//
//  AvellanedaStoikovMarketMaker.swift
//  QuotientCore
//
//  LEVELS 2 & 3 — inventory- and volatility-aware market making.
//
//  Implements the closed-form quotes of
//    Avellaneda, M. & Stoikov, S. (2008). "High-frequency trading in a limit
//    order book." Quantitative Finance 8(3), 217–224.
//
//  Model recap (their notation, our units):
//    * Mid follows dS = σ dW  (arithmetic Brownian motion)
//    * Maker has inventory q, CARA utility with risk aversion γ
//    * A quote at distance δ from the mid is hit with intensity λ(δ) = A·e^{−kδ}
//
//  Results used here:
//    reservation price   r  = s − q·γ·σ²·(T − t)                       (their eq. for r)
//    total spread        δ  = γ·σ²·(T − t) + (2/γ)·ln(1 + γ/k)
//    bid = r − δ/2,  ask = r + δ/2
//
//  Intuition, which is also the market-making interview answer:
//    * The reservation price is the maker's *indifference* price. Long
//      inventory (q > 0) shifts it below the mid, so the ask is more
//      aggressive and the bid less aggressive: the maker leans on the market
//      to get flat. The lean scales with how much variance is left to
//      endure, σ²(T − t), and how much the maker dislikes it, γ.
//    * The spread has two parts: a risk term that also grows with σ²(T − t),
//      and a liquidity term (2/γ)·ln(1 + γ/k) that trades off fill probability
//      (higher k = fills die off faster with distance = quote tighter) against
//      edge per fill.
//
//  Units in this implementation:
//    prices and σ are in ticks (σ per step), time in steps, q in lots. Hence
//    γ has units of 1/(ticks·lot) and k of 1/ticks. This keeps the formulas
//    literal and makes the parameters portable across instruments with
//    different tick sizes and price levels.
//
//  Departures from the paper, each a named parameter:
//    * Horizon. The paper's T is a fixed terminal time, which makes the maker
//      quote very wide at the open and collapse to a symmetric, un-skewed
//      quote at the close (because σ²(T − t) → 0). That is correct for the
//      model but poor practice for a maker that runs all day. `Horizon.rolling`
//      substitutes a constant effective horizon τ, the common practitioner
//      fix (see Guéant, Lehalle & Fernandez-Tapia, 2013 for the stationary
//      treatment). `Horizon.finite` reproduces the paper.
//    * Reference price. The paper centres on the mid `s`. Level 3 replaces
//      `s` with the microprice (Stoikov, 2018), so the reservation price also
//      leans in the direction the book says the next mid move is likely to
//      go. This is a natural extension in the spirit of Cartea, Jaimungal &
//      Penalva (2015, ch. 10) — it is NOT a claim of reproducing any specific
//      published or proprietary model.
//    * Hard inventory bound. Optional `maxInventory` stops quoting the side
//      that would breach the limit — a risk control the paper lacks.
//    * Tick grid. The paper's prices are continuous. We snap each quote to
//      the nearest tick and enforce a minimum spread of one tick.
//
//  σ is *estimated online* from observed mids (EWMA), never taken from the
//  simulator. A strategy that could peek at the true σ would not survive
//  contact with real data.
//
//  This is textbook-standard theory. It is not a claim to have reproduced any
//  firm's proprietary strategy, nor a claim of real-market profitability.
//

import Foundation

public struct AvellanedaStoikovMarketMaker: MarketMakingStrategy, Equatable {

    public enum Horizon: Sendable, Equatable {
        /// (T − t) = steps remaining in the session, as in the paper.
        case finite
        /// (T − t) = a constant number of steps. Stationary quotes.
        case rolling(steps: Int)
    }

    public enum ReferencePrice: String, Sendable, Equatable, CaseIterable {
        /// Centre on the mid (Level 2, the paper).
        case mid
        /// Centre on the microprice (Level 3).
        case microprice
    }

    public var name: String {
        referencePrice == .mid ? "Avellaneda-Stoikov" : "A-S + Microprice"
    }
    public var summary: String {
        switch referencePrice {
        case .mid:
            return "Avellaneda–Stoikov (2008) reservation price and optimal spread: skews quotes against inventory in proportion to γ·σ²·τ and sizes the spread from the fill-intensity decay k. σ is estimated online."
        case .microprice:
            return "Avellaneda–Stoikov quotes centred on Stoikov's (2018) microprice instead of the mid, so the reservation price also leans toward where order-book imbalance says the next mid move is likely to go."
        }
    }

    /// Risk aversion γ, in 1/(ticks·lot). Larger = leans harder against inventory and quotes wider.
    public var gamma: Double
    /// Fill-intensity decay k, in 1/ticks. Larger = fills fall off faster with distance = quote tighter.
    public var k: Double
    public var horizon: Horizon
    public var referencePrice: ReferencePrice
    public var sizeLots: Int
    public var maxInventory: Int?
    /// Floor on the total spread in ticks (a one-tick market is the tightest legal quote).
    public var minimumSpreadTicks: Ticks

    public init(gamma: Double = 0.05,
                k: Double = 1.0,
                horizon: Horizon = .rolling(steps: 300),
                referencePrice: ReferencePrice = .mid,
                sizeLots: Int = 1,
                maxInventory: Int? = nil,
                minimumSpreadTicks: Ticks = 1) {
        precondition(gamma > 0 && k > 0 && sizeLots > 0 && minimumSpreadTicks >= 1)
        self.gamma = gamma
        self.k = k
        self.horizon = horizon
        self.referencePrice = referencePrice
        self.sizeLots = sizeLots
        self.maxInventory = maxInventory
        self.minimumSpreadTicks = minimumSpreadTicks
    }

    // MARK: - The formulas, exposed for tests and the UI

    /// Effective time-to-horizon in steps.
    public func timeRemaining(for state: MarketState) -> Double {
        switch horizon {
        case .finite: return Double(state.stepsRemaining)
        case .rolling(let steps): return Double(steps)
        }
    }

    /// r = s − q·γ·σ²·(T − t)
    public func reservationPrice(reference s: Double, inventory q: Int, sigma: Double, timeRemaining tau: Double) -> Double {
        s - Double(q) * gamma * sigma * sigma * tau
    }

    /// δ = γ·σ²·(T − t) + (2/γ)·ln(1 + γ/k)
    public func optimalSpread(sigma: Double, timeRemaining tau: Double) -> Double {
        gamma * sigma * sigma * tau + (2.0 / gamma) * log(1.0 + gamma / k)
    }

    // MARK: - Strategy

    public mutating func quotes(for state: MarketState) -> QuoteIntent {
        let tau = timeRemaining(for: state)
        let sigma = state.sigmaTicksPerStep
        let s = referencePrice == .mid ? state.midTicks : state.micropriceTicks

        let r = reservationPrice(reference: s, inventory: state.inventory, sigma: sigma, timeRemaining: tau)
        let spread = max(optimalSpread(sigma: sigma, timeRemaining: tau), Double(minimumSpreadTicks))

        // Snap to the tick grid (nearest), then enforce the minimum spread.
        // WHY nearest and not outward: outward rounding inflates a 4.3-tick
        // theoretical spread to 6 ticks whenever the mid sits on a half-tick,
        // which silently widens *every* strategy by a different amount and
        // confounds the comparison. Nearest keeps the realised spread within
        // half a tick of the theory on both sides.
        var bid: Ticks? = Ticks((r - spread / 2).rounded(.toNearestOrAwayFromZero))
        var ask: Ticks? = Ticks((r + spread / 2).rounded(.toNearestOrAwayFromZero))
        if let b = bid, let a = ask, a - b < minimumSpreadTicks { ask = b + minimumSpreadTicks }

        if let cap = maxInventory {
            if state.inventory >= cap { bid = nil }
            if state.inventory <= -cap { ask = nil }
        }
        return QuoteIntent(bidPrice: bid, askPrice: ask, bidSize: sizeLots, askSize: sizeLots)
    }
}

public extension FixedSpreadMarketMaker {
    /// Build a fixed-spread maker whose total spread equals what the given
    /// Avellaneda–Stoikov maker would quote at zero inventory and σ = `sigma`.
    ///
    /// WHY: to compare "skews with inventory" against "doesn't", the spread
    /// width must be held equal, otherwise a wider spread alone would explain
    /// any P&L difference. This is the matched-confounder control the
    /// evaluation uses.
    static func matched(to strategy: AvellanedaStoikovMarketMaker, sigma: Double, horizonSteps: Double) -> FixedSpreadMarketMaker {
        let spread = max(strategy.optimalSpread(sigma: sigma, timeRemaining: horizonSteps), Double(strategy.minimumSpreadTicks))
        return FixedSpreadMarketMaker(halfSpreadTicks: spread / 2, sizeLots: strategy.sizeLots, maxInventory: strategy.maxInventory)
    }
}
