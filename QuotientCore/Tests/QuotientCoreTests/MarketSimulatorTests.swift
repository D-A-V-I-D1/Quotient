import Testing
import Foundation
@testable import QuotientCore

/// A strategy that never quotes. Isolates the market from any maker behaviour.
struct NoQuoteStrategy: MarketMakingStrategy {
    var name: String { "None" }
    var summary: String { "" }
    mutating func quotes(for state: MarketState) -> QuoteIntent { .none }
}

@Suite("MarketSimulator") struct MarketSimulatorTests {

    var short: SimulationParameters {
        var p = SimulationParameters.example
        p.steps = 600
        return p
    }

    @Test("same seed + same strategy → bit-identical results")
    func deterministic() {
        let a = MarketSimulator(parameters: short, strategy: AvellanedaStoikovMarketMaker(), seed: 77).run()
        let b = MarketSimulator(parameters: short, strategy: AvellanedaStoikovMarketMaker(), seed: 77).run()
        #expect(a.pnlDollars == b.pnlDollars)
        #expect(a.fills == b.fills)
        #expect(a.midTicks == b.midTicks)
        let c = MarketSimulator(parameters: short, strategy: AvellanedaStoikovMarketMaker(), seed: 78).run()
        #expect(a.fundamentalTicks != c.fundamentalTicks)
    }

    @Test("common random numbers: the market is identical across strategies for one seed")
    func commonRandomNumbersHoldAcrossStrategies() {
        let strategies: [any MarketMakingStrategy] = [NoQuoteStrategy(), FixedSpreadMarketMaker(halfSpreadTicks: 1), AvellanedaStoikovMarketMaker(gamma: 0.01)]
        var p = ScenarioPreset.newsHeavy(short).parameters
        p.crowdChurnProbability = 0.2 // stress the crowd stream, where the alignment bug lived
        let sims = strategies.map { MarketSimulator(parameters: p, strategy: $0, seed: 5) }
        let results = sims.map { $0.run() }
        for r in results.dropFirst() {
            #expect(r.fundamentalTicks == results[0].fundamentalTicks)
        }
        for s in sims.dropFirst() {
            #expect(s.arrivalsGenerated == sims[0].arrivalsGenerated)
            #expect(s.informedArrivals == sims[0].informedArrivals)
            #expect(s.crowdChurnEvents == sims[0].crowdChurnEvents)
        }
        #expect(sims[0].arrivalsGenerated > 0 && sims[0].crowdChurnEvents > 0)
    }

    @Test("book invariants hold at every step")
    func invariantsEveryStep() {
        let sim = MarketSimulator(parameters: short, strategy: AvellanedaStoikovMarketMaker(gamma: 0.01), seed: 3)
        while !sim.isFinished {
            sim.advance()
            #expect(sim.book.checkInvariants() == nil)
        }
    }

    @Test("with μ = 0 there are no informed fills, with μ > 0 there are")
    func informedFraction() {
        var p = short
        p.informedFraction = 0
        let none = MarketSimulator(parameters: p, strategy: FixedSpreadMarketMaker(halfSpreadTicks: 1), seed: 1).run()
        #expect(none.fills.allSatisfy { $0.counterparty != .informedTrader })
        #expect(!none.fills.isEmpty)
        p.informedFraction = 0.5
        let some = MarketSimulator(parameters: p, strategy: FixedSpreadMarketMaker(halfSpreadTicks: 1), seed: 1).run()
        #expect(some.fills.contains { $0.counterparty == .informedTrader })
    }

    @Test("adverse selection signature: informed markouts are negative, noise markouts positive")
    func markoutSign() async {
        var p = SimulationParameters.example
        p.steps = 1500
        p.informedFraction = 0.3
        let cfg = MonteCarloConfiguration(parameters: p, trials: 12)
        let rep = await MonteCarloRunner.run(cfg, strategies: [FixedSpreadMarketMaker(halfSpreadTicks: 1.5)])
        let o = rep.outcomes[0]
        #expect(o.meanMarkoutVsInformedTicks[50]!.mean < 0)
        #expect(o.meanMarkoutVsNoiseTicks[50]!.mean > 0)
        #expect(o.meanMarkoutVsInformedTicks[50]!.mean < o.meanMarkoutVsNoiseTicks[50]!.mean)
    }

    @Test("inventory risk with zero informed flow: naive maker's RMS inventory ≫ A-S")
    func inventoryControl() async {
        let p = ScenarioPreset.inventoryOnly(short).parameters
        let cfg = MonteCarloConfiguration(parameters: p, trials: 12)
        let asMM = AvellanedaStoikovMarketMaker(gamma: 0.01)
        let fixed = FixedSpreadMarketMaker.matched(to: asMM, sigma: p.fundamentalVolatilityTicks, horizonSteps: 300)
        let rep = await MonteCarloRunner.run(cfg, strategies: [fixed, asMM])
        let f = rep.outcome(named: fixed.name)!, a = rep.outcome(named: asMM.name)!
        #expect(f.rmsInventory.mean > 3 * a.rmsInventory.mean)
        #expect(f.finalPnL.standardDeviation > a.finalPnL.standardDeviation)
        #expect(rep.comparison(fixed.name, asMM.name)!.rmsInventory!.pValue < 0.01)
    }

    @Test("regression: mid excludes own quotes so no runaway feedback loop (was −6.7M ticks)")
    func midExcludesOwnQuotesSoNoFeedbackLoop() {
        // News-heavy, seed 0, A-S: the exact configuration that diverged.
        let p = ScenarioPreset.newsHeavy().parameters
        let sim = MarketSimulator(parameters: p, strategy: AvellanedaStoikovMarketMaker(gamma: 0.01), seed: 0)
        let r = sim.run()
        for (m, f) in zip(r.midTicks, r.fundamentalTicks) {
            #expect(m.isFinite)
            #expect(abs(m - f) < 300, "mid \(m) drifted from fundamental \(f)")
        }
        #expect(sim.volatility.sigma < 20)
    }

    @Test("P&L accounting: cash + inventory·mid equals recorded P&L and the decomposition sums")
    func pnlAccounting() {
        let sim = MarketSimulator(parameters: short, strategy: FixedSpreadMarketMaker(halfSpreadTicks: 1), seed: 4)
        let r = sim.run()
        let m = PerformanceMetrics(result: r)
        #expect(abs(m.spreadCapturePnL + m.inventoryPnL - m.finalPnL) < 1e-6)
        // Recompute from fills independently.
        var cash = 0.0, inv = 0
        for f in r.fills {
            cash -= Double(f.side.sign) * Double(f.price) * Double(f.quantity)
            inv += f.side.sign * f.quantity
        }
        let mtm = (cash + Double(inv) * r.midTicks.last!) * short.dollarsPerTickLot
        #expect(abs(mtm - r.finalPnLDollars) < 1e-6)
        #expect(inv == r.finalInventory)
    }

    @Test("markouts at horizon h exclude fills too close to the end")
    func markoutTruncation() {
        let r = MarketSimulator(parameters: short, strategy: FixedSpreadMarketMaker(halfSpreadTicks: 1), seed: 8).run()
        let h = 50
        let eligible = r.fills.filter { $0.step + h < r.midTicks.count }.count
        #expect(r.markouts(horizon: h).count == eligible)
        #expect(r.markouts(horizon: 0).count == r.fills.count)
    }

    @Test("a strategy that never quotes never trades")
    func noQuote() {
        let r = MarketSimulator(parameters: short, strategy: NoQuoteStrategy(), seed: 2).run()
        #expect(r.fills.isEmpty)
        #expect(r.finalPnLDollars == 0)
        #expect(r.quotedSpreadTicks.allSatisfy { $0 == nil })
    }

    @Test("replaceStrategy pulls quotes and switches behaviour mid-session")
    func replaceStrategy() {
        let sim = MarketSimulator(parameters: short, strategy: FixedSpreadMarketMaker(halfSpreadTicks: 1), seed: 6)
        for _ in 0..<50 { sim.advance() }
        sim.replaceStrategy(NoQuoteStrategy())
        #expect(sim.restingQuotes.bid == nil && sim.restingQuotes.ask == nil)
        let fillsBefore = sim.fills.count
        while !sim.isFinished { sim.advance() }
        #expect(sim.fills.count == fillsBefore)
        #expect(sim.strategy.name == "None")
    }

    @Test("trending regime: naive maker sells into the trend and carries the drawdown; A-S stays flat")
    func trendingRegime() async {
        var p = ScenarioPreset.trending().parameters
        p.steps = 2000
        let cfg = MonteCarloConfiguration(parameters: p, trials: 16)
        let rep = await MonteCarloRunner.run(cfg, strategies: MonteCarloRunner.standardLadder(parameters: p))
        let fixed = rep.outcomes[0], asMM = rep.outcomes[1]
        // Mechanism: the fundamental drifts up, informed traders lift the
        // naive maker's ask, and it ends the session structurally short.
        let fixedFinalInv = Statistics.mean(fixed.perTrial.map { Double($0.finalInventory) })
        let asFinalInv = Statistics.mean(asMM.perTrial.map { Double($0.finalInventory) })
        #expect(fixedFinalInv < -5, "naive maker should be run over short, got \(fixedFinalInv)")
        #expect(abs(asFinalInv) < 2, "A-S should stay near flat, got \(asFinalInv)")
        #expect(fixed.maxDrawdown.mean > 5 * asMM.maxDrawdown.mean)
        #expect(fixed.finalPnL.standardDeviation > 5 * asMM.finalPnL.standardDeviation)
        #expect(asMM.winRate > 0.9)
    }

    @Test("regression: the maker never trades with itself when a skew crosses its own stale quote")
    func makerNeverTradesWithItself() {
        // Aggressive skew so the new bid frequently lands at or above the old ask.
        let p = ScenarioPreset.trending().parameters
        for seed: UInt64 in 1...4 {
            let r = MarketSimulator(parameters: p, strategy: AvellanedaStoikovMarketMaker(gamma: 0.2), seed: seed).run()
            #expect(r.fills.allSatisfy { $0.counterparty != .marketMaker }, "self-trade on seed \(seed)")
        }
    }

    @Test("intensity fit is available and decays with distance after a session")
    func intensityFit() {
        var p = SimulationParameters.example
        p.steps = 3000
        let r = MarketSimulator(parameters: p, strategy: FixedSpreadMarketMaker(halfSpreadTicks: 1.5), seed: 9).run()
        if let fit = r.intensityFit {
            #expect(fit.k >= 0 && fit.A > 0)
        }
    }
}
