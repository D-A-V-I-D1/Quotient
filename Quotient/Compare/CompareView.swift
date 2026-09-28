//
//  CompareView.swift
//  Quotient
//
//  Paired Monte Carlo: same seeds for every strategy, paired t-tests on the
//  differences, distributions and markouts by counterparty.
//

import SwiftUI
import Charts
import QuotientCore

struct CompareView: View {
    @Environment(AppModel.self) private var app
    @State private var vm = CompareViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    setup
                    if vm.isRunning { runningPanel }
                    if let report = vm.report {
                        ResultsSection(report: report, summary: vm.lastRunSummary, markdown: vm.markdown)
                    } else if !vm.isRunning {
                        Panel {
                            Text("Runs every strategy on identical seeded markets (common random numbers) and tests the paired differences. Expect 100 trials × 3,000 steps to take a few seconds on device.")
                                .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                        }
                    }
                }
                .padding(12)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
        }
    }

    private var setup: some View {
        Panel(title: "Setup · \(app.selectedSymbol)") {
            HStack {
                Text("Scenario").font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Picker("Scenario", selection: $vm.presetName) {
                    ForEach(vm.presets(base: app.calibratedParameters)) { Text($0.name).tag($0.name) }
                }.tint(Theme.amber)
            }
            if let p = vm.presets(base: app.calibratedParameters).first(where: { $0.name == vm.presetName }) {
                Text(p.summary).font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
            }
            Stepper(value: $vm.trials, in: 20...500, step: 20) {
                HStack { Text("Trials").font(.system(size: 12)).foregroundStyle(Theme.inkSecondary); Spacer(); Text("\(vm.trials)").font(Theme.mono(13)).foregroundStyle(Theme.ink) }
            }
            HStack {
                Text("γ").font(.system(size: 12)).foregroundStyle(Theme.inkSecondary).frame(width: 20)
                Slider(value: $vm.gamma, in: 0.002...0.05).tint(Theme.amber)
                Text(String(format: "%.3f", vm.gamma)).font(Theme.mono(12)).foregroundStyle(Theme.ink).frame(width: 48, alignment: .trailing)
            }
            Button { vm.run(base: app.calibratedParameters) } label: {
                Label("Run paired Monte Carlo", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isRunning)
        }
    }

    private var runningPanel: some View {
        Panel {
            ProgressView(value: vm.progress) { Text("Running \(vm.trials) paired trials…").font(.system(size: 12)).foregroundStyle(Theme.inkSecondary) }
                .tint(Theme.amber)
        }
    }
}

private struct ResultsSection: View {
    let report: MonteCarloReport
    let summary: String
    let markdown: String

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(report.configuration.trials) trials · \(Fmt.num(report.wallClockSeconds, 1))s").font(Theme.mono(11)).foregroundStyle(Theme.inkMuted)
                Spacer()
                ShareLink(item: markdown, subject: Text("Quotient results")) { Label("Share markdown", systemImage: "square.and.arrow.up") }
                    .font(.system(size: 12))
            }
            ForEach(report.outcomes, id: \.name) { o in outcomeCard(o) }
            Panel(title: "Paired differences (A − B), same seeds") {
                ForEach(Array(report.comparisons.enumerated()), id: \.offset) { _, c in comparisonRow(c) }
            }
            Panel(title: "Final P&L distribution ($)") { pnlHistogram }
            Panel(title: "Markout at 50 steps by counterparty (ticks/lot)") { markoutChart }
            Panel(title: "Reading this") {
                Text("Negative markouts against informed counterparties are the empirical signature of adverse selection (Glosten–Milgrom). Lower RMS inventory and drawdown at similar spread capture is what Avellaneda–Stoikov's reservation-price skew buys. A paired p-value below 0.05 means the difference survived the trial-to-trial market noise; it says nothing about real-market profitability.")
                    .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private func outcomeCard(_ o: StrategyOutcome) -> some View {
        Panel {
            HStack {
                Circle().fill(Theme.seriesColor(for: o.name)).frame(width: 8, height: 8)
                Text(o.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text("win \(Fmt.pct(o.winRate))").font(Theme.mono(11)).foregroundStyle(Theme.inkSecondary)
            }
            HStack(spacing: 8) {
                StatTile(label: "P&L mean", value: Fmt.money(o.finalPnL.mean), color: Theme.pnlColor(o.finalPnL.mean), footnote: "± \(Fmt.num(o.finalPnL.standardDeviation, 0)) sd")
                StatTile(label: "Sharpe/sess", value: Fmt.num(o.sessionSharpe.mean, 2))
                StatTile(label: "Max DD", value: "$" + Fmt.num(o.maxDrawdown.mean, 0))
            }
            HStack(spacing: 8) {
                StatTile(label: "RMS inv", value: Fmt.num(o.rmsInventory.mean, 2), footnote: "max |q| \(Fmt.num(o.maxAbsInventory.mean, 1))")
                StatTile(label: "Fills", value: Fmt.num(o.fillCount.mean, 0), footnote: "spread \(Fmt.num(o.meanQuotedSpreadTicks.mean, 2))t")
                StatTile(label: "Markout 50", value: Fmt.signed(o.meanMarkoutTicks[50]?.mean ?? .nan, 2) + "t",
                         color: Theme.pnlColor(o.meanMarkoutTicks[50]?.mean ?? 0),
                         footnote: "inf \(Fmt.signed(o.meanMarkoutVsInformedTicks[50]?.mean ?? .nan, 1)) · noise \(Fmt.signed(o.meanMarkoutVsNoiseTicks[50]?.mean ?? .nan, 1))")
            }
        }
    }

    private func comparisonRow(_ c: PairedComparison) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(c.a)  −  \(c.b)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
            HStack {
                diffCell("ΔP&L", c.finalPnL.map { Fmt.money($0.meanDifference) }, c.finalPnL?.pValue, color: Theme.pnlColor(c.finalPnL?.meanDifference ?? 0))
                diffCell("ΔSharpe", c.sessionSharpe.map { Fmt.signed($0.meanDifference, 2) }, c.sessionSharpe?.pValue)
                diffCell("ΔMax DD", c.maxDrawdown.map { Fmt.signed($0.meanDifference, 0) }, c.maxDrawdown?.pValue)
                diffCell("ΔRMS inv", c.rmsInventory.map { Fmt.signed($0.meanDifference, 2) }, c.rmsInventory?.pValue)
            }
            if let t = c.finalPnL {
                Text("95% CI [\(Fmt.num(t.confidenceInterval95.lowerBound, 0)), \(Fmt.num(t.confidenceInterval95.upperBound, 0))] · t=\(Fmt.num(t.tStatistic, 2)) · A wins \(Fmt.pct(c.aWinsFraction)) of trials")
                    .font(Theme.mono(10)).foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.vertical, 4)
    }

    private func diffCell(_ label: String, _ value: String?, _ p: Double?, color: Color = Theme.ink) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkMuted)
            Text(value ?? "–").font(Theme.mono(12, weight: .semibold)).foregroundStyle(color)
            Text(Fmt.p(p)).font(Theme.mono(9)).foregroundStyle((p ?? 1) < 0.05 ? Theme.amber : Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Histogram binned in code so all strategies share bins.
    private struct Bin: Identifiable { let id: Int; let strategy: String; let lower: Double; let count: Int }
    private var bins: [Bin] {
        let all = report.outcomes.flatMap { $0.perTrial.map(\.finalPnL) }
        guard let lo = all.min(), let hi = all.max(), hi > lo else { return [] }
        let n = 18
        let width = (hi - lo) / Double(n)
        var out: [Bin] = []
        for o in report.outcomes {
            var counts = Array(repeating: 0, count: n)
            for v in o.perTrial.map(\.finalPnL) {
                counts[min(n - 1, Int((v - lo) / width))] += 1
            }
            for (i, c) in counts.enumerated() where c > 0 {
                out.append(Bin(id: out.count, strategy: o.name, lower: lo + Double(i) * width, count: c))
            }
        }
        return out
    }

    private var pnlHistogram: some View {
        Chart(bins) { b in
            BarMark(x: .value("P&L", b.lower), y: .value("Trials", b.count), width: .automatic)
                .foregroundStyle(by: .value("Strategy", b.strategy))
                .opacity(0.75)
        }
        .chartForegroundStyleScale(domain: report.outcomes.map(\.name), range: report.outcomes.map { Theme.seriesColor(for: $0.name) })
        .chartLegend(position: .top, alignment: .leading)
        .chartXAxis { AxisMarks { AxisGridLine().foregroundStyle(Theme.hairline); AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.inkMuted) } }
        .chartYAxis { AxisMarks(position: .trailing) { AxisGridLine().foregroundStyle(Theme.hairline); AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.inkMuted) } }
        .frame(height: 160)
    }

    private struct MarkoutPoint: Identifiable { let id = UUID(); let strategy: String; let counterparty: String; let value: Double }
    private var markoutPoints: [MarkoutPoint] {
        report.outcomes.flatMap { o in
            [MarkoutPoint(strategy: o.name, counterparty: "vs informed", value: o.meanMarkoutVsInformedTicks[50]?.mean ?? 0),
             MarkoutPoint(strategy: o.name, counterparty: "vs noise", value: o.meanMarkoutVsNoiseTicks[50]?.mean ?? 0)]
        }
    }

    private var markoutChart: some View {
        Chart(markoutPoints) { pt in
            BarMark(x: .value("Counterparty", pt.counterparty), y: .value("Markout", pt.value))
                .foregroundStyle(by: .value("Strategy", pt.strategy))
                .position(by: .value("Strategy", pt.strategy))
                .cornerRadius(3)
            RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.inkMuted.opacity(0.6))
        }
        .chartForegroundStyleScale(domain: report.outcomes.map(\.name), range: report.outcomes.map { Theme.seriesColor(for: $0.name) })
        .chartLegend(position: .top, alignment: .leading)
        .chartXAxis { AxisMarks { AxisValueLabel().font(.system(size: 10)).foregroundStyle(Theme.inkSecondary) } }
        .chartYAxis { AxisMarks(position: .trailing) { AxisGridLine().foregroundStyle(Theme.hairline); AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.inkMuted) } }
        .frame(height: 150)
    }
}
