//
//  TerminalViewModel.swift
//  Quotient
//
//  Drives a live `MarketSimulator` for the Terminal screen. All simulation
//  logic lives in QuotientCore; this class only owns pacing, the strategy
//  picker, and the derived series the charts read.
//

import Foundation
import Observation
import QuotientCore

@Observable
final class TerminalViewModel {

    enum StrategyChoice: String, CaseIterable, Identifiable {
        case fixed = "Fixed"
        case avellanedaStoikov = "A-S"
        case microprice = "A-S + Micro"
        case manual = "Manual"
        var id: String { rawValue }
    }

    enum Speed: Int, CaseIterable, Identifiable {
        case x1 = 1, x5 = 5, x20 = 20
        var id: Int { rawValue }
        var label: String { "\(rawValue)×" }
    }

    // Configuration
    private(set) var parameters: SimulationParameters
    var preset: ScenarioPreset
    var strategyChoice: StrategyChoice = .avellanedaStoikov { didSet { applyStrategy() } }
    var speed: Speed = .x5
    var gamma: Double = 0.01 { didSet { applyStrategy() } }
    var informedFraction: Double { didSet { rebuild(keepingSeed: false) } }
    var maxInventoryEnabled = false { didSet { applyStrategy() } }

    // Manual mode
    var manualHalfSpread: Double = 1.5 { didSet { applyStrategy() } }
    var manualSkew: Double = 0 { didSet { applyStrategy() } }
    var manualSize: Int = 1 { didSet { applyStrategy() } }

    // Live state
    private(set) var simulator: MarketSimulator
    private(set) var isRunning = false
    private(set) var seed: UInt64 = 1
    private var ticker: Task<Void, Never>?

    // Derived for the view (refreshed each tick)
    private(set) var bids: [PriceLevelSnapshot] = []
    private(set) var asks: [PriceLevelSnapshot] = []
    private(set) var state: MarketState
    private(set) var pnlSeries: [Double] = []
    private(set) var inventorySeries: [Int] = []
    private(set) var recentFills: [MarketMakerFill] = []
    private(set) var makerQuotes: (bid: Ticks?, ask: Ticks?) = (nil, nil)
    private(set) var meanMarkout50: Double?
    private(set) var liveSummary: String = ""
    private(set) var version = 0

    /// Steps back to compare the quoted spread against for the live summary.
    private let spreadLookbackSteps = 150

    var instrument: Instrument { parameters.instrument }

    init(parameters: SimulationParameters) {
        self.parameters = parameters
        self.preset = ScenarioPreset.baseline(parameters)
        self.informedFraction = parameters.informedFraction
        let sim = MarketSimulator(parameters: parameters, strategy: AvellanedaStoikovMarketMaker(gamma: 0.01), seed: 1)
        self.simulator = sim
        self.state = sim.marketState
        refresh()
    }

    // MARK: Strategy construction (the only place UI choices become core types)

    private var maxInventory: Int? { maxInventoryEnabled ? 5 : nil }

    func makeStrategy() -> any MarketMakingStrategy {
        switch strategyChoice {
        case .fixed:
            let asMM = AvellanedaStoikovMarketMaker(gamma: gamma, maxInventory: maxInventory)
            return FixedSpreadMarketMaker.matched(to: asMM, sigma: simulator.volatility.sigma, horizonSteps: 300)
        case .avellanedaStoikov:
            return AvellanedaStoikovMarketMaker(gamma: gamma, referencePrice: .mid, maxInventory: maxInventory)
        case .microprice:
            return AvellanedaStoikovMarketMaker(gamma: gamma, referencePrice: .microprice, maxInventory: maxInventory)
        case .manual:
            return ManualMarketMaker(halfSpreadTicks: manualHalfSpread, skewTicks: manualSkew, sizeLots: manualSize)
        }
    }

    private func applyStrategy() {
        simulator.replaceStrategy(makeStrategy())
        refresh()
    }

    // MARK: Session control

    func setParameters(_ p: SimulationParameters, preset: ScenarioPreset? = nil) {
        parameters = p
        if let preset { self.preset = preset }
        informedFraction = p.informedFraction
    }

    func applyPreset(_ preset: ScenarioPreset) {
        self.preset = preset
        parameters = preset.parameters
        informedFraction = preset.parameters.informedFraction
        rebuild(keepingSeed: true)
    }

    func rebuild(keepingSeed: Bool) {
        let wasRunning = isRunning
        pause()
        if !keepingSeed { seed &+= 1 }
        var p = parameters
        p.informedFraction = informedFraction
        parameters = p
        simulator = MarketSimulator(parameters: p, strategy: makeStrategy(), seed: seed)
        refresh()
        if wasRunning { play() }
    }

    func reset() { rebuild(keepingSeed: false) }

    func play() {
        guard !isRunning else { return }
        isRunning = true
        ticker = Task { [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                // ~20 frames/s; `speed` steps per frame.
                for _ in 0..<self.speed.rawValue where !self.simulator.isFinished { self.simulator.advance() }
                self.refresh()
                if self.simulator.isFinished { self.isRunning = false; break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func pause() {
        isRunning = false
        ticker?.cancel()
        ticker = nil
    }

    func step(_ n: Int = 1) {
        for _ in 0..<n where !simulator.isFinished { simulator.advance() }
        refresh()
    }

    // MARK: Derived state

    private func refresh() {
        let book = simulator.book
        bids = book.depth(.bid, levels: 6)
        asks = book.depth(.ask, levels: 6)
        state = simulator.marketState
        makerQuotes = simulator.restingQuotes
        let r = simulator.result()
        pnlSeries = r.pnlDollars
        inventorySeries = r.inventory
        recentFills = Array(simulator.fills.suffix(8).reversed())
        let m = r.markouts(horizon: 50)
        meanMarkout50 = m.isEmpty ? nil : m.reduce(0, +) / Double(m.count)
        let spreads = r.quotedSpreadTicks
        let earlierIdx = max(0, spreads.count - 1 - spreadLookbackSteps)
        liveSummary = PlainEnglish.liveSummary(PlainEnglish.LiveState(
            symbol: instrument.symbol, inventoryLots: simulator.inventory, sharesPerLot: instrument.lotSize,
            pnlDollars: simulator.pnlDollars, fills: simulator.fills.count,
            informedFills: simulator.fills.filter { $0.counterparty == .informedTrader }.count,
            quotedSpreadTicks: spreads.last.flatMap { $0 }.map(Int.init),
            earlierQuotedSpreadTicks: spreads.isEmpty ? nil : spreads[earlierIdx].map(Int.init),
            sigmaEstimate: simulator.volatility.sigma, sigmaPrior: parameters.fundamentalVolatilityTicks,
            isFinished: simulator.isFinished, step: simulator.step))
        version &+= 1
    }

    var pnl: Double { simulator.pnlDollars }
    var inventory: Int { simulator.inventory }
    var progress: Double { Double(simulator.step) / Double(parameters.steps) }
    var strategyName: String { simulator.strategy.name }
    var strategySummary: String { simulator.strategy.summary }

    func dollars(_ ticks: Ticks) -> String { Fmt.price(instrument.price(fromTicks: ticks)) }
    func dollars(_ ticks: Double) -> String { Fmt.price(instrument.price(fromTicks: ticks)) }
}
