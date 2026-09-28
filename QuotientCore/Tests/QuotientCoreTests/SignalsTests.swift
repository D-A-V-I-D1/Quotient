import Testing
import Foundation
@testable import QuotientCore

@Suite("Signals") struct SignalsTests {

    /// Build a book with one level per side.
    func book(bid: Ticks, bidQty: Int, ask: Ticks, askQty: Int) -> OrderBook {
        let b = OrderBook()
        b.submitLimit(side: .bid, price: bid, quantity: bidQty, owner: .noiseTrader)
        b.submitLimit(side: .ask, price: ask, quantity: askQty, owner: .noiseTrader)
        return b
    }

    @Test("imbalance and bid share")
    func imbalance() {
        let b = book(bid: 100, bidQty: 3, ask: 101, askQty: 1)
        #expect(Signals.imbalance(b) == 0.5)
        #expect(Signals.bidShare(b) == 0.75)
        #expect(Signals.imbalance(OrderBook()) == nil)
    }

    @Test("weighted mid leans toward the ask when the bid is heavy")
    func weightedMid() {
        let heavyBid = book(bid: 100, bidQty: 3, ask: 101, askQty: 1)
        #expect(Signals.weightedMid(heavyBid) == 100.75)
        let heavyAsk = book(bid: 100, bidQty: 1, ask: 101, askQty: 3)
        #expect(Signals.weightedMid(heavyAsk) == 100.25)
        let balanced = book(bid: 100, bidQty: 2, ask: 101, askQty: 2)
        #expect(Signals.weightedMid(balanced) == balanced.midTicks)
    }

    @Test("OFI: bid size increase at same price is positive; ask increase is negative")
    func orderFlowImbalance() {
        var ofi = OrderFlowImbalance(windowLength: 10)
        ofi.observe(BestQuotes(bidPrice: 100, bidQuantity: 5, askPrice: 101, askQuantity: 5))
        #expect(ofi.value == 0)
        // Bid grows 5 -> 8 at the same price: e = +8 − 5 = +3; ask unchanged: −5 + 5 = 0.
        ofi.observe(BestQuotes(bidPrice: 100, bidQuantity: 8, askPrice: 101, askQuantity: 5))
        #expect(ofi.value == 3)
        // Ask grows 5 -> 9: −9 + 5 = −4; bid unchanged 0. Cumulative −1.
        ofi.observe(BestQuotes(bidPrice: 100, bidQuantity: 8, askPrice: 101, askQuantity: 9))
        #expect(ofi.value == -1)
        // Bid price ticks up: e_bid = +new qty (indicator P_b ≥ prev) = +2, minus nothing (P_b > prev). Ask same.
        ofi.observe(BestQuotes(bidPrice: 101, bidQuantity: 2, askPrice: 102, askQuantity: 9))
        // ask price up: 1{Pa <= prev}=0 → 0; 1{Pa >= prev}=1 → +9. Total e = 2 + 9 = 11 → cumulative 10.
        #expect(ofi.value == 10)
        ofi.reset()
        #expect(ofi.value == 0)
    }

    @Test("OFI window drops old contributions")
    func ofiWindow() {
        var ofi = OrderFlowImbalance(windowLength: 2)
        ofi.observe(BestQuotes(bidPrice: 100, bidQuantity: 1, askPrice: 101, askQuantity: 1))
        ofi.observe(BestQuotes(bidPrice: 100, bidQuantity: 4, askPrice: 101, askQuantity: 1)) // +3
        ofi.observe(BestQuotes(bidPrice: 100, bidQuantity: 4, askPrice: 101, askQuantity: 1)) // 0
        ofi.observe(BestQuotes(bidPrice: 100, bidQuantity: 4, askPrice: 101, askQuantity: 1)) // 0, drops +3
        #expect(ofi.value == 0)
    }

    @Test("volatility estimator converges to the true σ of a random walk")
    func volatility() {
        var rng = SeededRandom(seed: 21)
        var est = VolatilityEstimator(halfLife: 200, prior: 1.0, warmup: 20)
        #expect(est.sigma == 1.0, "prior until warm")
        var mid = 1000.0
        for _ in 0..<5000 {
            mid += 0.5 * rng.nextGaussian()
            est.observe(mid: mid)
        }
        #expect(est.isWarm)
        #expect(abs(est.sigma - 0.5) < 0.08)
    }

    @Test("intensity calibrator recovers A and k from exponential fill rates")
    func intensityFit() {
        var cal = IntensityCalibrator()
        let A = 0.8, k = 0.7
        for d in 0...6 {
            let rate = A * exp(-k * Double(d))
            cal.record(distance: d, fills: Int((rate * 10_000).rounded()), exposure: 10_000)
        }
        let fit = cal.fit()!
        #expect(abs(fit.A - A) < 0.02)
        #expect(abs(fit.k - k) < 0.02)
        #expect(IntensityCalibrator().fit() == nil)
    }

    @Test("microprice estimator learns that heavy bids precede up-moves")
    func micropriceLearns() {
        // Synthetic market: state alternates between heavy-bid (I=0.8) and
        // heavy-ask (I=0.2). From heavy-bid the mid ticks up w.p. 0.6, from
        // heavy-ask it ticks down w.p. 0.6, else unchanged. Truth: G¹(0.8) > 0.
        var rng = SeededRandom(seed: 99)
        var est = MicropriceEstimator(configuration: .init(imbalanceBuckets: 5, maxSpreadTicks: 1, horizonMidChanges: 3, minimumObservations: 200))
        var bid: Ticks = 1000
        var heavyBid = true
        for _ in 0..<6000 {
            let b = book(bid: bid, bidQty: heavyBid ? 8 : 2, ask: bid + 1, askQty: heavyBid ? 2 : 8)
            est.observe(b)
            // Transition
            let move = rng.nextBool(probability: 0.6)
            if move { bid += heavyBid ? 1 : -1 }
            heavyBid = rng.nextBool(probability: 0.5)
        }
        #expect(est.hasEnoughData)
        let fitted = est.refit()
        #expect(fitted)
        #expect(est.isFitted)
        let up = est.adjustment(bidShare: 0.8, spreadTicks: 1)!
        let down = est.adjustment(bidShare: 0.2, spreadTicks: 1)!
        #expect(up > 0.2, "heavy bid → positive adjustment, got \(up)")
        #expect(down < -0.2, "heavy ask → negative adjustment, got \(down)")
        // Microprice should now exceed the mid in the heavy-bid state.
        let hb = book(bid: 500, bidQty: 8, ask: 501, askQty: 2)
        #expect(est.microprice(hb)! > hb.midTicks!)
    }

    @Test("microprice falls back to weighted mid before it has data")
    func micropriceFallback() {
        let est = MicropriceEstimator()
        let b = book(bid: 100, bidQty: 3, ask: 101, askQty: 1)
        #expect(est.isFitted == false)
        #expect(est.microprice(b) == Signals.weightedMid(b))
    }

    @Test("linear algebra: inverse of a known matrix")
    func inverse() {
        // [[4,7],[2,6]]⁻¹ = [[0.6,-0.7],[-0.2,0.4]]
        let inv = LinearAlgebra.invert([4, 7, 2, 6], n: 2)!
        let expected = [0.6, -0.7, -0.2, 0.4]
        for i in 0..<4 { #expect(abs(inv[i] - expected[i]) < 1e-12) }
        #expect(LinearAlgebra.invert([1, 2, 2, 4], n: 2) == nil, "singular")
        let v = LinearAlgebra.multiply([1, 2, 3, 4], [1, 1], n: 2)
        #expect(v == [3, 7])
        let m = LinearAlgebra.multiplyMatrices([1, 2, 3, 4], [1, 0, 0, 1], n: 2)
        #expect(m == [1, 2, 3, 4])
    }
}
