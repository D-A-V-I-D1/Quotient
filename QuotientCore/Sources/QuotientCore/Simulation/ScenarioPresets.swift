//
//  ScenarioPresets.swift
//  QuotientCore
//
//  Named market regimes. Each is `SimulationParameters.example` with a few
//  knobs turned, and a one-line statement of what it is designed to expose.
//  The Compare screen and the README results both run these.
//

import Foundation

public struct ScenarioPreset: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let summary: String
    public let parameters: SimulationParameters

    public static func all(base: SimulationParameters = .example) -> [ScenarioPreset] {
        [baseline(base), inventoryOnly(base), adverseSelection(base), trending(base), newsHeavy(base)]
    }

    /// Mixed flow: 20% informed, moderate jumps. The default.
    public static func baseline(_ base: SimulationParameters = .example) -> ScenarioPreset {
        ScenarioPreset(name: "Baseline",
                       summary: "20% informed flow, occasional news jumps, symmetric uninformed flow.",
                       parameters: base)
    }

    /// μ = 0: no adverse selection at all. Isolates inventory risk.
    public static func inventoryOnly(_ base: SimulationParameters = .example) -> ScenarioPreset {
        var p = base
        p.informedFraction = 0
        p.jumpProbability = 0
        return ScenarioPreset(name: "Inventory Only",
                              summary: "No informed traders, no jumps. Any loss is pure inventory risk (Avellaneda–Stoikov's setting).",
                              parameters: p)
    }

    /// Heavy informed flow with a longer information delay.
    public static func adverseSelection(_ base: SimulationParameters = .example) -> ScenarioPreset {
        var p = base
        p.informedFraction = 0.45
        p.informationDelaySteps = 15
        p.jumpProbability = 0.01
        p.jumpSizeTicks = 10
        return ScenarioPreset(name: "Adverse Selection",
                              summary: "45% informed flow that sees the fundamental 15 steps early, larger news jumps (Glosten–Milgrom stress).",
                              parameters: p)
    }

    /// A trending session: the fundamental drifts and informed traders lean on it.
    public static func trending(_ base: SimulationParameters = .example) -> ScenarioPreset {
        var p = base
        p.fundamentalDriftTicks = 0.06
        p.informedFraction = 0.3
        // A longer information lag gives informed traders a real lead on the
        // trend (≈ drift × delay = 2.4 ticks) instead of just noise.
        p.informationDelaySteps = 40
        p.informedThresholdTicks = 0.5
        return ScenarioPreset(name: "Trending",
                              summary: "Fundamental drifts up ~\(Int(0.06 * Double(base.steps))) ticks over the session; 30% informed flow sees it 40 steps early. A maker that keeps selling into the trend gets run over.",
                              parameters: p)
    }

    /// Frequent, large jumps.
    public static func newsHeavy(_ base: SimulationParameters = .example) -> ScenarioPreset {
        var p = base
        p.jumpProbability = 0.02
        p.jumpSizeTicks = 15
        p.informedFraction = 0.3
        p.informationDelaySteps = 12
        return ScenarioPreset(name: "News Heavy",
                              summary: "Jumps every ~50 steps of ~15 ticks, 30% informed. Tests whether spreads widen with realised σ.",
                              parameters: p)
    }
}

public extension MonteCarloRunner {
    /// The standard three-strategy ladder used throughout the project, with the
    /// fixed-spread control matched to the A-S spread.
    ///
    /// Matching uses σ from a short *pilot* run of the A-S maker on
    /// `pilotSeed`, because the A-S maker sizes its spread from its own online
    /// σ estimate, not from the calibration prior; matching against the prior
    /// would leave a spread-width confounder in the comparison.
    static func standardLadder(parameters: SimulationParameters,
                               gamma: Double = 0.01, k: Double = 1.0,
                               horizonSteps: Int = 300,
                               maxInventory: Int? = nil,
                               pilotSeed: UInt64 = 0) -> [any MarketMakingStrategy] {
        let asMM = AvellanedaStoikovMarketMaker(gamma: gamma, k: k, horizon: .rolling(steps: horizonSteps),
                                                referencePrice: .mid, maxInventory: maxInventory)
        let pilot = MarketSimulator(parameters: parameters, strategy: asMM, seed: pilotSeed)
        _ = pilot.run()
        let sigma = pilot.volatility.sigma
        let fixed = FixedSpreadMarketMaker.matched(to: asMM, sigma: sigma, horizonSteps: Double(horizonSteps))
        let micro = AvellanedaStoikovMarketMaker(gamma: gamma, k: k, horizon: .rolling(steps: horizonSteps),
                                                 referencePrice: .microprice, maxInventory: maxInventory)
        return [fixed, asMM, micro]
    }
}
