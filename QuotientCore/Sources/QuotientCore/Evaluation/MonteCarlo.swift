//
//  MonteCarlo.swift
//  QuotientCore
//
//  Paired Monte Carlo evaluation.
//
//  For trial i with seed s_i, EVERY strategy is run on a fresh simulator
//  seeded with s_i. Because the simulator's randomness is independent of the
//  strategy (see MarketSimulator header), strategy A and strategy B face the
//  same market in trial i, and the difference in their outcomes is attributable
//  to the strategies alone. Differences are then tested with a paired t-test.
//
//  WHY not just run each strategy 500 times and compare means: the variance of
//  a single session's P&L is dominated by the market path (did a jump happen?
//  which way did flow lean?). Pairing removes that common component and gives
//  an honest, much tighter estimate of the strategy effect.
//

import Foundation

public struct MonteCarloConfiguration: Sendable {
    public var parameters: SimulationParameters
    public var trials: Int
    public var baseSeed: UInt64

    public init(parameters: SimulationParameters, trials: Int = 200, baseSeed: UInt64 = 20_260_928) {
        precondition(trials >= 1)
        self.parameters = parameters
        self.trials = trials
        self.baseSeed = baseSeed
    }

    public func seed(forTrial i: Int) -> UInt64 { baseSeed &+ UInt64(i) &* 0x9E37_79B9 }
}

/// Distributional summary of one metric across trials.
public struct MetricSummary: Sendable, Equatable {
    public let mean: Double
    public let standardDeviation: Double
    public let min: Double
    public let max: Double
    public let median: Double
    /// 95% CI for the mean (normal approximation, n ≥ 30 typical).
    public let confidenceInterval95: ClosedRange<Double>

    public init(_ xs: [Double]) {
        let sorted = xs.sorted()
        mean = Statistics.mean(xs)
        standardDeviation = Statistics.standardDeviation(xs)
        min = sorted.first ?? 0
        max = sorted.last ?? 0
        median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let se = xs.count > 1 ? standardDeviation / Double(xs.count).squareRoot() : 0
        confidenceInterval95 = (mean - 1.96 * se)...(mean + 1.96 * se)
    }
}

/// Aggregate results for one strategy over all trials.
public struct StrategyOutcome: Sendable {
    public let name: String
    public let perTrial: [PerformanceMetrics]
    public let finalPnL: MetricSummary
    public let sessionSharpe: MetricSummary
    public let maxDrawdown: MetricSummary
    public let rmsInventory: MetricSummary
    public let maxAbsInventory: MetricSummary
    public let fillCount: MetricSummary
    public let meanCaptureTicks: MetricSummary
    public let meanQuotedSpreadTicks: MetricSummary
    /// Mean-of-means markout per horizon, ticks.
    public let meanMarkoutTicks: [Int: MetricSummary]
    public let meanMarkoutVsInformedTicks: [Int: MetricSummary]
    public let meanMarkoutVsNoiseTicks: [Int: MetricSummary]
    public let spreadCapturePnL: MetricSummary
    public let inventoryPnL: MetricSummary
    /// Fraction of trials with positive final P&L.
    public let winRate: Double

    init(name: String, perTrial: [PerformanceMetrics], horizons: [Int]) {
        self.name = name
        self.perTrial = perTrial
        finalPnL = MetricSummary(perTrial.map(\.finalPnL))
        sessionSharpe = MetricSummary(perTrial.map(\.sessionSharpe))
        maxDrawdown = MetricSummary(perTrial.map(\.maxDrawdown))
        rmsInventory = MetricSummary(perTrial.map(\.rmsInventory))
        maxAbsInventory = MetricSummary(perTrial.map { Double($0.maxAbsInventory) })
        fillCount = MetricSummary(perTrial.map { Double($0.fillCount) })
        meanCaptureTicks = MetricSummary(perTrial.map(\.meanCaptureTicks))
        meanQuotedSpreadTicks = MetricSummary(perTrial.map(\.meanQuotedSpreadTicks))
        spreadCapturePnL = MetricSummary(perTrial.map(\.spreadCapturePnL))
        inventoryPnL = MetricSummary(perTrial.map(\.inventoryPnL))
        var m: [Int: MetricSummary] = [:], mi: [Int: MetricSummary] = [:], mn: [Int: MetricSummary] = [:]
        for h in horizons {
            let a = perTrial.compactMap { $0.meanMarkoutTicks[h] }
            if !a.isEmpty { m[h] = MetricSummary(a) }
            let b = perTrial.compactMap { $0.meanMarkoutVsInformedTicks[h] }
            if !b.isEmpty { mi[h] = MetricSummary(b) }
            let c = perTrial.compactMap { $0.meanMarkoutVsNoiseTicks[h] }
            if !c.isEmpty { mn[h] = MetricSummary(c) }
        }
        meanMarkoutTicks = m
        meanMarkoutVsInformedTicks = mi
        meanMarkoutVsNoiseTicks = mn
        winRate = perTrial.isEmpty ? 0 : Double(perTrial.filter { $0.finalPnL > 0 }.count) / Double(perTrial.count)
    }
}

/// Paired comparison of strategy `a` minus strategy `b` on each metric.
public struct PairedComparison: Sendable {
    public let a: String
    public let b: String
    public let finalPnL: Statistics.PairedTTest?
    public let maxDrawdown: Statistics.PairedTTest?
    public let rmsInventory: Statistics.PairedTTest?
    public let sessionSharpe: Statistics.PairedTTest?
    /// Fraction of trials in which `a` beat `b` on final P&L.
    public let aWinsFraction: Double

    init(a: StrategyOutcome, b: StrategyOutcome) {
        self.a = a.name
        self.b = b.name
        let pa = a.perTrial, pb = b.perTrial
        finalPnL = Statistics.pairedTTest(pa.map(\.finalPnL), pb.map(\.finalPnL))
        maxDrawdown = Statistics.pairedTTest(pa.map(\.maxDrawdown), pb.map(\.maxDrawdown))
        rmsInventory = Statistics.pairedTTest(pa.map(\.rmsInventory), pb.map(\.rmsInventory))
        sessionSharpe = Statistics.pairedTTest(pa.map(\.sessionSharpe), pb.map(\.sessionSharpe))
        let wins = zip(pa, pb).filter { $0.finalPnL > $1.finalPnL }.count
        aWinsFraction = pa.isEmpty ? 0 : Double(wins) / Double(pa.count)
    }
}

public struct MonteCarloReport: Sendable {
    public let configuration: MonteCarloConfiguration
    public let outcomes: [StrategyOutcome]
    /// All ordered pairs (i, j) with i < j in `outcomes` order.
    public let comparisons: [PairedComparison]
    public let wallClockSeconds: Double

    public func outcome(named name: String) -> StrategyOutcome? { outcomes.first { $0.name == name } }
    public func comparison(_ a: String, _ b: String) -> PairedComparison? {
        comparisons.first { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }
    }
}

public enum MonteCarloRunner {

    /// Run all strategies across all trials. Trials run concurrently; within a
    /// trial, strategies run sequentially on identically-seeded simulators.
    ///
    /// `progress` receives the fraction of trials completed (on an arbitrary thread).
    public static func run(_ config: MonteCarloConfiguration,
                           strategies: [any MarketMakingStrategy],
                           progress: (@Sendable (Double) -> Void)? = nil) async -> MonteCarloReport {
        precondition(!strategies.isEmpty)
        let start = Date()
        let names = strategies.map(\.name)
        precondition(Set(names).count == names.count, "strategy names must be unique")

        // perTrial[trial][strategyIndex]
        var perTrial = [[PerformanceMetrics]?](repeating: nil, count: config.trials)
        var completed = 0

        await withTaskGroup(of: (Int, [PerformanceMetrics]).self) { group in
            // Bound concurrency to the core count so memory stays flat.
            let width = max(1, ProcessInfo.processInfo.activeProcessorCount)
            var next = 0
            func enqueue() {
                guard next < config.trials else { return }
                let i = next; next += 1
                group.addTask {
                    (i, runTrial(config, strategies: strategies, trial: i))
                }
            }
            for _ in 0..<min(width, config.trials) { enqueue() }
            for await (i, metrics) in group {
                perTrial[i] = metrics
                completed += 1
                progress?(Double(completed) / Double(config.trials))
                enqueue()
            }
        }

        let horizons = config.parameters.markoutHorizons
        let outcomes = strategies.indices.map { s in
            StrategyOutcome(name: names[s], perTrial: perTrial.map { $0![s] }, horizons: horizons)
        }
        var comparisons: [PairedComparison] = []
        for i in outcomes.indices {
            for j in outcomes.indices where j > i {
                comparisons.append(PairedComparison(a: outcomes[i], b: outcomes[j]))
            }
        }
        return MonteCarloReport(configuration: config, outcomes: outcomes, comparisons: comparisons,
                                wallClockSeconds: Date().timeIntervalSince(start))
    }

    /// One trial: every strategy on the same seed.
    public static func runTrial(_ config: MonteCarloConfiguration,
                                strategies: [any MarketMakingStrategy],
                                trial: Int) -> [PerformanceMetrics] {
        let seed = config.seed(forTrial: trial)
        return strategies.map { strategy in
            let sim = MarketSimulator(parameters: config.parameters, strategy: strategy, seed: seed)
            return PerformanceMetrics(result: sim.run())
        }
    }
}
