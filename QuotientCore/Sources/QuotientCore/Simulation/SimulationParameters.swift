//
//  SimulationParameters.swift
//  QuotientCore
//
//  Every knob of the market simulator, named and documented. There are no
//  magic numbers inside `MarketSimulator`; if a behaviour needs a constant it
//  lives here with an explanation of what it controls and why the default is
//  what it is.
//
//  Units convention (used everywhere in QuotientCore):
//    prices in ticks · quantities in lots · time in steps · σ in ticks/step
//

import Foundation

public struct SimulationParameters: Sendable, Codable, Equatable {

    // MARK: Instrument & session

    public var instrument: Instrument
    /// Starting fundamental value and mid, in ticks.
    public var initialMidTicks: Ticks
    /// Number of discrete steps in one session (trial).
    public var steps: Int
    /// Wall-clock seconds each step represents. Only used to annualise
    /// statistics and to map real-world volatility onto per-step σ.
    public var secondsPerStep: Double

    // MARK: Fundamental ("true value") process

    /// σ of the fundamental per step, in ticks. Arithmetic Brownian motion as
    /// in Avellaneda–Stoikov: V_{t+1} = V_t + drift + σ·ε.
    public var fundamentalVolatilityTicks: Double
    /// Deterministic drift of the fundamental per step, in ticks. 0 by default
    /// (A-S assumes a driftless mid). Non-zero creates a trending session in
    /// which a maker that keeps selling into buying gets run over — the
    /// classic inventory failure.
    public var fundamentalDriftTicks: Double
    /// Probability per step of an information event (jump in the fundamental).
    /// Jumps are what informed traders most profit from: a large, sudden
    /// change the public mid has not yet reflected.
    public var jumpProbability: Double
    /// Standard deviation of a jump, in ticks.
    public var jumpSizeTicks: Double
    /// Steps between a change in the fundamental and the public mid reflecting
    /// it. During this window informed traders know something the market
    /// maker does not — the Glosten–Milgrom information asymmetry made explicit.
    public var informationDelaySteps: Int

    // MARK: Aggressive order flow

    /// Expected number of aggressive (market) orders per step. Arrivals are
    /// Poisson, as in Avellaneda–Stoikov's intensity framework.
    public var arrivalRatePerStep: Double
    /// Glosten–Milgrom μ: probability an arriving aggressor is informed.
    /// 0 gives pure inventory risk with no adverse selection.
    public var informedFraction: Double
    /// Probability an *uninformed* aggressor buys. 0.5 is symmetric; other
    /// values inject a directional flow bias to stress inventory management.
    public var uninformedBuyProbability: Double
    /// Mean aggressive order size in lots (geometric distribution).
    public var meanOrderSizeLots: Double
    /// Informed traders only act when the mispricing exceeds this many ticks
    /// (their own cost of trading / uncertainty). Larger = fewer, sharper
    /// informed trades.
    public var informedThresholdTicks: Double
    /// Informed orders are sized as a multiple of the mean uninformed size.
    public var informedSizeMultiplier: Double

    // MARK: Background liquidity ("the crowd")

    /// Number of price levels the crowd maintains on each side.
    public var crowdLevels: Int
    /// Distance in ticks from the public mid to the crowd's best quote.
    /// The crowd's spread is 2× this (plus one if the mid is on a tick).
    public var crowdHalfSpreadTicks: Int
    /// Lots the crowd rests at its best level.
    public var crowdBaseSizeLots: Int
    /// Multiplicative growth of crowd size per level away from the touch.
    /// Deeper books have more size; >1 also makes fills at distance rarer,
    /// which is what produces the exponential-ish λ(δ) that A-S assumes.
    public var crowdSizeGrowthPerLevel: Double
    /// Probability per step that a crowd level is randomly cancelled and
    /// re-posted (loses queue position). Adds realistic churn to depth.
    public var crowdChurnProbability: Double

    // MARK: Market maker plumbing

    /// Re-evaluate quotes every N steps. 1 = every step.
    public var quoteIntervalSteps: Int
    /// Horizons (steps) at which fills are marked out.
    public var markoutHorizons: [Int]
    /// EWMA half-life for the strategy's volatility estimator, in steps.
    public var volatilityHalfLifeSteps: Double
    /// Refit the microprice estimator every N steps.
    public var micropriceRefitIntervalSteps: Int

    public init(instrument: Instrument,
                initialMidTicks: Ticks,
                steps: Int = 3_000,
                secondsPerStep: Double = 0.1,
                fundamentalVolatilityTicks: Double = 0.4,
                fundamentalDriftTicks: Double = 0,
                jumpProbability: Double = 0.004,
                jumpSizeTicks: Double = 6,
                informationDelaySteps: Int = 8,
                arrivalRatePerStep: Double = 0.6,
                informedFraction: Double = 0.2,
                uninformedBuyProbability: Double = 0.5,
                meanOrderSizeLots: Double = 2.0,
                informedThresholdTicks: Double = 1.0,
                informedSizeMultiplier: Double = 1.5,
                crowdLevels: Int = 6,
                crowdHalfSpreadTicks: Int = 2,
                crowdBaseSizeLots: Int = 3,
                crowdSizeGrowthPerLevel: Double = 1.4,
                crowdChurnProbability: Double = 0.05,
                quoteIntervalSteps: Int = 1,
                markoutHorizons: [Int] = [10, 50, 200],
                volatilityHalfLifeSteps: Double = 100,
                micropriceRefitIntervalSteps: Int = 250) {
        precondition(steps > 0 && secondsPerStep > 0)
        precondition(informedFraction >= 0 && informedFraction <= 1)
        precondition(uninformedBuyProbability >= 0 && uninformedBuyProbability <= 1)
        precondition(crowdLevels >= 1 && crowdHalfSpreadTicks >= 1 && crowdBaseSizeLots >= 1)
        precondition(quoteIntervalSteps >= 1 && informationDelaySteps >= 0)
        self.instrument = instrument
        self.initialMidTicks = initialMidTicks
        self.steps = steps
        self.secondsPerStep = secondsPerStep
        self.fundamentalVolatilityTicks = fundamentalVolatilityTicks
        self.fundamentalDriftTicks = fundamentalDriftTicks
        self.jumpProbability = jumpProbability
        self.jumpSizeTicks = jumpSizeTicks
        self.informationDelaySteps = informationDelaySteps
        self.arrivalRatePerStep = arrivalRatePerStep
        self.informedFraction = informedFraction
        self.uninformedBuyProbability = uninformedBuyProbability
        self.meanOrderSizeLots = meanOrderSizeLots
        self.informedThresholdTicks = informedThresholdTicks
        self.informedSizeMultiplier = informedSizeMultiplier
        self.crowdLevels = crowdLevels
        self.crowdHalfSpreadTicks = crowdHalfSpreadTicks
        self.crowdBaseSizeLots = crowdBaseSizeLots
        self.crowdSizeGrowthPerLevel = crowdSizeGrowthPerLevel
        self.crowdChurnProbability = crowdChurnProbability
        self.quoteIntervalSteps = quoteIntervalSteps
        self.markoutHorizons = markoutHorizons
        self.volatilityHalfLifeSteps = volatilityHalfLifeSteps
        self.micropriceRefitIntervalSteps = micropriceRefitIntervalSteps
    }

    /// A generic instrument for tests and examples: $100.00 stock, 1¢ tick.
    public static let example = SimulationParameters(
        instrument: Instrument(symbol: "SIM", name: "Simulated Stock", tickSize: 0.01),
        initialMidTicks: 10_000
    )

    /// Dollar value of one tick on one lot.
    public var dollarsPerTickLot: Double { instrument.tickSize * Double(instrument.lotSize) }
}
