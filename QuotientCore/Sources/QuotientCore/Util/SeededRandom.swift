//
//  SeededRandom.swift
//  QuotientCore
//
//  Deterministic pseudo-random number generation.
//
//  WHY: Paired Monte Carlo comparison ("same seed => same market") is the
//  backbone of the evaluation methodology. `SystemRandomNumberGenerator` is
//  not seedable, and Foundation's `srand48`/`drand48` are global state that is
//  unsafe to share across concurrent trials. We therefore ship our own small,
//  well-known generator with an explicit, value-type state.
//
//  Algorithm: xoshiro256** (Blackman & Vigna, 2018). It is fast, has a 2^256
//  period, passes BigCrush, and is trivially seedable via SplitMix64.
//  Reference: https://prng.di.unimi.it/  (public domain reference code).
//

import Foundation

/// A seedable, value-type PRNG. Copying a `SeededRandom` copies its state, so
/// two copies produce identical streams — which is exactly what common random
/// numbers across strategies requires.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var s0: UInt64
    private var s1: UInt64
    private var s2: UInt64
    private var s3: UInt64

    /// Cached second Box–Muller normal so we don't throw half the work away.
    /// Kept in the state so copies of the generator stay in lockstep.
    private var spareGaussian: Double?

    public init(seed: UInt64) {
        // SplitMix64 to expand a 64-bit seed into 256 bits of state.
        // WHY: xoshiro must not be seeded with all zeros; SplitMix guarantees a
        // well-mixed nonzero state for any input seed, including 0.
        var sm = seed
        func splitMix() -> UInt64 {
            sm &+= 0x9E37_79B9_7F4A_7C15
            var z = sm
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        s0 = splitMix()
        s1 = splitMix()
        s2 = splitMix()
        s3 = splitMix()
        spareGaussian = nil
    }

    /// Derive an independent sub-stream. Used so the fundamental-price path,
    /// the order-arrival stream and the background-liquidity stream each have
    /// their own generator: a strategy consuming random draws (or not) can then
    /// never perturb the market it is being evaluated on.
    public func derived(stream: UInt64) -> SeededRandom {
        var copy = self
        let mixed = copy.next() ^ (stream &* 0xD1B5_4A32_D192_ED03)
        return SeededRandom(seed: mixed)
    }

    @inline(__always)
    private static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }

    public mutating func next() -> UInt64 {
        let result = Self.rotl(s1 &* 5, 7) &* 9
        let t = s1 << 17
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = Self.rotl(s3, 45)
        return result
    }

    // MARK: - Distributions

    /// Uniform in [0, 1).
    public mutating func nextDouble() -> Double {
        // Take the top 53 bits so the result is exactly representable.
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Standard normal via Box–Muller.
    public mutating func nextGaussian() -> Double {
        if let g = spareGaussian {
            spareGaussian = nil
            return g
        }
        var u1 = nextDouble()
        // Guard against log(0).
        while u1 <= Double.leastNonzeroMagnitude { u1 = nextDouble() }
        let u2 = nextDouble()
        let r = (-2.0 * log(u1)).squareRoot()
        let theta = 2.0 * Double.pi * u2
        spareGaussian = r * sin(theta)
        return r * cos(theta)
    }

    public mutating func nextGaussian(mean: Double, standardDeviation: Double) -> Double {
        mean + standardDeviation * nextGaussian()
    }

    /// Exponential with the given rate (mean 1/rate).
    public mutating func nextExponential(rate: Double) -> Double {
        precondition(rate > 0, "rate must be positive")
        var u = nextDouble()
        while u <= Double.leastNonzeroMagnitude { u = nextDouble() }
        return -log(u) / rate
    }

    /// Poisson via Knuth's method for small means, normal approximation for large.
    public mutating func nextPoisson(mean: Double) -> Int {
        precondition(mean >= 0)
        if mean == 0 { return 0 }
        if mean > 50 {
            // WHY: Knuth's algorithm is O(mean); for large means the normal
            // approximation is accurate to well within what a simulation needs.
            let x = nextGaussian(mean: mean, standardDeviation: mean.squareRoot())
            return max(0, Int(x.rounded()))
        }
        let l = exp(-mean)
        var k = 0
        var p = 1.0
        repeat {
            k += 1
            p *= nextDouble()
        } while p > l
        return k - 1
    }

    /// Bernoulli trial.
    public mutating func nextBool(probability: Double) -> Bool {
        nextDouble() < probability
    }

    /// Geometric number of "units" >= 1 with success probability p.
    /// Used for order sizes: heavy-ish right tail, always at least one lot.
    public mutating func nextGeometric(successProbability p: Double) -> Int {
        precondition(p > 0 && p <= 1)
        if p == 1 { return 1 }
        var u = nextDouble()
        while u <= Double.leastNonzeroMagnitude { u = nextDouble() }
        return Int((log(u) / log(1 - p)).rounded(.down)) + 1
    }
}
