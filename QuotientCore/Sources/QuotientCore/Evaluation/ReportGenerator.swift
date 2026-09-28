//
//  ReportGenerator.swift
//  QuotientCore
//
//  Renders a `MonteCarloReport` as Markdown. Used to produce the results
//  tables in the README (so the numbers there are generated, not typed) and
//  by the app's share/export action.
//

import Foundation

public enum ReportGenerator {

    public static func markdown(_ report: MonteCarloReport, title: String? = nil, scenarioSummary: String? = nil) -> String {
        var out = ""
        if let t = title { out += "### \(t)\n\n" }
        if let s = scenarioSummary { out += "_\(s)_\n\n" }
        let p = report.configuration.parameters
        out += "\(report.configuration.trials) paired trials · \(p.steps) steps · σ=\(fmt(p.fundamentalVolatilityTicks, 2)) ticks/step · μ=\(fmt(p.informedFraction, 2)) informed · jumps p=\(fmt(p.jumpProbability, 3)) × \(fmt(p.jumpSizeTicks, 0)) ticks · drift \(fmt(p.fundamentalDriftTicks, 3)) ticks/step\n\n"

        out += "| Strategy | Final P&L ($) mean ± sd | Win rate | Session Sharpe | Max DD ($) | RMS inv (lots) | Max |inv| | Fills | Quoted spread (ticks) | Capture (ticks) | Markout 50 (ticks) | vs informed | vs noise |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for o in report.outcomes {
            out += "| \(o.name) | \(fmt(o.finalPnL.mean, 0)) ± \(fmt(o.finalPnL.standardDeviation, 0)) | \(fmt(o.winRate * 100, 0))% | \(fmt(o.sessionSharpe.mean, 2)) | \(fmt(o.maxDrawdown.mean, 0)) | \(fmt(o.rmsInventory.mean, 2)) | \(fmt(o.maxAbsInventory.mean, 1)) | \(fmt(o.fillCount.mean, 0)) | \(fmt(o.meanQuotedSpreadTicks.mean, 2)) | \(fmt(o.meanCaptureTicks.mean, 2)) | \(fmt(o.meanMarkoutTicks[50]?.mean, 2)) | \(fmt(o.meanMarkoutVsInformedTicks[50]?.mean, 2)) | \(fmt(o.meanMarkoutVsNoiseTicks[50]?.mean, 2)) |\n"
        }
        out += "\n**Paired differences (A − B), same seeds:**\n\n"
        out += "| A | B | ΔP&L ($) | 95% CI | t | p | ΔSharpe (p) | ΔMax DD ($) | ΔRMS inv | A wins |\n|---|---|---|---|---|---|---|---|---|---|\n"
        for c in report.comparisons {
            let pnl = c.finalPnL
            out += "| \(c.a) | \(c.b) | \(fmt(pnl?.meanDifference, 0)) | [\(fmt(pnl?.confidenceInterval95.lowerBound, 0)), \(fmt(pnl?.confidenceInterval95.upperBound, 0))] | \(fmt(pnl?.tStatistic, 2)) | \(pval(pnl?.pValue)) | \(fmt(c.sessionSharpe?.meanDifference, 2)) (\(pval(c.sessionSharpe?.pValue))) | \(fmt(c.maxDrawdown?.meanDifference, 0)) | \(fmt(c.rmsInventory?.meanDifference, 2)) | \(fmt(c.aWinsFraction * 100, 0))% |\n"
        }
        return out
    }

    static func fmt(_ x: Double?, _ decimals: Int) -> String {
        guard let x, x.isFinite else { return "–" }
        return String(format: "%.\(decimals)f", x)
    }

    static func pval(_ p: Double?) -> String {
        guard let p else { return "–" }
        if p < 0.0001 { return "<0.0001" }
        return String(format: "%.4f", p)
    }
}
