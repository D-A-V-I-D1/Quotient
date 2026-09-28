//
//  Statistics.swift
//  QuotientCore
//
//  Small, dependency-free statistics helpers used by the evaluation layer.
//  WHY not a third-party library: keeping QuotientCore dependency-free makes it
//  trivially auditable and buildable anywhere `swift` runs.
//

import Foundation

public enum Statistics {
    public static func mean(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Sample (n-1) variance.
    public static func variance(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        return xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
    }

    public static func standardDeviation(_ xs: [Double]) -> Double {
        variance(xs).squareRoot()
    }

    /// Root-mean-square (no centering). Used for inventory, where the
    /// relevant quantity is distance from flat, not from the mean.
    public static func rootMeanSquare(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return (xs.reduce(0) { $0 + $1 * $1 } / Double(xs.count)).squareRoot()
    }

    /// Maximum peak-to-trough decline of a cumulative series (in the series'
    /// own units, not percent — P&L can pass through zero so percent is
    /// ill-defined).
    public static func maxDrawdown(_ series: [Double]) -> Double {
        var peak = -Double.infinity
        var maxDD = 0.0
        for x in series {
            peak = max(peak, x)
            maxDD = max(maxDD, peak - x)
        }
        return maxDD
    }

    /// Pearson correlation.
    public static func correlation(_ xs: [Double], _ ys: [Double]) -> Double {
        precondition(xs.count == ys.count)
        guard xs.count > 1 else { return 0 }
        let mx = mean(xs), my = mean(ys)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in xs.indices {
            let dx = xs[i] - mx, dy = ys[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        let denom = (sxx * syy).squareRoot()
        return denom == 0 ? 0 : sxy / denom
    }

    /// Ordinary least squares y = a + b x. Returns (intercept, slope).
    public static func linearRegression(x: [Double], y: [Double]) -> (intercept: Double, slope: Double) {
        precondition(x.count == y.count && x.count >= 2)
        let mx = mean(x), my = mean(y)
        var sxy = 0.0, sxx = 0.0
        for i in x.indices {
            sxy += (x[i] - mx) * (y[i] - my)
            sxx += (x[i] - mx) * (x[i] - mx)
        }
        let slope = sxx == 0 ? 0 : sxy / sxx
        return (my - slope * mx, slope)
    }

    // MARK: - Paired t-test

    public struct PairedTTest: Sendable, Equatable {
        public let n: Int
        public let meanDifference: Double
        public let standardError: Double
        public let tStatistic: Double
        /// Two-sided p-value under Student's t with n-1 degrees of freedom.
        public let pValue: Double
        /// 95% confidence interval for the mean difference.
        public let confidenceInterval95: ClosedRange<Double>
    }

    /// Paired t-test of `a[i] - b[i]`.
    ///
    /// WHY paired: each trial i runs both strategies on the *same* seeded
    /// market, so the differences are matched and the market's own randomness
    /// cancels. This is far more powerful than comparing two independent
    /// samples and is the standard "common random numbers" technique.
    public static func pairedTTest(_ a: [Double], _ b: [Double]) -> PairedTTest? {
        precondition(a.count == b.count)
        let n = a.count
        guard n >= 2 else { return nil }
        let d = zip(a, b).map { $0 - $1 }
        let m = mean(d)
        let sd = standardDeviation(d)
        let se = sd / Double(n).squareRoot()
        let t = se == 0 ? (m == 0 ? 0 : Double.infinity * (m > 0 ? 1 : -1)) : m / se
        let df = Double(n - 1)
        let p = se == 0 ? (m == 0 ? 1 : 0) : 2 * (1 - studentTCDF(abs(t), degreesOfFreedom: df))
        let tCrit = studentTQuantile(0.975, degreesOfFreedom: df)
        return PairedTTest(
            n: n, meanDifference: m, standardError: se, tStatistic: t, pValue: p,
            confidenceInterval95: (m - tCrit * se)...(m + tCrit * se)
        )
    }

    // MARK: - Distributions (numerical)

    /// CDF of Student's t via the regularized incomplete beta function.
    /// P(T <= t) = 1 - 0.5 * I_{df/(df+t^2)}(df/2, 1/2) for t >= 0.
    public static func studentTCDF(_ t: Double, degreesOfFreedom df: Double) -> Double {
        if t.isInfinite { return t > 0 ? 1 : 0 }
        let x = df / (df + t * t)
        let ib = regularizedIncompleteBeta(x, a: df / 2, b: 0.5)
        return t >= 0 ? 1 - 0.5 * ib : 0.5 * ib
    }

    /// Quantile of Student's t by bisection on the CDF (monotone, well-behaved).
    public static func studentTQuantile(_ p: Double, degreesOfFreedom df: Double) -> Double {
        precondition(p > 0 && p < 1)
        var lo = -1e3, hi = 1e3
        for _ in 0..<200 {
            let mid = 0.5 * (lo + hi)
            if studentTCDF(mid, degreesOfFreedom: df) < p { lo = mid } else { hi = mid }
            if hi - lo < 1e-12 { break }
        }
        return 0.5 * (lo + hi)
    }

    /// Standard normal CDF.
    public static func normalCDF(_ x: Double) -> Double {
        0.5 * erfc(-x / 2.0.squareRoot())
    }

    /// Regularized incomplete beta I_x(a, b) via Lentz's continued fraction
    /// (Numerical Recipes §6.4). Accurate to ~1e-10 for the ranges used here.
    static func regularizedIncompleteBeta(_ x: Double, a: Double, b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let lbeta = lgamma(a) + lgamma(b) - lgamma(a + b)
        let front = exp(log(x) * a + log(1 - x) * b - lbeta)
        // Use the symmetry relation for faster convergence.
        if x > (a + 1) / (a + b + 2) {
            return 1 - regularizedIncompleteBeta(1 - x, a: b, b: a)
        }
        let cf = betaContinuedFraction(x, a: a, b: b)
        return front * cf / a
    }

    private static func betaContinuedFraction(_ x: Double, a: Double, b: Double) -> Double {
        let tiny = 1e-300
        let eps = 1e-14
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for m in 1...300 {
            let m2 = 2.0 * Double(m)
            var aa = Double(m) * (b - Double(m)) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d; h *= d * c
            aa = -(a + Double(m)) * (qab + Double(m)) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            let del = d * c
            h *= del
            if abs(del - 1) < eps { break }
        }
        return h
    }
}
