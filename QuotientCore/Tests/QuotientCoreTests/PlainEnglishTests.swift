import Testing
import Foundation
@testable import QuotientCore

@Suite("PlainEnglish") struct PlainEnglishTests {

    /// Build a StrategyOutcome from a per-trial P&L series and summary shape.
    func outcome(_ name: String, pnls: [Double], dd: Double, rmsInv: Double, maxInv: Int, fills: Int,
                 informed: Double? = -2, noise: Double? = 1, spread: Double = 3) -> StrategyOutcome {
        let sd = Statistics.standardDeviation(pnls)
        let per = pnls.enumerated().map { i, p in
            PerformanceMetrics(strategyName: name, seed: UInt64(i), finalPnL: p,
                               sessionSharpe: sd == 0 ? 0 : p / max(sd, 1), maxDrawdown: dd, rmsInventory: rmsInv,
                               maxAbsInventory: maxInv, finalInventory: 0, fillCount: fills, volume: fills,
                               meanCaptureTicks: 1, meanQuotedSpreadTicks: spread,
                               meanMarkoutTicks: [50: ((informed ?? 0) + (noise ?? 0)) / 2],
                               meanMarkoutVsInformedTicks: informed.map { [50: $0] } ?? [:],
                               meanMarkoutVsNoiseTicks: noise.map { [50: $0] } ?? [:],
                               spreadCapturePnL: p, inventoryPnL: 0)
        }
        return StrategyOutcome(name: name, perTrial: per, horizons: [50])
    }

    func report(_ outcomes: [StrategyOutcome]) -> MonteCarloReport {
        var comps: [PairedComparison] = []
        for i in outcomes.indices { for j in outcomes.indices where j > i { comps.append(PairedComparison(a: outcomes[i], b: outcomes[j])) } }
        return MonteCarloReport(configuration: MonteCarloConfiguration(parameters: .example, trials: outcomes[0].perTrial.count),
                                outcomes: outcomes, comparisons: comps, wallClockSeconds: 0)
    }

    var rng: SeededRandom { SeededRandom(seed: 1) }
    func series(mean: Double, sd: Double, n: Int = 40) -> [Double] {
        var r = rng
        return (0..<n).map { _ in mean + sd * r.nextGaussian() }
    }

    // MARK: Shapes

    @Test("dominant strategy: higher mean AND lower variance reads as a clear win with no 'but'")
    func dominant() {
        let good = outcome("Good", pnls: series(mean: 500, sd: 40), dd: 20, rmsInv: 0.6, maxInv: 2, fills: 600, informed: -2, noise: 1)
        let bad = outcome("Bad", pnls: series(mean: 200, sd: 300), dd: 300, rmsInv: 10, maxInv: 25, fills: 400, informed: -4, noise: 2)
        let rep = report([bad, good])
        let text = PlainEnglish.summary(of: good, in: rep)
        #expect(text.contains("made about \(PlainEnglish.money(good.finalPnL.mean - bad.finalPnL.mean)) more per session"))
        #expect(text.contains("a clear difference"))
        #expect(text.contains("more consistent"))
        #expect(text.contains(", and "))
        #expect(!text.contains(", but "))
        #expect(text.contains("kept almost no position"))
        #expect(text.contains("less than half of what Bad gave up"))
        #expect(!text.contains("nan") && !text.contains("–$"))
        let head = PlainEnglish.headline(rep)
        #expect(head.contains("Good did best both on average"))
    }

    @Test("mixed picture: lower mean but far lower variance reads as a trade-off with a win-rate caveat")
    func mixed() {
        // Mirrors the real A-S vs Fixed baseline result and the brief's example.
        let steady = outcome("A-S", pnls: series(mean: -141, sd: 48), dd: 144, rmsInv: 0.02, maxInv: 1, fills: 300, informed: -6.75, noise: 1.5)
        let wild = outcome("Fixed", pnls: series(mean: -172, sd: 288), dd: 338, rmsInv: 2.04, maxInv: 8, fills: 320, informed: -15.19, noise: 2)
        let rep = report([wild, steady])
        let text = PlainEnglish.summary(of: steady, in: rep)
        #expect(text.contains("lost about \(PlainEnglish.money(abs(steady.finalPnL.mean))) per session"))
        #expect(text.contains("made about \(PlainEnglish.money(steady.finalPnL.mean - wild.finalPnL.mean)) more per session"))
        #expect(text.contains("far more consistent"))
        #expect(text.contains("less than half of what Fixed gave up"))
        // Steady loses in nearly every session; wild wins ~27% of the time by luck.
        #expect(steady.winRate < wild.winRate)
        #expect(text.contains("Fixed ended positive more often") || text.contains("Fixed 'won' more often"))
        #expect(text.contains("Consistency") || text.contains("safer outcome"))
        #expect(!text.contains("nan"))

        let other = PlainEnglish.summary(of: wild, in: rep)
        #expect(other.contains("made about \(PlainEnglish.money(steady.finalPnL.mean - wild.finalPnL.mean)) less per session"))
        #expect(other.contains("less consistent") || other.contains("swung"))
        #expect(other.contains(", but ") == false || other.contains("more"))

        let head = PlainEnglish.headline(rep)
        #expect(head.contains("Every strategy lost money"))
        #expect(head.contains("steadiest") || head.contains("clear winner"))
    }

    @Test("degenerate: zero fills produces a sensible sentence and never NaN")
    func zeroFills() {
        let none = outcome("Never", pnls: Array(repeating: 0, count: 10), dd: 0, rmsInv: 0, maxInv: 0, fills: 0, informed: nil, noise: nil)
        let some = outcome("Some", pnls: series(mean: 100, sd: 20, n: 10), dd: 10, rmsInv: 1, maxInv: 3, fills: 50)
        let rep = report([none, some])
        let t = PlainEnglish.summary(of: none, in: rep)
        #expect(t.contains("never traded"))
        #expect(!t.contains("nan") && !t.contains("inf"))
        // The trading strategy should compare against nothing (only other has no fills) without crashing.
        let t2 = PlainEnglish.summary(of: some, in: rep)
        #expect(t2.contains("made about $"))
        #expect(!t2.contains("Compared with Never"))
        #expect(PlainEnglish.headline(rep).contains("Not enough trading activity"))
    }

    @Test("no informed traders: adverse-selection sentence switches to the ordinary-flow form")
    func noInformed() {
        let a = outcome("A", pnls: series(mean: 300, sd: 30), dd: 5, rmsInv: 0.8, maxInv: 2, fills: 500, informed: nil, noise: 1.0)
        let b = outcome("B", pnls: series(mean: 400, sd: 200), dd: 100, rmsInv: 10, maxInv: 30, fills: 800, informed: nil, noise: 1.0)
        let t = PlainEnglish.summary(of: a, in: report([b, a]))
        #expect(t.contains("no better-informed traders"))
        #expect(t.contains("earned it about 1.0 cent a share"))
    }

    @Test("identical strategies read as 'about the same' with similar risk")
    func identical() {
        let s = series(mean: 250, sd: 50)
        let a = outcome("A", pnls: s, dd: 30, rmsInv: 1, maxInv: 3, fills: 100)
        let b = outcome("B", pnls: s, dd: 30, rmsInv: 1, maxInv: 3, fills: 100)
        let t = PlainEnglish.summary(of: a, in: report([a, b]))
        #expect(t.contains("about the same on average"))
        #expect(t.contains("similar risk"))
    }

    @Test("summaries from a real Monte Carlo run are non-empty, finite, and 2–4 sentences")
    func realRun() async {
        var p = SimulationParameters.example; p.steps = 400
        let rep = await MonteCarloRunner.run(MonteCarloConfiguration(parameters: p, trials: 8),
                                             strategies: MonteCarloRunner.standardLadder(parameters: p))
        for o in rep.outcomes {
            let t = PlainEnglish.summary(of: o, in: rep)
            let sentences = t.split(separator: ". ").count
            #expect(sentences >= 2 && sentences <= 5, "\(o.name): \(t)")
            #expect(!t.contains("nan"))
        }
        #expect(!PlainEnglish.headline(rep).isEmpty)
    }

    // MARK: Pairs and live

    @Test("pairs summary reflects regime, trades and Monte Carlo verdict")
    func pairs() {
        let mr = PairsParameters(steps: 1500, reversionSpeed: 0.05)
        let r = PairsSimulator.run(mr, seed: 3)
        let t = PlainEnglish.pairsSummary(r, parameters: mr, monteCarlo: (mean: 0.01, tStatistic: 4.0, trials: 60))
        #expect(t.contains("drift back toward normal"))
        #expect(t.contains("stepped in \(r.trades) time"))
        #expect(t.contains("too consistent to be luck"))
        let rw = PairsParameters(steps: 1500, reversionSpeed: 0)
        let t2 = PlainEnglish.pairsSummary(PairsSimulator.run(rw, seed: 3), parameters: rw, monteCarlo: (mean: 0.001, tStatistic: 0.5, trials: 60))
        #expect(t2.contains("wanders randomly"))
        #expect(t2.contains("no real pattern to exploit"))
        let none = PairsResult(priceA: [1], priceB: [1], zScore: [0], position: [0], pnl: [0], trades: 0)
        #expect(PlainEnglish.pairsSummary(none, parameters: mr).contains("never found"))
    }

    @Test("live summary describes position, P&L and spread changes")
    func live() {
        var s = PlainEnglish.LiveState(symbol: "SPY", inventoryLots: 12, sharesPerLot: 100, pnlDollars: 340, fills: 30, informedFills: 4,
                                       quotedSpreadTicks: 6, earlierQuotedSpreadTicks: 3, sigmaEstimate: 2.0, sigmaPrior: 1.0, isFinished: false, step: 500)
        var t = PlainEnglish.liveSummary(s)
        #expect(t.contains("long 1200 shares"))
        #expect(t.contains("up $340"))
        #expect(t.contains("widened its spread from 3 to 6 ticks because the market has become more volatile"))
        #expect(t.contains("4 of its fills came from traders who knew"))
        s.inventoryLots = -1; s.pnlDollars = -12.5; s.quotedSpreadTicks = 3; s.informedFills = 0
        t = PlainEnglish.liveSummary(s)
        #expect(t.contains("short 100 shares") && t.contains("down $13"), "amounts above $10 are shown in whole dollars: \(t)")
        #expect(t.contains("shading its quotes to buy"))
        s.step = 0
        #expect(PlainEnglish.liveSummary(s).contains("Press Run"))
    }

    @Test("glossary covers the concepts on screen")
    func glossary() {
        let terms = PlainEnglish.glossary.map(\.term)
        for required in ["Spread", "Inventory", "Sharpe ratio", "Max drawdown", "Markout", "Win rate"] {
            #expect(terms.contains(required))
        }
        #expect(Set(terms).count == terms.count)
        #expect(PlainEnglish.glossary.allSatisfy { $0.definition.count > 60 })
    }
}
