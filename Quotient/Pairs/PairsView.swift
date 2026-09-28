//
//  PairsView.swift
//  Quotient
//
//  Breadth demo: z-score pairs trading on a simulated cointegrated pair seeded
//  from the snapshot's KO/PEP prices, with the random-walk negative control.
//

import SwiftUI
import Charts
import QuotientCore

struct PairsView: View {
    @Environment(AppModel.self) private var app
    @State private var seed: UInt64 = 1
    @State private var meanReverting = true
    @State private var result: PairsResult?
    @State private var mcSummary: (mean: Double, t: Double, n: Int)?

    private var pair: ReferencePair? { app.snapshot?.pairs.first }
    private var params: PairsParameters {
        var p = PairsParameters()
        if let pair, let a = app.snapshot?.instrument(pair.symbolA), let b = app.snapshot?.instrument(pair.symbolB) {
            p.initialPriceA = a.lastPrice; p.initialPriceB = b.lastPrice
        }
        p.reversionSpeed = meanReverting ? 0.05 : 0
        return p
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Panel(title: "Pair · \(pair?.symbolA ?? "A") / \(pair?.symbolB ?? "B")") {
                        Text(pair?.rationale ?? "Two correlated simulated instruments.").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                        Toggle(isOn: $meanReverting) {
                            Text(meanReverting ? "Spread mean-reverts (θ = 0.05)" : "Negative control: random-walk spread (θ = 0)").font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                        }.tint(Theme.amber)
                        HStack {
                            Button { seed &+= 1; runOne() } label: { Label("New path", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                            Button { runMC() } label: { Label("60-trial Monte Carlo", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                        }
                    }
                    if let r = result {
                        HStack(spacing: 8) {
                            StatTile(label: "P&L (spread units)", value: Fmt.signed(r.finalPnL * 100, 2) + "%", color: Theme.pnlColor(r.finalPnL))
                            StatTile(label: "Trades", value: "\(r.trades)")
                            if let m = mcSummary {
                                StatTile(label: "MC mean · t", value: "\(Fmt.signed(m.mean * 100, 2))% · t=\(Fmt.num(m.t, 1))", color: Theme.pnlColor(m.mean), footnote: "\(m.n) seeds")
                            }
                        }
                        Panel(title: "z-score of the spread, entry bands ±2") { zChart(r) }
                        Panel(title: "Cumulative P&L") { pnlChart(r) }
                    }
                    Panel(title: "What this shows") {
                        Text("A rolling-OLS hedge ratio and z-score band rule. When the spread truly mean-reverts the rule is profitable across seeds; when it is a random walk it is not — the negative control is what separates a real effect from an in-sample artifact. A first version of this code accrued P&L on the re-fitted residual and passed the positive test while failing the control; the fix locks β at entry (see PairsTrading.swift).")
                            .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                    }
                }
                .padding(12)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Pairs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
        }
        .onAppear { if result == nil { runOne() } }
        .onChange(of: meanReverting) { runOne() }
    }

    private func runOne() {
        result = PairsSimulator.run(params, seed: seed)
        mcSummary = nil
    }

    private func runMC() {
        let p = params
        Task.detached {
            let pnls = PairsSimulator.monteCarlo(p, trials: 60)
            let mean = Statistics.mean(pnls)
            let sd = Statistics.standardDeviation(pnls)
            let t = sd > 0 ? mean / (sd / Double(pnls.count).squareRoot()) : 0
            await MainActor.run { mcSummary = (mean, t, pnls.count) }
        }
    }

    private func zChart(_ r: PairsResult) -> some View {
        Chart {
            ForEach(Array(r.zScore.enumerated()), id: \.offset) { i, z in
                LineMark(x: .value("Step", i), y: .value("z", z)).foregroundStyle(Theme.amber).lineStyle(.init(lineWidth: 1.2))
            }
            RuleMark(y: .value("Entry", 2)).foregroundStyle(Theme.inkMuted).lineStyle(.init(lineWidth: 1, dash: [3, 3]))
            RuleMark(y: .value("Entry", -2)).foregroundStyle(Theme.inkMuted).lineStyle(.init(lineWidth: 1, dash: [3, 3]))
            ForEach(Array(r.position.enumerated()), id: \.offset) { i, p in
                if p != 0 {
                    PointMark(x: .value("Step", i), y: .value("pos", Double(p) * 3.5)).foregroundStyle(p > 0 ? Theme.bid : Theme.ask).symbolSize(6)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .trailing) { AxisGridLine().foregroundStyle(Theme.hairline); AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.inkMuted) } }
        .frame(height: 140)
    }

    private func pnlChart(_ r: PairsResult) -> some View {
        Chart {
            ForEach(Array(r.pnl.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("Step", i), y: .value("P&L", v * 100)).foregroundStyle(Theme.amber).lineStyle(.init(lineWidth: 1.5))
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.inkMuted.opacity(0.5)).lineStyle(.init(lineWidth: 1, dash: [3, 3]))
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .trailing) { AxisGridLine().foregroundStyle(Theme.hairline); AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.inkMuted) } }
        .frame(height: 110)
    }
}
