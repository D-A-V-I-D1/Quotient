//
//  Signals.swift
//  QuotientCore
//
//  Fair-value signals derived from the order book.
//
//  All functions here are pure: they read a book and return a number. Keeping
//  them separate from the strategies means the same signal can feed the UI,
//  the tests and any strategy without duplication.
//

import Foundation

public enum Signals {

    /// Depth imbalance in [-1, 1]: (Qb − Qa) / (Qb + Qa) over the top `levels`.
    /// +1 means all resting size is on the bid (buying pressure).
    /// Reference: Cont, Kukanov & Stoikov (2014) show top-of-book imbalance is
    /// the dominant short-horizon predictor of price changes.
    public static func imbalance(_ book: OrderBook, levels: Int = 1) -> Double? {
        let qb = Double(book.quantity(.bid, topLevels: levels))
        let qa = Double(book.quantity(.ask, topLevels: levels))
        let total = qb + qa
        guard total > 0 else { return nil }
        return (qb - qa) / total
    }

    /// Bid-share of top-of-book depth, I = Qb / (Qb + Qa) in [0, 1].
    /// This is the state variable Stoikov (2018) buckets.
    public static func bidShare(_ book: OrderBook) -> Double? {
        let b = book.best
        let total = Double(b.bidQuantity + b.askQuantity)
        guard total > 0, b.bidPrice != nil, b.askPrice != nil else { return nil }
        return Double(b.bidQuantity) / total
    }

    /// Imbalance-weighted mid, in ticks: P_w = I·P_a + (1 − I)·P_b.
    ///
    /// WHY the weights look "backwards": heavy bid depth (I → 1) means buyers
    /// are queuing, so the next mid move is more likely up; the fair value
    /// leans toward the ask. This is the first-order microprice heuristic and
    /// the fallback when the full estimator has too little data.
    public static func weightedMid(_ book: OrderBook) -> Double? {
        guard let i = bidShare(book), let b = book.bestBid, let a = book.bestAsk else { return nil }
        return i * Double(a) + (1 - i) * Double(b)
    }
}

// MARK: - Order flow imbalance

/// Event-based order flow imbalance (OFI) accumulator.
///
/// Cont, Kukanov & Stoikov (2014), eq. (10): for consecutive best-quote
/// observations n−1 → n,
///   e_n = 1{Pb_n ≥ Pb_{n−1}}·qb_n − 1{Pb_n ≤ Pb_{n−1}}·qb_{n−1}
///       − 1{Pa_n ≤ Pa_{n−1}}·qa_n + 1{Pa_n ≥ Pa_{n−1}}·qa_{n−1}
/// OFI over a window is Σ e_n. Positive OFI = net buying pressure.
///
/// Unlike depth imbalance (a level), OFI is a flow: it captures *changes* in
/// the queues, which is what actually moves the mid.
public struct OrderFlowImbalance: Sendable {
    private var previous: BestQuotes?
    /// Rolling window of recent contributions, oldest first.
    private var window: [Double] = []
    private let windowLength: Int
    public private(set) var value: Double = 0

    public init(windowLength: Int = 50) {
        precondition(windowLength > 0)
        self.windowLength = windowLength
    }

    /// Feed the current top of book. Call once per observation (e.g. per step).
    public mutating func observe(_ q: BestQuotes) {
        defer { previous = q }
        guard let p = previous,
              let pb = p.bidPrice, let pa = p.askPrice,
              let cb = q.bidPrice, let ca = q.askPrice else { return }
        var e = 0.0
        if cb >= pb { e += Double(q.bidQuantity) }
        if cb <= pb { e -= Double(p.bidQuantity) }
        if ca <= pa { e -= Double(q.askQuantity) }
        if ca >= pa { e += Double(p.askQuantity) }
        window.append(e)
        value += e
        if window.count > windowLength {
            value -= window.removeFirst()
        }
    }

    public mutating func reset() {
        previous = nil
        window.removeAll()
        value = 0
    }
}

// MARK: - Volatility

/// Exponentially weighted estimator of mid-price volatility per step, in ticks.
///
/// WHY EWMA: Avellaneda–Stoikov needs σ as an input, and a strategy that might
/// one day see real data can't be handed the simulator's true σ. An EWMA
/// (RiskMetrics-style) tracks regime changes with O(1) state and no window
/// buffer. The half-life is a named parameter, not a magic number.
public struct VolatilityEstimator: Sendable {
    private let decay: Double
    private var lastMid: Double?
    private var variance: Double
    private var observations = 0
    /// Number of observations before the estimate is trusted.
    public let warmup: Int
    /// Used until warm-up completes.
    public let prior: Double

    /// - Parameters:
    ///   - halfLife: number of steps for a shock's weight to halve.
    ///   - prior: initial σ per step (ticks), used until warm-up completes.
    public init(halfLife: Double, prior: Double, warmup: Int = 20) {
        precondition(halfLife > 0 && prior >= 0)
        self.decay = pow(0.5, 1.0 / halfLife)
        self.prior = prior
        self.variance = prior * prior
        self.warmup = warmup
    }

    public mutating func observe(mid: Double) {
        defer { lastMid = mid }
        guard let last = lastMid else { return }
        let r = mid - last
        // Blend the prior in during warm-up so the first few returns don't
        // dominate; after warm-up this is the standard EWMA recursion.
        variance = decay * variance + (1 - decay) * r * r
        observations += 1
    }

    /// σ per step in ticks.
    public var sigma: Double {
        observations >= warmup ? variance.squareRoot() : prior
    }

    public var isWarm: Bool { observations >= warmup }
}

// MARK: - Fill intensity calibration

/// Fits the Avellaneda–Stoikov intensity model λ(δ) = A·exp(−k·δ) from
/// observed (distance-from-mid, fills, exposure-time) tuples.
///
/// WHY: `k` is the one A-S input that is not observable from the tape; it has
/// to be estimated. Taking logs gives ln λ = ln A − k·δ, a linear regression.
/// Buckets with zero fills are dropped (ln 0), which biases `k` slightly
/// downward at large δ — documented rather than hidden.
public struct IntensityCalibrator: Sendable {
    /// distance (ticks) -> (fills, exposure in steps)
    private var buckets: [Int: (fills: Int, exposure: Int)] = [:]

    public init() {}

    /// Record that a quote sat `distance` ticks from the mid for one step and
    /// received `fills` executions during it.
    public mutating func record(distance: Int, fills: Int, exposure: Int = 1) {
        guard distance >= 0 else { return }
        var b = buckets[distance] ?? (0, 0)
        b.fills += fills
        b.exposure += exposure
        buckets[distance] = b
    }

    public struct Fit: Sendable, Equatable {
        public let A: Double
        public let k: Double
        public let bucketsUsed: Int
    }

    /// Returns nil if fewer than two buckets have positive fill rates.
    public func fit() -> Fit? {
        var xs: [Double] = [], ys: [Double] = []
        for (d, b) in buckets where b.fills > 0 && b.exposure > 0 {
            xs.append(Double(d))
            ys.append(log(Double(b.fills) / Double(b.exposure)))
        }
        guard xs.count >= 2 else { return nil }
        let (intercept, slope) = Statistics.linearRegression(x: xs, y: ys)
        return Fit(A: exp(intercept), k: max(0, -slope), bucketsUsed: xs.count)
    }
}
