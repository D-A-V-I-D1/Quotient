//
//  MarketSimulator.swift
//  QuotientCore
//
//  A discrete-event market with planted structure:
//
//    * A latent fundamental value V_t (arithmetic Brownian motion + Poisson
//      jumps). Nobody trades *at* V; it is what prices are heading toward.
//    * A public mid P_t = V_{t − delay}: the consensus lags the truth.
//    * Background liquidity providers ("the crowd") who rest a ladder of
//      limit orders around P_t. They are price-takers on information: they
//      re-centre when P_t moves, never before.
//    * Aggressive order flow arriving as a Poisson process. Each arrival is
//      informed with probability μ (Glosten–Milgrom, 1985). Informed traders
//      see V_t now and hit whichever side of the book is mispriced against it.
//      Uninformed traders hit a random side regardless of price.
//    * The market maker under test, who sees only the book (never V_t) and
//      quotes through the `MarketMakingStrategy` protocol.
//
//  Two things this produces on purpose:
//    Inventory risk (A-S setup) — with μ = 0, uninformed flow randomly fills
//      the maker's quotes and the position random-walks.
//    Adverse selection (G-M) — with μ > 0, the maker's fills against informed
//      traders precede price moves against it, visible as negative markouts.
//
//  Determinism and common random numbers
//    All randomness comes from three independent `SeededRandom` streams
//    derived from one seed: fundamental, arrivals, crowd. The strategy has no
//    access to any of them. Hence two strategies run with the same seed face
//    the identical fundamental path, identical arrival times/sizes/types and
//    identical crowd behaviour — what differs is only how the flow interacts
//    with *their* quotes. This is what makes the paired comparison valid.
//
//  Swapping in real data
//    This class implements (c) "the order flow driving it" from the brief.
//    A replay driver reading recorded L2 updates would produce the same
//    `MarketState` snapshots and `MarketMakerFill`s through the same
//    `MarketMakingStrategy` seam; see README → Roadmap.
//

import Foundation

/// One execution involving the market maker, from the maker's point of view.
public struct MarketMakerFill: Sendable, Hashable {
    public let step: Int
    /// The maker's side: `.bid` means the maker BOUGHT.
    public let side: Side
    public let price: Ticks
    public let quantity: Int
    /// Mid at the moment of the fill, in ticks.
    public let midAtFill: Double
    /// Who was on the other side (for attributing adverse selection).
    public let counterparty: Participant
    /// True if the maker's order was resting (earned the spread); false if
    /// the maker crossed the book (paid it).
    public let wasMaker: Bool

    /// Immediate edge vs. the mid at fill time, in ticks per lot: positive means
    /// bought below / sold above the mid. This is the "spread capture" term.
    public var captureTicks: Double { Double(side.sign) * (midAtFill - Double(price)) }
}

/// Everything recorded during one session.
public struct SimulationResult: Sendable {
    public let parameters: SimulationParameters
    public let strategyName: String
    public let seed: UInt64
    /// Per-step series (length = steps + 1, index 0 = initial).
    public let midTicks: [Double]
    public let fundamentalTicks: [Double]
    public let inventory: [Int]
    /// Mark-to-market P&L in dollars, marked at the mid.
    public let pnlDollars: [Double]
    /// The maker's own quoted spread (ask − bid) in ticks at each step, or nil
    /// when the maker was not two-sided. Reported so that a spread-width
    /// confounder between strategies is visible rather than hidden.
    public let quotedSpreadTicks: [Ticks?]
    public let fills: [MarketMakerFill]
    public let finalInventory: Int
    public let finalPnLDollars: Double
    /// Fitted intensity parameters, if the maker had enough fills.
    public let intensityFit: IntensityCalibrator.Fit?

    /// Markout in ticks for each fill at `horizon` steps after the fill:
    ///   sign · (mid_{t+h} − fill price).
    /// Negative = the price moved against the maker's fill: adverse selection.
    /// Fills within `horizon` of the session end are excluded rather than
    /// truncated, so every returned markout is at the same horizon.
    public func markouts(horizon: Int) -> [Double] {
        fills.compactMap { f in
            let idx = f.step + horizon
            guard idx < midTicks.count else { return nil }
            return Double(f.side.sign) * (midTicks[idx] - Double(f.price))
        }
    }

    /// Markouts split by counterparty type — the direct test of the
    /// Glosten–Milgrom story: informed counterparties should produce the
    /// negative tail.
    public func markouts(horizon: Int, counterparty: Participant) -> [Double] {
        fills.compactMap { f in
            guard f.counterparty == counterparty else { return nil }
            let idx = f.step + horizon
            guard idx < midTicks.count else { return nil }
            return Double(f.side.sign) * (midTicks[idx] - Double(f.price))
        }
    }
}

public final class MarketSimulator {

    public let parameters: SimulationParameters
    public let seed: UInt64
    public private(set) var strategy: any MarketMakingStrategy
    public let book = OrderBook()

    // RNG streams — see header.
    private var fundamentalRNG: SeededRandom
    private var arrivalRNG: SeededRandom
    private var crowdRNG: SeededRandom

    // Market state
    public private(set) var step = 0
    /// True value V_t in ticks (continuous).
    public private(set) var fundamental: Double
    /// Ring buffer of past fundamentals for the information delay.
    private var fundamentalHistory: [Double]
    /// Public consensus price in ticks (V lagged, rounded to grid).
    public private(set) var publicMidTicks: Ticks

    // Crowd bookkeeping: order id per (side, price) so we re-post only what changed.
    private var crowdOrders: [Side: [Ticks: OrderID]] = [.bid: [:], .ask: [:]]

    // Diagnostics. These depend only on the seed, never on the strategy, so
    // they double as a check that common random numbers are intact.
    public private(set) var arrivalsGenerated = 0
    public private(set) var informedArrivals = 0
    public private(set) var informedTradesExecuted = 0
    public private(set) var crowdChurnEvents = 0

    // Market maker bookkeeping
    public private(set) var inventory = 0
    /// Cash in tick·lots (negative after buying).
    public private(set) var cashTickLots: Double = 0
    private var restingBid: (id: OrderID, price: Ticks, size: Int)?
    private var restingAsk: (id: OrderID, price: Ticks, size: Int)?
    private var lastIntent: QuoteIntent = .none

    // Signals
    public private(set) var microprice: MicropriceEstimator
    public private(set) var volatility: VolatilityEstimator
    public private(set) var ofi: OrderFlowImbalance
    private var intensity = IntensityCalibrator()

    // Recording
    private var midSeries: [Double] = []
    private var fundamentalSeries: [Double] = []
    private var inventorySeries: [Int] = []
    private var pnlSeries: [Double] = []
    private var quotedSpreadSeries: [Ticks?] = []
    public private(set) var fills: [MarketMakerFill] = []

    public init(parameters: SimulationParameters, strategy: any MarketMakingStrategy, seed: UInt64) {
        self.parameters = parameters
        self.strategy = strategy
        self.seed = seed
        let root = SeededRandom(seed: seed)
        fundamentalRNG = root.derived(stream: 1)
        arrivalRNG = root.derived(stream: 2)
        crowdRNG = root.derived(stream: 3)
        fundamental = Double(parameters.initialMidTicks)
        fundamentalHistory = Array(repeating: fundamental, count: parameters.informationDelaySteps + 1)
        publicMidTicks = parameters.initialMidTicks
        microprice = MicropriceEstimator()
        volatility = VolatilityEstimator(halfLife: parameters.volatilityHalfLifeSteps,
                                         prior: parameters.fundamentalVolatilityTicks)
        ofi = OrderFlowImbalance()
        self.strategy.reset()
        refreshCrowd()
        record()
    }

    // MARK: - Public API

    public var isFinished: Bool { step >= parameters.steps }
    public var currentMidTicks: Double? { book.midTicks }

    /// Mark-to-market P&L in dollars at the current mid.
    public var pnlDollars: Double {
        let mid = book.midTicks ?? Double(publicMidTicks)
        return (cashTickLots + Double(inventory) * mid) * parameters.dollarsPerTickLot
    }

    /// The market mid *excluding the maker's own orders*, falling back to the
    /// full-book mid and finally the public mid.
    ///
    /// WHY (a real bug found in development): if the strategy centres on a mid
    /// that includes its own quotes, then whenever one side of the crowd is
    /// wiped out the maker's own far-away quote becomes the best price on that
    /// side, the "mid" jumps toward it, the maker re-centres there, its σ
    /// estimator sees a huge move, the A-S spread widens, and the loop runs
    /// away exponentially (observed: mid of −6.7 million ticks). A maker knows
    /// its own orders, so "the market without me" is a legitimate observable.
    /// Regression test: MarketSimulatorTests.midExcludesOwnQuotesSoNoFeedbackLoop.
    public var externalMidTicks: Double {
        book.midTicks(excluding: .marketMaker) ?? book.midTicks ?? Double(publicMidTicks)
    }

    /// The state the strategy sees right now (also used by the UI).
    public var marketState: MarketState {
        let best = book.best
        let bid = best.bidPrice ?? publicMidTicks - Ticks(parameters.crowdHalfSpreadTicks)
        let ask = best.askPrice ?? publicMidTicks + Ticks(parameters.crowdHalfSpreadTicks)
        let mid = externalMidTicks
        // The microprice is centred on the full-book mid by construction; shift
        // its adjustment onto the external mid so both references agree when
        // the maker is not at the touch.
        let microAdj = (microprice.microprice(book) ?? Signals.weightedMid(book) ?? mid) - (best.midTicks ?? mid)
        let micro = mid + (microAdj.isFinite ? microAdj : 0)
        return MarketState(
            step: step, totalSteps: parameters.steps,
            midTicks: mid, micropriceTicks: micro,
            imbalance: Signals.imbalance(book) ?? 0,
            orderFlowImbalance: ofi.value,
            spreadTicks: best.spreadTicks ?? Ticks(2 * parameters.crowdHalfSpreadTicks),
            inventory: inventory,
            sigmaTicksPerStep: volatility.sigma,
            bestBid: bid, bestAsk: ask
        )
    }

    /// Replace the strategy mid-session (used by the app's Manual mode and
    /// the strategy picker). Pulls existing quotes.
    public func replaceStrategy(_ newStrategy: any MarketMakingStrategy) {
        pullQuotes()
        strategy = newStrategy
        strategy.reset()
    }

    /// Update a manual strategy's parameters without resetting anything.
    public func updateStrategy(_ mutate: (inout any MarketMakingStrategy) -> Void) {
        mutate(&strategy)
    }

    /// Advance one step. Order of operations within a step:
    ///   1. fundamental evolves; public mid updates (with delay)
    ///   2. crowd re-centres / churns
    ///   3. signals observe the book
    ///   4. maker quotes
    ///   5. aggressive flow arrives and matches
    ///   6. record
    public func advance() {
        guard !isFinished else { return }
        step += 1
        evolveFundamental()
        refreshCrowd()
        observeSignals()
        if step % parameters.quoteIntervalSteps == 0 { requote() }
        processArrivals()
        record()
    }

    public func run() -> SimulationResult {
        while !isFinished { advance() }
        return result()
    }

    public func result() -> SimulationResult {
        SimulationResult(
            parameters: parameters, strategyName: strategy.name, seed: seed,
            midTicks: midSeries, fundamentalTicks: fundamentalSeries,
            inventory: inventorySeries, pnlDollars: pnlSeries,
            quotedSpreadTicks: quotedSpreadSeries, fills: fills,
            finalInventory: inventory, finalPnLDollars: pnlDollars,
            intensityFit: intensity.fit()
        )
    }

    // MARK: - 1. Fundamental

    private func evolveFundamental() {
        var dv = parameters.fundamentalDriftTicks + parameters.fundamentalVolatilityTicks * fundamentalRNG.nextGaussian()
        // Always draw the jump Bernoulli so the stream stays aligned across runs.
        let jumps = fundamentalRNG.nextBool(probability: parameters.jumpProbability)
        let jumpDraw = fundamentalRNG.nextGaussian()
        if jumps { dv += parameters.jumpSizeTicks * jumpDraw }
        fundamental += dv
        fundamentalHistory.append(fundamental)
        if fundamentalHistory.count > parameters.informationDelaySteps + 1 {
            fundamentalHistory.removeFirst()
        }
        publicMidTicks = Ticks(fundamentalHistory[0].rounded())
    }

    // MARK: - 2. Crowd

    /// Desired crowd ladder: best quotes at publicMid ± halfSpread, deeper
    /// levels one tick apart, sizes growing geometrically.
    private func desiredCrowdLevels(_ side: Side) -> [(price: Ticks, size: Int)] {
        (0..<parameters.crowdLevels).map { i in
            let dist = Ticks(parameters.crowdHalfSpreadTicks + i)
            let price = side == .bid ? publicMidTicks - dist : publicMidTicks + dist
            let size = Int((Double(parameters.crowdBaseSizeLots) * pow(parameters.crowdSizeGrowthPerLevel, Double(i))).rounded())
            return (price, max(1, size))
        }
    }

    private func refreshCrowd() {
        for side in Side.allCases {
            let desired = desiredCrowdLevels(side)
            let desiredPrices = Set(desired.map(\.price))
            var live = crowdOrders[side] ?? [:]

            // Draw churn for every *desired* level up front, a fixed number of
            // draws per step regardless of book state.
            // WHY: if the number of RNG draws depended on which crowd levels
            // happened to be live, the maker's own fills would perturb the
            // crowd stream and the "same seed, same market" guarantee would
            // silently break. (This was a real bug found during development;
            // see MarketSimulatorTests.commonRandomNumbersHoldAcrossStrategies.)
            var churned = Set<Ticks>()
            for lvl in desired where crowdRNG.nextBool(probability: parameters.crowdChurnProbability) {
                churned.insert(lvl.price)
                crowdChurnEvents += 1
            }
            // Cancel levels that are no longer wanted, or randomly churn.
            for (price, id) in live {
                if !desiredPrices.contains(price) || churned.contains(price) || book.order(id: id) == nil {
                    book.cancel(id)
                    live.removeValue(forKey: price)
                }
            }
            // Post (or top up) wanted levels. A depleted level gets a fresh
            // order at the back of the queue — the crowd replenishes, it
            // doesn't jump the line.
            for (price, size) in desired {
                if let id = live[price], let o = book.order(id: id), o.remainingQuantity > 0 { continue }
                live.removeValue(forKey: price)
                // The crowd posts at its price regardless of the maker. If the
                // maker has a stale quote on the wrong side of the public price,
                // the crowd's limit order crosses it and the maker gets picked
                // off — exactly what happens to a stale quote on a real venue.
                let midBefore = externalMidTicks
                let res = book.submitLimit(side: side, price: price, quantity: size, owner: .backgroundLiquidity)
                for f in res.fills where f.makerOwner == .marketMaker {
                    recordMakerFill(side: side.opposite, price: f.price, quantity: f.quantity,
                                    counterparty: .backgroundLiquidity, wasMaker: true, mid: midBefore)
                }
                if res.restingQuantity > 0 { live[price] = res.orderID }
            }
            crowdOrders[side] = live
        }
    }

    // MARK: - 3. Signals

    private func observeSignals() {
        // Estimate σ on the book *excluding our own orders* — see OrderBook.bestPrice(_:excluding:).
        // If there is no external two-sided market this step, skip the
        // observation rather than feed our own quote back into σ.
        if let mid = book.midTicks(excluding: .marketMaker) { volatility.observe(mid: mid) }
        ofi.observe(book.best)
        microprice.observe(book)
        if step % parameters.micropriceRefitIntervalSteps == 0 { microprice.refit() }
    }

    // MARK: - 4. Maker quotes

    private func pullQuotes() {
        if let b = restingBid { book.cancel(b.id); restingBid = nil }
        if let a = restingAsk { book.cancel(a.id); restingAsk = nil }
        lastIntent = .none
    }

    private func requote() {
        let state = marketState
        var intent = strategy.quotes(for: state)
        if !intent.isValid { intent = .none }

        // Record exposure for intensity calibration (distance of each live quote from mid).
        if let b = restingBid { intensity.record(distance: Int((state.midTicks - Double(b.price)).rounded()), fills: 0) }
        if let a = restingAsk { intensity.record(distance: Int((Double(a.price) - state.midTicks).rounded()), fills: 0) }

        // Replace only the sides that changed, to keep queue priority when the
        // strategy wants the same price (matters for realism: A-S at zero
        // inventory sits still; fixed-spread re-quotes only when mid moves).
        //
        // Cancel BOTH stale sides before submitting EITHER new one.
        // WHY (a real bug found in development): submitting the new bid while
        // the old ask was still resting let a large skew cross the maker's own
        // ask — a self-trade, recorded as a fill against `.marketMaker`.
        // Regression test: MarketSimulatorTests.makerNeverTradesWithItself.
        let bidStale = isStale(.bid, desiredPrice: intent.bidPrice, desiredSize: intent.bidSize)
        let askStale = isStale(.ask, desiredPrice: intent.askPrice, desiredSize: intent.askSize)
        if bidStale, let b = restingBid { book.cancel(b.id); restingBid = nil }
        if askStale, let a = restingAsk { book.cancel(a.id); restingAsk = nil }
        if bidStale { place(.bid, price: intent.bidPrice, size: intent.bidSize, mid: state.midTicks) }
        if askStale { place(.ask, price: intent.askPrice, size: intent.askSize, mid: state.midTicks) }
        lastIntent = intent
    }

    /// True unless the current resting order already matches the intent.
    private func isStale(_ side: Side, desiredPrice: Ticks?, desiredSize: Int) -> Bool {
        let current = side == .bid ? restingBid : restingAsk
        if let c = current, let live = book.order(id: c.id), live.remainingQuantity > 0,
           c.price == desiredPrice, c.size == desiredSize {
            return false
        }
        return true
    }

    private func place(_ side: Side, price desiredPrice: Ticks?, size desiredSize: Int, mid: Double) {
        guard let price = desiredPrice, desiredSize > 0 else { return }

        let res = book.submitLimit(side: side, price: price, quantity: desiredSize, owner: .marketMaker)
        // If the maker crossed the book it took liquidity — record as taker fills.
        for f in res.fills {
            recordMakerFill(side: side, price: f.price, quantity: f.quantity, counterparty: f.makerOwner, wasMaker: false, mid: mid)
        }
        if res.restingQuantity > 0 {
            let entry = (id: res.orderID, price: price, size: desiredSize)
            if side == .bid { restingBid = entry } else { restingAsk = entry }
        }
    }

    // MARK: - 5. Aggressive flow

    private func processArrivals() {
        let n = arrivalRNG.nextPoisson(mean: parameters.arrivalRatePerStep)
        for _ in 0..<n {
            // Draw everything up front so the stream is identical across strategies.
            let informed = arrivalRNG.nextBool(probability: parameters.informedFraction)
            let uninformedBuys = arrivalRNG.nextBool(probability: parameters.uninformedBuyProbability)
            let baseSize = arrivalRNG.nextGeometric(successProbability: 1.0 / max(1.0, parameters.meanOrderSizeLots))
            arrivalsGenerated += 1
            if informed { informedArrivals += 1 }

            let side: Side
            let size: Int
            if informed {
                // Glosten–Milgrom: informed trader compares true value to the quotes.
                guard let bid = book.bestBid, let ask = book.bestAsk else { continue }
                if fundamental > Double(ask) + parameters.informedThresholdTicks {
                    side = .bid
                } else if fundamental < Double(bid) - parameters.informedThresholdTicks {
                    side = .ask
                } else {
                    continue // no edge, no trade
                }
                size = max(1, Int((Double(baseSize) * parameters.informedSizeMultiplier).rounded()))
                informedTradesExecuted += 1
            } else {
                side = uninformedBuys ? .bid : .ask
                size = baseSize
            }
            let midBefore = externalMidTicks
            let owner: Participant = informed ? .informedTrader : .noiseTrader
            let res = book.submitMarket(side: side, quantity: size, owner: owner)
            for f in res.fills where f.makerOwner == .marketMaker {
                // The maker's side is opposite the aggressor's.
                recordMakerFill(side: side.opposite, price: f.price, quantity: f.quantity,
                                counterparty: owner, wasMaker: true, mid: midBefore)
                intensity.record(distance: Int(abs(Double(f.price) - midBefore).rounded()), fills: 1, exposure: 0)
            }
            // Crowd orders that got consumed will be replenished next step.
        }
        // Clear maker bookkeeping for fully-filled quotes.
        if let b = restingBid, book.order(id: b.id) == nil { restingBid = nil }
        if let a = restingAsk, book.order(id: a.id) == nil { restingAsk = nil }
    }

    private func recordMakerFill(side: Side, price: Ticks, quantity: Int, counterparty: Participant, wasMaker: Bool, mid: Double) {
        inventory += side.sign * quantity
        cashTickLots -= Double(side.sign) * Double(price) * Double(quantity)
        fills.append(MarketMakerFill(step: step, side: side, price: price, quantity: quantity,
                                     midAtFill: mid, counterparty: counterparty, wasMaker: wasMaker))
    }

    // MARK: - 6. Record

    private func record() {
        midSeries.append(externalMidTicks)
        fundamentalSeries.append(fundamental)
        inventorySeries.append(inventory)
        pnlSeries.append(pnlDollars)
        if let b = restingBid, let a = restingAsk { quotedSpreadSeries.append(a.price - b.price) } else { quotedSpreadSeries.append(nil) }
    }

    /// The maker's currently resting quotes (for the UI).
    public var restingQuotes: (bid: Ticks?, ask: Ticks?) { (restingBid?.price, restingAsk?.price) }
}
