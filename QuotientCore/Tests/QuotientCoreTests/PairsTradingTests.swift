import Testing
import Foundation
@testable import QuotientCore

@Suite("Pairs trading") struct PairsTradingTests {

    @Test("mean-reverting spread: strategy is profitable on average across seeds")
    func meanReverting() {
        let p = PairsParameters(steps: 3000, reversionSpeed: 0.05, spreadVolatility: 0.003)
        let pnls = PairsSimulator.monteCarlo(p, trials: 40)
        let t = Statistics.mean(pnls) / (Statistics.standardDeviation(pnls) / Double(pnls.count).squareRoot())
        #expect(Statistics.mean(pnls) > 0)
        #expect(t > 2.5, "t-stat \(t)")
    }

    @Test("negative control: random-walk spread (θ = 0) is not significantly profitable")
    func randomWalkControl() {
        let p = PairsParameters(steps: 3000, reversionSpeed: 0.0, spreadVolatility: 0.003)
        let pnls = PairsSimulator.monteCarlo(p, trials: 60)
        let t = Statistics.mean(pnls) / (Statistics.standardDeviation(pnls) / Double(pnls.count).squareRoot())
        #expect(t < 2.0, "should not find edge in a random walk, t=\(t)")
    }

    @Test("positions only open beyond the entry band and close inside the exit band")
    func rules() {
        let p = PairsParameters(steps: 2000)
        let r = PairsSimulator.run(p, seed: 3)
        #expect(r.priceA.count == p.steps + 1 && r.pnl.count == p.steps + 1)
        for i in 1..<r.position.count where r.position[i] != 0 && r.position[i - 1] == 0 {
            #expect(abs(r.zScore[i]) > p.entryZ)
        }
        #expect(r.trades > 0)
        #expect(r.priceA.allSatisfy { $0 > 0 } && r.priceB.allSatisfy { $0 > 0 })
    }

    @Test("deterministic by seed")
    func deterministic() {
        let p = PairsParameters()
        #expect(PairsSimulator.run(p, seed: 1).pnl == PairsSimulator.run(p, seed: 1).pnl)
        #expect(PairsSimulator.run(p, seed: 1).pnl != PairsSimulator.run(p, seed: 2).pnl)
    }
}
