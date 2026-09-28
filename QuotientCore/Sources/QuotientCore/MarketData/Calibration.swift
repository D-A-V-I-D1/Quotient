//
//  Calibration.swift
//  QuotientCore
//
//  Maps real-world reference values onto simulator parameters. This is the
//  bridge from "what the market looked like on the as-of date" to "what the
//  simulated order book should look like at t = 0".
//
//  Every mapping is a stated assumption, not a fit:
//
//    Volatility.  VIX is the 30-day implied vol of the S&P 500 in annualised
//    percent. We scale by the instrument's `volatilityMultiplier` (single
//    stocks move more than the index), convert to per-step ticks with √t,
//        σ_step = price · (VIX/100) · m / √(steps per trading year) · d
//    with a 6.5-hour session and 252 trading days, and apply the
//    `highFrequencyDampening` factor d (see below) because √t scaling badly
//    overstates how much a tick-constrained mid moves in 100 ms.
//
//    Spread.  The crowd's half-spread is the instrument's typical quoted
//    spread, rounded up to at least one tick either side.
//
//    Everything else (arrival rate, informed fraction, jump sizes) is not
//    observable from a snapshot and stays at the documented defaults; the
//    UI exposes them as sliders.
//

import Foundation

public enum Calibration {

    /// Seconds in a US cash-equity trading day.
    public static let secondsPerTradingDay: Double = 6.5 * 3600
    public static let tradingDaysPerYear: Double = 252

    /// Fraction of √t-scaled implied volatility that shows up as smooth
    /// diffusion of the mid at a sub-second step. A stated assumption, not a fit.
    ///
    /// WHY this exists: scaling VIX down with √t to a 0.1 s step gives SPY a σ
    /// of ≈1.5 ticks per step against a 2-tick book, and every resting quote
    /// is then picked off within a few steps (observed: every strategy lost in
    /// every regime). Three effects make the observed mid far stickier than
    /// that: roughly a third of daily variance is realised overnight, implied
    /// vol carries a premium over realised, and at 100 ms a tick-constrained
    /// mid mostly does not move at all (the discreteness shows up as
    /// occasional one-tick jumps, which the simulator models separately as
    /// news jumps). 0.35 puts SPY at ≈0.5 ticks/step, in line with the
    /// $100 example instrument the strategies were tuned on. Set it to 1.0 to
    /// see the unadjusted case.
    public static let highFrequencyDampening: Double = 0.35

    /// Per-step σ in ticks implied by an annualised vol.
    public static func sigmaTicksPerStep(price: Double, annualisedVol: Double, tickSize: Double, secondsPerStep: Double,
                                         dampening: Double = highFrequencyDampening) -> Double {
        let stepsPerYear = tradingDaysPerYear * secondsPerTradingDay / secondsPerStep
        let sigmaDollars = price * annualisedVol / stepsPerYear.squareRoot()
        return sigmaDollars / tickSize * dampening
    }

    /// Build simulation parameters for `symbol` from a snapshot, starting from
    /// `base` for everything the snapshot does not inform.
    public static func parameters(from snapshot: MarketSnapshot, symbol: String,
                                  base: SimulationParameters = .example) throws -> SimulationParameters {
        guard let ref = snapshot.instrument(symbol) else {
            throw MarketDataError.invalid("unknown symbol \(symbol)")
        }
        let instrument = Instrument(symbol: ref.symbol, name: ref.name, tickSize: ref.tickSize)
        var p = base
        p.instrument = instrument
        p.initialMidTicks = instrument.ticks(fromPrice: ref.lastPrice)
        let annualVol = snapshot.volatility.vixClose / 100 * ref.volatilityMultiplier
        p.fundamentalVolatilityTicks = sigmaTicksPerStep(price: ref.lastPrice, annualisedVol: annualVol,
                                                         tickSize: ref.tickSize, secondsPerStep: base.secondsPerStep)
        if let spread = ref.typicalSpreadTicks {
            p.crowdHalfSpreadTicks = max(1, Int((spread / 2).rounded(.up)))
        }
        // Jumps scale with σ so "news" stays meaningful relative to diffusion.
        p.jumpSizeTicks = max(2, p.fundamentalVolatilityTicks * 15)
        return p
    }
}
