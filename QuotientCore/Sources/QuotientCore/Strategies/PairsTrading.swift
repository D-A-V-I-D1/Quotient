//
//  PairsTrading.swift
//  QuotientCore
//
//  Breadth module: a statistical-arbitrage strategy on two correlated
//  simulated instruments, with its own small simulator.
//
//  Model. Two log-price series share a common factor; their spread
//  (Y − β·X) follows an Ornstein–Uhlenbeck process:
//      s_{t+1} = s_t + θ(μ − s_t) + σ_s·ε
//  θ > 0 gives mean reversion (the pair is cointegrated); θ = 0 makes the
//  spread a random walk, in which case the strategy should NOT make money —
//  and the tests check that it doesn't. That negative control matters more
//  than the positive result.
//
//  Strategy. Rolling OLS for the hedge ratio β, rolling z-score of the
//  residual. Enter short-spread at z > +entry, long-spread at z < −entry,
//  exit at |z| < exit, stop at |z| > stop. Unit notional per leg, so P&L is
//  in "spread units". Transaction cost per leg per trade is a named parameter,
//  because the whole game in pairs trading is whether the reversion pays for
//  the round trip.
//
//  Reference: Vidyamurthy, G. (2004). Pairs Trading: Quantitative Methods and
//  Analysis. Wiley. (Standard practitioner treatment; the z-score band rule
//  is textbook, not novel.)
//

import Foundation

public struct PairsParameters: Sendable, Codable, Equatable {
    public var steps: Int
    /// Starting prices of the two legs.
    public var initialPriceA: Double
    public var initialPriceB: Double
    /// Per-step volatility of the common factor (log-return).
    public var factorVolatility: Double
    /// Sensitivity of B's log price to the common factor (true β).
    public var beta: Double
    /// OU mean-reversion speed per step (0 = random-walk spread).
    public var reversionSpeed: Double
    /// Per-step volatility of the spread innovation.
    public var spreadVolatility: Double
    /// Rolling window for hedge ratio and z-score.
    public var lookback: Int
    public var entryZ: Double
    public var exitZ: Double
    public var stopZ: Double
    /// Cost per leg per trade, as a fraction of notional.
    public var costPerLeg: Double

    public init(steps: Int = 2_000, initialPriceA: Double = 87.81, initialPriceB: Double = 128.63,
                factorVolatility: Double = 0.004, beta: Double = 1.1,
                reversionSpeed: Double = 0.05, spreadVolatility: Double = 0.003,
                lookback: Int = 100, entryZ: Double = 2.0, exitZ: Double = 0.5, stopZ: Double = 4.0,
                costPerLeg: Double = 0.0002) {
        self.steps = steps
        self.initialPriceA = initialPriceA
        self.initialPriceB = initialPriceB
        self.factorVolatility = factorVolatility
        self.beta = beta
        self.reversionSpeed = reversionSpeed
        self.spreadVolatility = spreadVolatility
        self.lookback = lookback
        self.entryZ = entryZ
        self.exitZ = exitZ
        self.stopZ = stopZ
        self.costPerLeg = costPerLeg
    }
}

public struct PairsResult: Sendable {
    public let priceA: [Double]
    public let priceB: [Double]
    public let zScore: [Double]
    /// +1 long spread (long B, short βA), −1 short spread, 0 flat.
    public let position: [Int]
    /// Cumulative P&L as a fraction of one unit of notional per leg.
    public let pnl: [Double]
    public let trades: Int
    public var finalPnL: Double { pnl.last ?? 0 }
}

public enum PairsSimulator {

    public static func run(_ p: PairsParameters, seed: UInt64) -> PairsResult {
        var rng = SeededRandom(seed: seed)
        var logA = log(p.initialPriceA)
        var logB = log(p.initialPriceB)
        // Spread state in log space, mean zero by construction.
        var s = 0.0
        let base = logB - p.beta * logA

        var priceA = [p.initialPriceA], priceB = [p.initialPriceB]
        var zs = [0.0], pos = [0], pnl = [0.0]
        var position = 0
        var trades = 0
        var cum = 0.0
        /// Hedge ratio locked when the position was opened.
        ///
        /// WHY (a real bug found in development): the first version accrued
        /// P&L on the change in the *rolling-regression residual*. That
        /// residual is re-fitted every step, so it is mean-reverting by
        /// construction even when the true spread is a random walk — the
        /// negative-control test (θ = 0) showed a spurious t-stat > 2. A real
        /// position's P&L is Δlog B − β_entry·Δlog A with β fixed at entry;
        /// only the *signal* may use the latest fit.
        var entryBeta = 0.0

        for _ in 0..<p.steps {
            let prevLogA = logA, prevLogB = logB
            // Common factor moves both legs; spread mean-reverts.
            let f = p.factorVolatility * rng.nextGaussian()
            s += p.reversionSpeed * (0 - s) + p.spreadVolatility * rng.nextGaussian()
            logA += f
            logB = base + p.beta * logA + s
            priceA.append(exp(logA))
            priceB.append(exp(logB))

            // Tradable P&L on the open position (unit notional per leg).
            if position != 0 {
                cum += Double(position) * ((logB - prevLogB) - entryBeta * (logA - prevLogA))
            }

            // Signal: residual from rolling OLS of logB on logA.
            var z = 0.0
            if priceA.count > p.lookback {
                let xs = priceA.suffix(p.lookback).map(log)
                let ys = priceB.suffix(p.lookback).map(log)
                let (a, b) = Statistics.linearRegression(x: xs, y: ys)
                let resid = ys.indices.map { ys[$0] - (a + b * xs[$0]) }
                let sd = Statistics.standardDeviation(resid)
                z = sd > 0 ? resid.last! / sd : 0

                if position == 0 {
                    if z > p.entryZ { position = -1; entryBeta = b; trades += 1; cum -= 2 * p.costPerLeg }
                    else if z < -p.entryZ { position = 1; entryBeta = b; trades += 1; cum -= 2 * p.costPerLeg }
                } else if abs(z) < p.exitZ || abs(z) > p.stopZ {
                    position = 0
                    cum -= 2 * p.costPerLeg
                }
            }
            zs.append(z)
            pos.append(position)
            pnl.append(cum)
        }
        return PairsResult(priceA: priceA, priceB: priceB, zScore: zs, position: pos, pnl: pnl, trades: trades)
    }

    /// Monte Carlo over seeds; returns final P&L per trial.
    public static func monteCarlo(_ p: PairsParameters, trials: Int, baseSeed: UInt64 = 7) -> [Double] {
        (0..<trials).map { run(p, seed: baseSeed &+ UInt64($0)).finalPnL }
    }
}
