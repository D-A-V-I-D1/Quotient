import Testing
import Foundation
@testable import QuotientCore

@Suite("Statistics & RNG") struct StatisticsTests {

    @Test("seeded RNG is deterministic and copies stay in lockstep")
    func determinism() {
        var a = SeededRandom(seed: 123)
        var b = SeededRandom(seed: 123)
        for _ in 0..<1000 { #expect(a.next() == b.next()) }
        var c = a
        #expect(a.nextGaussian() == c.nextGaussian())
        var d = SeededRandom(seed: 124)
        #expect(a.next() != d.next())
    }

    @Test("derived streams differ from each other and from the parent")
    func derivedStreams() {
        let root = SeededRandom(seed: 5)
        var s1 = root.derived(stream: 1)
        var s2 = root.derived(stream: 2)
        var r = root
        #expect(s1.next() != s2.next())
        #expect(s1.next() != r.next())
    }

    @Test("gaussian has unit variance and zero mean (10⁵ samples)")
    func gaussianMoments() {
        var rng = SeededRandom(seed: 9)
        let xs = (0..<100_000).map { _ in rng.nextGaussian() }
        #expect(abs(Statistics.mean(xs)) < 0.02)
        #expect(abs(Statistics.standardDeviation(xs) - 1) < 0.02)
    }

    @Test("poisson and geometric have the right means")
    func discreteMoments() {
        var rng = SeededRandom(seed: 11)
        let pois = (0..<50_000).map { _ in Double(rng.nextPoisson(mean: 3.5)) }
        #expect(abs(Statistics.mean(pois) - 3.5) < 0.05)
        let geo = (0..<50_000).map { _ in Double(rng.nextGeometric(successProbability: 0.25)) }
        #expect(abs(Statistics.mean(geo) - 4.0) < 0.06)
        let big = (0..<20_000).map { _ in Double(rng.nextPoisson(mean: 80)) }
        #expect(abs(Statistics.mean(big) - 80) < 0.5)
    }

    @Test("descriptive statistics")
    func descriptive() {
        let xs = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
        #expect(Statistics.mean(xs) == 5)
        #expect(abs(Statistics.variance(xs) - 32.0 / 7.0) < 1e-12)
        #expect(Statistics.rootMeanSquare([3, -4]) == 12.5.squareRoot())
        #expect(Statistics.maxDrawdown([0, 10, 5, 12, 2, 8]) == 10)
        #expect(Statistics.maxDrawdown([1, 2, 3]) == 0)
        #expect(abs(Statistics.correlation([1, 2, 3, 4], [2, 4, 6, 8]) - 1) < 1e-12)
        let (a, b) = Statistics.linearRegression(x: [0, 1, 2, 3], y: [1, 3, 5, 7])
        #expect(abs(a - 1) < 1e-12 && abs(b - 2) < 1e-12)
    }

    @Test("Student t CDF matches known values")
    func studentT() {
        // t(0) = 0.5 for any df; t_{0.975, df=10} = 2.228; large df → normal.
        #expect(abs(Statistics.studentTCDF(0, degreesOfFreedom: 5) - 0.5) < 1e-9)
        #expect(abs(Statistics.studentTQuantile(0.975, degreesOfFreedom: 10) - 2.228) < 0.002)
        #expect(abs(Statistics.studentTQuantile(0.975, degreesOfFreedom: 1_000) - 1.962) < 0.002)
        #expect(abs(Statistics.studentTCDF(1.96, degreesOfFreedom: 1e6) - Statistics.normalCDF(1.96)) < 1e-4)
    }

    @Test("paired t-test detects a shift and not its absence")
    func pairedTTest() {
        var rng = SeededRandom(seed: 3)
        let base = (0..<60).map { _ in rng.nextGaussian() * 10 }
        let shifted = base.map { $0 + 1 + rng.nextGaussian() * 0.5 }
        let same = base.map { $0 + rng.nextGaussian() * 0.5 }
        let t1 = Statistics.pairedTTest(shifted, base)!
        #expect(t1.pValue < 0.001)
        #expect(t1.meanDifference > 0.8 && t1.meanDifference < 1.2)
        #expect(t1.confidenceInterval95.contains(1.0))
        let t2 = Statistics.pairedTTest(same, base)!
        #expect(t2.pValue > 0.05)
        #expect(Statistics.pairedTTest([1.0], [2.0]) == nil)
        // Identical series: zero difference, p = 1.
        let t3 = Statistics.pairedTTest(base, base)!
        #expect(t3.pValue == 1 && t3.tStatistic == 0)
    }

    @Test("regularized incomplete beta edge cases")
    func incompleteBeta() {
        #expect(Statistics.regularizedIncompleteBeta(0, a: 2, b: 3) == 0)
        #expect(Statistics.regularizedIncompleteBeta(1, a: 2, b: 3) == 1)
        // I_0.5(1,1) = 0.5 (uniform).
        #expect(abs(Statistics.regularizedIncompleteBeta(0.5, a: 1, b: 1) - 0.5) < 1e-9)
    }
}
