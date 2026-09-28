import Testing
import Foundation
@testable import QuotientCore

@Suite("Evaluation") struct EvaluationTests {

    var p: SimulationParameters { var p = SimulationParameters.example; p.steps = 400; return p }

    @Test("Monte Carlo is deterministic and paired: identical strategies give zero difference")
    func pairedIdentical() async {
        let cfg = MonteCarloConfiguration(parameters: p, trials: 6, baseSeed: 1)
        // Two instances of the same strategy under different names.
        struct Renamed: MarketMakingStrategy {
            var inner: FixedSpreadMarketMaker; let name: String
            var summary: String { inner.summary }
            mutating func quotes(for s: MarketState) -> QuoteIntent { inner.quotes(for: s) }
        }
        let a = Renamed(inner: FixedSpreadMarketMaker(halfSpreadTicks: 1), name: "A")
        let b = Renamed(inner: FixedSpreadMarketMaker(halfSpreadTicks: 1), name: "B")
        let rep = await MonteCarloRunner.run(cfg, strategies: [a, b])
        let c = rep.comparisons[0]
        #expect(c.finalPnL!.meanDifference == 0)
        #expect(c.finalPnL!.pValue == 1)
        #expect(c.aWinsFraction == 0)
        let rep2 = await MonteCarloRunner.run(cfg, strategies: [a, b])
        #expect(rep.outcomes[0].finalPnL == rep2.outcomes[0].finalPnL)
    }

    @Test("per-trial results are ordered by trial index regardless of completion order")
    func ordering() async {
        let cfg = MonteCarloConfiguration(parameters: p, trials: 10)
        let rep = await MonteCarloRunner.run(cfg, strategies: [FixedSpreadMarketMaker(halfSpreadTicks: 1)])
        for (i, m) in rep.outcomes[0].perTrial.enumerated() {
            #expect(m.seed == cfg.seed(forTrial: i))
        }
    }

    @Test("progress callback reaches 1.0")
    func progress() async {
        let cfg = MonteCarloConfiguration(parameters: p, trials: 4)
        final class Box: @unchecked Sendable { var last = 0.0; let lock = NSLock() }
        let box = Box()
        _ = await MonteCarloRunner.run(cfg, strategies: [FixedSpreadMarketMaker(halfSpreadTicks: 1)]) { f in
            box.lock.lock(); box.last = max(box.last, f); box.lock.unlock()
        }
        #expect(box.last == 1.0)
    }

    @Test("MetricSummary basics")
    func summary() {
        let s = MetricSummary([1, 2, 3, 4, 5])
        #expect(s.mean == 3 && s.min == 1 && s.max == 5 && s.median == 3)
        #expect(s.confidenceInterval95.contains(3))
    }

    @Test("markdown report renders every strategy and comparison")
    func report() async {
        let cfg = MonteCarloConfiguration(parameters: p, trials: 3)
        let rep = await MonteCarloRunner.run(cfg, strategies: MonteCarloRunner.standardLadder(parameters: p))
        let md = ReportGenerator.markdown(rep, title: "T", scenarioSummary: "S")
        #expect(md.contains("### T"))
        for o in rep.outcomes { #expect(md.contains("| \(o.name) |")) }
        #expect(md.components(separatedBy: "\n").filter { $0.hasPrefix("| Fixed Spread | Avellaneda-Stoikov") }.count == 1)
    }

    @Test("scenario presets differ from the base only in the documented knobs")
    func presets() {
        let all = ScenarioPreset.all()
        #expect(all.count == 5)
        #expect(Set(all.map(\.name)).count == 5)
        #expect(ScenarioPreset.inventoryOnly().parameters.informedFraction == 0)
        #expect(ScenarioPreset.trending().parameters.fundamentalDriftTicks > 0)
        #expect(ScenarioPreset.baseline().parameters == .example)
    }
}
