import Testing
import Foundation
@testable import QuotientCore

@Suite("Strategies") struct StrategyTests {

    func state(mid: Double = 10_000, micro: Double? = nil, inventory: Int = 0, sigma: Double = 0.5,
               step: Int = 0, total: Int = 1000) -> MarketState {
        MarketState(step: step, totalSteps: total, midTicks: mid, micropriceTicks: micro ?? mid,
                    imbalance: 0, orderFlowImbalance: 0, spreadTicks: 2, inventory: inventory,
                    sigmaTicksPerStep: sigma, bestBid: Ticks(mid) - 1, bestAsk: Ticks(mid) + 1)
    }

    // MARK: Fixed spread

    @Test("fixed spread is symmetric around the mid and ignores inventory")
    func fixedSymmetric() {
        var s = FixedSpreadMarketMaker(halfSpreadTicks: 2)
        let flat = s.quotes(for: state())
        let long = s.quotes(for: state(inventory: 50))
        #expect(flat.bidPrice == 9_998 && flat.askPrice == 10_002)
        #expect(flat == long, "no skew whatsoever")
    }

    @Test("fixed spread never locks or crosses on a half-tick mid")
    func fixedNoLock() {
        var s = FixedSpreadMarketMaker(halfSpreadTicks: 0.5)
        let q = s.quotes(for: state(mid: 10_000.5))
        #expect(q.isValid)
        #expect(q.askPrice! - q.bidPrice! >= 1)
    }

    @Test("fixed spread with inventory cap drops the accumulating side")
    func fixedCap() {
        var s = FixedSpreadMarketMaker(halfSpreadTicks: 1, maxInventory: 5)
        #expect(s.quotes(for: state(inventory: 5)).bidPrice == nil)
        #expect(s.quotes(for: state(inventory: 5)).askPrice != nil)
        #expect(s.quotes(for: state(inventory: -5)).askPrice == nil)
    }

    // MARK: Avellaneda–Stoikov

    @Test("A-S formulas match the paper at hand-computed values")
    func formulas() {
        let s = AvellanedaStoikovMarketMaker(gamma: 0.1, k: 1.5, horizon: .rolling(steps: 100))
        // r = s − q γ σ² τ = 10000 − 3·0.1·0.25·100 = 10000 − 7.5
        #expect(abs(s.reservationPrice(reference: 10_000, inventory: 3, sigma: 0.5, timeRemaining: 100) - 9_992.5) < 1e-9)
        // δ = γσ²τ + (2/γ) ln(1+γ/k) = 2.5 + 20·ln(1.0667) = 2.5 + 1.2908
        let spread = s.optimalSpread(sigma: 0.5, timeRemaining: 100)
        #expect(abs(spread - (2.5 + 20 * log(1 + 0.1 / 1.5))) < 1e-9)
    }

    @Test("long inventory skews both quotes down; short skews up; flat is symmetric")
    func skewDirection() {
        var s = AvellanedaStoikovMarketMaker(gamma: 0.05, k: 1, horizon: .rolling(steps: 200))
        let flat = s.quotes(for: state())
        let long = s.quotes(for: state(inventory: 4))
        let short = s.quotes(for: state(inventory: -4))
        #expect(long.bidPrice! < flat.bidPrice! && long.askPrice! < flat.askPrice!)
        #expect(short.bidPrice! > flat.bidPrice! && short.askPrice! > flat.askPrice!)
        let mid = 10_000.0
        #expect(abs((Double(flat.bidPrice!) + Double(flat.askPrice!)) / 2 - mid) <= 0.5)
    }

    @Test("spread widens with volatility and with risk aversion, tightens with k")
    func spreadMonotone() {
        let base = AvellanedaStoikovMarketMaker(gamma: 0.05, k: 1, horizon: .rolling(steps: 200))
        let lowVol = base.optimalSpread(sigma: 0.3, timeRemaining: 200)
        let highVol = base.optimalSpread(sigma: 0.9, timeRemaining: 200)
        #expect(highVol > lowVol)
        let braver = AvellanedaStoikovMarketMaker(gamma: 0.01, k: 1, horizon: .rolling(steps: 200))
        #expect(braver.optimalSpread(sigma: 0.5, timeRemaining: 200) < base.optimalSpread(sigma: 0.5, timeRemaining: 200))
        let liquid = AvellanedaStoikovMarketMaker(gamma: 0.05, k: 3, horizon: .rolling(steps: 200))
        #expect(liquid.optimalSpread(sigma: 0.5, timeRemaining: 200) < base.optimalSpread(sigma: 0.5, timeRemaining: 200))
    }

    @Test("finite horizon: skew and spread shrink as the session ends")
    func finiteHorizon() {
        var s = AvellanedaStoikovMarketMaker(gamma: 0.05, k: 1, horizon: .finite)
        let early = s.quotes(for: state(inventory: 5, step: 0, total: 1000))
        let late = s.quotes(for: state(inventory: 5, step: 999, total: 1000))
        #expect(early.askPrice! - early.bidPrice! > late.askPrice! - late.bidPrice!)
        // At the very end the reservation price ≈ mid, so the quote is nearly symmetric.
        let lateCentre = (Double(late.bidPrice!) + Double(late.askPrice!)) / 2
        #expect(abs(lateCentre - 10_000) <= 1)
        let earlyCentre = (Double(early.bidPrice!) + Double(early.askPrice!)) / 2
        #expect(earlyCentre < lateCentre)
    }

    @Test("minimum spread is enforced")
    func minimumSpread() {
        var s = AvellanedaStoikovMarketMaker(gamma: 0.001, k: 100, horizon: .rolling(steps: 1), minimumSpreadTicks: 2)
        let q = s.quotes(for: state(sigma: 0.01))
        #expect(q.askPrice! - q.bidPrice! >= 2)
        #expect(q.isValid)
    }

    @Test("microprice reference shifts the quotes in the direction of the signal")
    func micropriceReference() {
        var mid = AvellanedaStoikovMarketMaker(gamma: 0.01, k: 1, referencePrice: .mid)
        var micro = AvellanedaStoikovMarketMaker(gamma: 0.01, k: 1, referencePrice: .microprice)
        let st = state(mid: 10_000, micro: 10_001.4)
        let a = mid.quotes(for: st), b = micro.quotes(for: st)
        #expect(b.bidPrice! >= a.bidPrice! && b.askPrice! >= a.askPrice!)
        #expect(b != a)
        #expect(mid.name != micro.name)
    }

    @Test("inventory cap")
    func asCap() {
        var s = AvellanedaStoikovMarketMaker(maxInventory: 3)
        #expect(s.quotes(for: state(inventory: 3)).bidPrice == nil)
        #expect(s.quotes(for: state(inventory: -3)).askPrice == nil)
        #expect(s.quotes(for: state(inventory: 2)).bidPrice != nil)
    }

    @Test("matched fixed-spread control has the same total spread as A-S at q = 0")
    func matched() {
        let asMM = AvellanedaStoikovMarketMaker(gamma: 0.02, k: 1.2, horizon: .rolling(steps: 300))
        let fixed = FixedSpreadMarketMaker.matched(to: asMM, sigma: 0.5, horizonSteps: 300)
        #expect(abs(fixed.halfSpreadTicks * 2 - asMM.optimalSpread(sigma: 0.5, timeRemaining: 300)) < 1e-12)
        #expect(fixed.sizeLots == asMM.sizeLots)
    }

    // MARK: Manual

    @Test("manual maker applies skew and can pull one side")
    func manual() {
        var m = ManualMarketMaker(halfSpreadTicks: 2, skewTicks: 1)
        let q = m.quotes(for: state())
        #expect(q.bidPrice == 9_997 && q.askPrice == 10_001)
        m.quoteAsk = false
        #expect(m.quotes(for: state()).askPrice == nil)
        m.sizeLots = 0
        #expect(m.quotes(for: state()) .bidPrice == nil)
    }

    @Test("QuoteIntent validity")
    func intentValidity() {
        #expect(QuoteIntent(bidPrice: 10, askPrice: 11, bidSize: 1, askSize: 1).isValid)
        #expect(QuoteIntent(bidPrice: 11, askPrice: 11, bidSize: 1, askSize: 1).isValid == false)
        #expect(QuoteIntent(bidPrice: nil, askPrice: 11, bidSize: 1, askSize: 1).isValid)
    }
}
