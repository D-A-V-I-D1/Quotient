//
//  MicropriceEstimator.swift
//  QuotientCore
//
//  Stoikov (2018), "The Micro-Price: A High Frequency Estimator of Future
//  Prices", Quantitative Finance 18(12). SSRN 2970694.
//
//  The microprice is defined as the limit of the expected mid-price after
//  many future mid changes, conditional on the current state (imbalance,
//  spread):
//
//      P_micro = M + G*(I, S),   G* = lim_{n→∞} Σ_{i=1..n} B^{i−1} G¹
//
//  where, with the state space discretised,
//      Q  = transition matrix among states with NO mid change,
//      R  = transition matrix to states WITH a mid change,
//      r  = vector of expected immediate mid change (ticks) from each state,
//      G¹ = (I − Q)⁻¹ r         expected mid change at the *first* change,
//      B  = (I − Q)⁻¹ R         state transition across one mid change.
//
//  In practice the series converges within a handful of terms because the
//  state after a mid change carries little memory; the paper uses ~6.
//
//  WHY implement the full construction rather than the weighted mid:
//  the weighted mid is not a martingale — it over-reacts at wide spreads and
//  under-reacts at narrow ones — and the whole point of the paper is that the
//  adjustment must be *learned* from how imbalance actually resolves. The
//  estimator here learns online from the very book it is quoting into, so if
//  the simulator's microstructure changes, the signal re-calibrates.
//
//  Estimation is online: counts are accumulated per observation; `estimate()`
//  solves the small linear system (state count ≈ imbalanceBuckets × spreadBuckets,
//  e.g. 10 × 2 = 20) with Gaussian elimination. That is cheap enough to run
//  every few hundred steps.
//

import Foundation

public struct MicropriceEstimator: Sendable {

    public struct Configuration: Sendable, Equatable {
        /// Number of equal-width imbalance buckets over [0, 1].
        public var imbalanceBuckets: Int
        /// Spreads (in ticks) from 1...maxSpreadTicks get their own bucket;
        /// wider spreads are clamped to the last bucket.
        public var maxSpreadTicks: Int
        /// Number of terms in the Σ Bⁱ G¹ series.
        public var horizonMidChanges: Int
        /// Minimum observed transitions before the estimate is trusted; until
        /// then the weighted mid is returned.
        public var minimumObservations: Int

        public init(imbalanceBuckets: Int = 10, maxSpreadTicks: Int = 2,
                    horizonMidChanges: Int = 6, minimumObservations: Int = 500) {
            precondition(imbalanceBuckets >= 2 && maxSpreadTicks >= 1 && horizonMidChanges >= 1)
            self.imbalanceBuckets = imbalanceBuckets
            self.maxSpreadTicks = maxSpreadTicks
            self.horizonMidChanges = horizonMidChanges
            self.minimumObservations = minimumObservations
        }
    }

    public let configuration: Configuration
    private let stateCount: Int

    // Transition counts. Flat row-major [from * stateCount + to].
    private var noChangeCounts: [Double]
    private var changeCounts: [Double]
    /// Sum of mid changes (ticks) for transitions from each state (with change).
    private var changeSum: [Double]
    private var rowTotals: [Double]
    private var previousState: Int?
    private var previousMid: Double?
    public private(set) var observations = 0

    /// Cached adjustment table G*[state], refreshed by `refit()`.
    private var adjustment: [Double]?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        stateCount = configuration.imbalanceBuckets * configuration.maxSpreadTicks
        noChangeCounts = Array(repeating: 0, count: stateCount * stateCount)
        changeCounts = Array(repeating: 0, count: stateCount * stateCount)
        changeSum = Array(repeating: 0, count: stateCount)
        rowTotals = Array(repeating: 0, count: stateCount)
    }

    // MARK: - State discretisation

    func stateIndex(bidShare: Double, spreadTicks: Ticks) -> Int {
        let n = configuration.imbalanceBuckets
        var ib = Int(bidShare * Double(n))
        if ib >= n { ib = n - 1 }
        if ib < 0 { ib = 0 }
        let sb = Int(min(max(spreadTicks, 1), Ticks(configuration.maxSpreadTicks))) - 1
        return sb * n + ib
    }

    // MARK: - Online learning

    /// Feed one observation of the top of book. Call once per step.
    public mutating func observe(_ book: OrderBook) {
        guard let share = Signals.bidShare(book), let spread = book.spreadTicks,
              let mid = book.midTicks else { return }
        let state = stateIndex(bidShare: share, spreadTicks: spread)
        defer { previousState = state; previousMid = mid }
        guard let prev = previousState, let pm = previousMid else { return }
        let dm = mid - pm
        let idx = prev * stateCount + state
        if dm == 0 {
            noChangeCounts[idx] += 1
        } else {
            changeCounts[idx] += 1
            changeSum[prev] += dm
        }
        rowTotals[prev] += 1
        observations += 1
        adjustment = nil // invalidate cache lazily; caller decides when to refit
    }

    public var hasEnoughData: Bool { observations >= configuration.minimumObservations }

    /// Recompute the adjustment table from accumulated counts. O(S³) with
    /// S = stateCount (≈20), i.e. negligible. Returns false if the system is
    /// singular (e.g. some state has never been observed) — the estimator then
    /// keeps its previous table or falls back to the weighted mid.
    @discardableResult
    public mutating func refit() -> Bool {
        guard hasEnoughData else { return false }
        let S = stateCount
        // Build Q, R, r as probabilities. Unobserved rows are treated as
        // absorbing with zero expected change — a conservative prior.
        var Q = Array(repeating: 0.0, count: S * S)
        var R = Array(repeating: 0.0, count: S * S)
        var r = Array(repeating: 0.0, count: S)
        for i in 0..<S {
            let tot = rowTotals[i]
            guard tot > 0 else { continue }
            for j in 0..<S {
                Q[i * S + j] = noChangeCounts[i * S + j] / tot
                R[i * S + j] = changeCounts[i * S + j] / tot
            }
            r[i] = changeSum[i] / tot
        }
        // M = I − Q
        var M = Array(repeating: 0.0, count: S * S)
        for i in 0..<S {
            for j in 0..<S { M[i * S + j] = (i == j ? 1 : 0) - Q[i * S + j] }
        }
        // Solve M·G1 = r and M·B = R (B column by column) via one LU pass.
        guard let inv = LinearAlgebra.invert(M, n: S) else { return false }
        let G1 = LinearAlgebra.multiply(inv, r, n: S)
        let B = LinearAlgebra.multiplyMatrices(inv, R, n: S)

        // G* = G1 + B·G1 + B²·G1 + ...  (horizonMidChanges terms)
        var G = G1
        var term = G1
        for _ in 1..<configuration.horizonMidChanges {
            term = LinearAlgebra.multiply(B, term, n: S)
            for i in 0..<S { G[i] += term[i] }
        }
        // Guard against divergence from a poorly conditioned estimate.
        if G.contains(where: { !$0.isFinite || abs($0) > Double(configuration.maxSpreadTicks) * 4 }) {
            return false
        }
        adjustment = G
        return true
    }

    /// Microprice in ticks. Falls back to the imbalance-weighted mid until the
    /// estimator has data and a valid fit.
    public func microprice(_ book: OrderBook) -> Double? {
        guard let mid = book.midTicks, let share = Signals.bidShare(book),
              let spread = book.spreadTicks else { return nil }
        guard let table = adjustment else { return Signals.weightedMid(book) }
        let s = stateIndex(bidShare: share, spreadTicks: spread)
        return mid + table[s]
    }

    /// The learned adjustment (ticks) for a given state — exposed for tests
    /// and for the UI to show what the estimator has learned.
    public func adjustment(bidShare: Double, spreadTicks: Ticks) -> Double? {
        adjustment?[stateIndex(bidShare: bidShare, spreadTicks: spreadTicks)]
    }

    public var isFitted: Bool { adjustment != nil }
}

/// Minimal dense linear algebra for tiny systems. Not for large matrices.
enum LinearAlgebra {
    /// Gauss–Jordan inverse with partial pivoting. Returns nil if singular.
    static func invert(_ a: [Double], n: Int) -> [Double]? {
        var m = a
        var inv = Array(repeating: 0.0, count: n * n)
        for i in 0..<n { inv[i * n + i] = 1 }
        for col in 0..<n {
            // Pivot
            var pivot = col
            var best = abs(m[col * n + col])
            for row in (col + 1)..<max(col + 1, n) where abs(m[row * n + col]) > best {
                best = abs(m[row * n + col]); pivot = row
            }
            if best < 1e-12 { return nil }
            if pivot != col {
                for j in 0..<n {
                    m.swapAt(col * n + j, pivot * n + j)
                    inv.swapAt(col * n + j, pivot * n + j)
                }
            }
            let p = m[col * n + col]
            for j in 0..<n { m[col * n + j] /= p; inv[col * n + j] /= p }
            for row in 0..<n where row != col {
                let f = m[row * n + col]
                if f == 0 { continue }
                for j in 0..<n {
                    m[row * n + j] -= f * m[col * n + j]
                    inv[row * n + j] -= f * inv[col * n + j]
                }
            }
        }
        return inv
    }

    static func multiply(_ a: [Double], _ v: [Double], n: Int) -> [Double] {
        var out = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            var s = 0.0
            for j in 0..<n { s += a[i * n + j] * v[j] }
            out[i] = s
        }
        return out
    }

    /// Square matrix product (n×n)·(n×n), both flattened row-major.
    static func multiplyMatrices(_ a: [Double], _ b: [Double], n: Int) -> [Double] {
        var out = Array(repeating: 0.0, count: n * n)
        for i in 0..<n {
            for k in 0..<n {
                let aik = a[i * n + k]
                if aik == 0 { continue }
                for j in 0..<n { out[i * n + j] += aik * b[k * n + j] }
            }
        }
        return out
    }
}
