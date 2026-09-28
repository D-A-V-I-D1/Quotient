//
//  PerformanceMetrics.swift
//  QuotientCore
//
//  Turns a `SimulationResult` into the numbers a desk would actually look at.
//  Every metric states its units. Nothing here is specific to simulated data.
//

import Foundation

public struct PerformanceMetrics: Sendable, Equatable {
    public let strategyName: String
    public let seed: UInt64

    /// Final mark-to-market P&L, dollars.
    public let finalPnL: Double
    /// Per-session Sharpe: mean(ΔPnL) / sd(ΔPnL) · √steps. Dimensionless.
    /// This is the t-statistic of the session's P&L path; it is NOT
    /// annualised because per-step P&L increments at sub-second horizons are
    /// not the kind of returns an annualised Sharpe is meant to summarise.
    public let sessionSharpe: Double
    /// Largest peak-to-trough decline of P&L, dollars.
    public let maxDrawdown: Double
    /// Root-mean-square inventory over the session, lots.
    public let rmsInventory: Double
    /// Largest absolute position reached, lots.
    public let maxAbsInventory: Int
    public let finalInventory: Int
    public let fillCount: Int
    /// Lots traded.
    public let volume: Int
    /// Fraction of fills where the maker was the resting order.
    public let makerFillRatio: Double
    /// Mean immediate edge vs. mid at fill time, ticks per lot ("spread capture").
    public let meanCaptureTicks: Double
    /// Mean of the maker's own quoted spread over steps it was two-sided, ticks.
    public let meanQuotedSpreadTicks: Double
    /// Fraction of steps the maker was quoting both sides.
    public let twoSidedFraction: Double
    /// Mean markout at each horizon, ticks per lot. Key = horizon in steps.
    public let meanMarkoutTicks: [Int: Double]
    /// Mean markout against informed counterparties only (nil if none).
    public let meanMarkoutVsInformedTicks: [Int: Double]
    /// Mean markout against noise counterparties only (nil if none).
    public let meanMarkoutVsNoiseTicks: [Int: Double]
    /// Decomposition of final P&L (dollars): spread capture + inventory MTM.
    /// Sums to `finalPnL` up to floating-point rounding.
    public let spreadCapturePnL: Double
    public let inventoryPnL: Double

    /// Direct initialiser for tests and previews that need a specific shape
    /// of result without running a simulation.
    init(strategyName: String, seed: UInt64 = 0, finalPnL: Double, sessionSharpe: Double, maxDrawdown: Double,
         rmsInventory: Double, maxAbsInventory: Int, finalInventory: Int, fillCount: Int, volume: Int,
         makerFillRatio: Double = 1, meanCaptureTicks: Double, meanQuotedSpreadTicks: Double, twoSidedFraction: Double = 1,
         meanMarkoutTicks: [Int: Double], meanMarkoutVsInformedTicks: [Int: Double], meanMarkoutVsNoiseTicks: [Int: Double],
         spreadCapturePnL: Double, inventoryPnL: Double) {
        self.strategyName = strategyName; self.seed = seed; self.finalPnL = finalPnL; self.sessionSharpe = sessionSharpe
        self.maxDrawdown = maxDrawdown; self.rmsInventory = rmsInventory; self.maxAbsInventory = maxAbsInventory
        self.finalInventory = finalInventory; self.fillCount = fillCount; self.volume = volume; self.makerFillRatio = makerFillRatio
        self.meanCaptureTicks = meanCaptureTicks; self.meanQuotedSpreadTicks = meanQuotedSpreadTicks; self.twoSidedFraction = twoSidedFraction
        self.meanMarkoutTicks = meanMarkoutTicks; self.meanMarkoutVsInformedTicks = meanMarkoutVsInformedTicks
        self.meanMarkoutVsNoiseTicks = meanMarkoutVsNoiseTicks; self.spreadCapturePnL = spreadCapturePnL; self.inventoryPnL = inventoryPnL
    }

    public init(result r: SimulationResult) {
        strategyName = r.strategyName
        seed = r.seed
        finalPnL = r.finalPnLDollars

        let increments = zip(r.pnlDollars.dropFirst(), r.pnlDollars).map { $0 - $1 }
        let sd = Statistics.standardDeviation(increments)
        sessionSharpe = sd == 0 ? 0 : Statistics.mean(increments) / sd * Double(increments.count).squareRoot()
        maxDrawdown = Statistics.maxDrawdown(r.pnlDollars)
        rmsInventory = Statistics.rootMeanSquare(r.inventory.map(Double.init))
        maxAbsInventory = r.inventory.map { abs($0) }.max() ?? 0
        finalInventory = r.finalInventory
        fillCount = r.fills.count
        volume = r.fills.reduce(0) { $0 + $1.quantity }
        makerFillRatio = r.fills.isEmpty ? 0 : Double(r.fills.filter(\.wasMaker).count) / Double(r.fills.count)

        let quoted = r.quotedSpreadTicks.compactMap { $0 }.map(Double.init)
        meanQuotedSpreadTicks = Statistics.mean(quoted)
        twoSidedFraction = r.quotedSpreadTicks.isEmpty ? 0 : Double(quoted.count) / Double(r.quotedSpreadTicks.count)

        let perLot = r.dollarsPerTickLot
        let captureTicks = r.fills.map { $0.captureTicks * Double($0.quantity) }
        let totalLots = Double(max(1, volume))
        meanCaptureTicks = r.fills.isEmpty ? 0 : captureTicks.reduce(0, +) / totalLots
        spreadCapturePnL = captureTicks.reduce(0, +) * perLot
        inventoryPnL = finalPnL - spreadCapturePnL

        var all: [Int: Double] = [:], inf: [Int: Double] = [:], noise: [Int: Double] = [:]
        for h in r.parameters.markoutHorizons {
            let m = r.markouts(horizon: h)
            if !m.isEmpty { all[h] = Statistics.mean(m) }
            let mi = r.markouts(horizon: h, counterparty: .informedTrader)
            if !mi.isEmpty { inf[h] = Statistics.mean(mi) }
            let mn = r.markouts(horizon: h, counterparty: .noiseTrader)
            if !mn.isEmpty { noise[h] = Statistics.mean(mn) }
        }
        meanMarkoutTicks = all
        meanMarkoutVsInformedTicks = inf
        meanMarkoutVsNoiseTicks = noise
    }
}

extension SimulationResult {
    var dollarsPerTickLot: Double { parameters.dollarsPerTickLot }
}
