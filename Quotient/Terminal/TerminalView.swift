//
//  TerminalView.swift
//  Quotient
//
//  The live demonstration: a simulated order book, the selected strategy's
//  quotes, P&L and inventory, and the controls to switch strategies (or take
//  over manually) while the same order flow keeps arriving.
//

import SwiftUI
import Charts
import QuotientCore

struct TerminalView: View {
    @Environment(AppModel.self) private var app
    @State private var vm: TerminalViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let vm { TerminalContent(vm: vm) } else { ProgressView().tint(Theme.amber) }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Quotient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image("Quotient-icon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Text("Quotient").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                }
            }
        }
        // Rebuild when the snapshot finishes loading or the instrument changes.
        // The id must include snapshot presence: the view appears before the
        // async load completes, and the symbol alone would never change.
        .task(id: "\(app.selectedSymbol)|\(app.snapshot?.asOfDate ?? "")") {
            guard app.snapshot != nil else { return }
            let p = app.calibratedParameters
            if let vm { vm.pause(); vm.setParameters(p, preset: ScenarioPreset.baseline(p)); vm.rebuild(keepingSeed: true) }
            else { vm = TerminalViewModel(parameters: p) }
            if CommandLine.arguments.contains("-autoplay") { vm?.play() }
        }
        .onAppear { if vm == nil, app.snapshot == nil { vm = TerminalViewModel(parameters: .example) } }
    }
}

private struct TerminalContent: View {
    @Bindable var vm: TerminalViewModel
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                headerBar
                strategyPicker
                signalsRow
                Panel(title: "Order book · \(vm.instrument.symbol)") {
                    OrderBookLadderView(bids: vm.bids, asks: vm.asks, makerQuotes: vm.makerQuotes,
                                        instrument: vm.instrument, midTicks: vm.state.midTicks, spreadTicks: vm.state.spreadTicks)
                    makerQuoteLine
                }
                tiles
                charts
                controls
                if vm.strategyChoice == .manual { manualControls }
                fillsTape
                Text(vm.strategySummary)
                    .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, 4)
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        // The simulator updates ~20×/s; implicit animations on any of this
        // content would fight the scroll view and make it judder.
        .transaction { $0.animation = nil }
    }

    /// Fixed-width trailing axis so the plot area does not shift as label
    /// widths change (e.g. "$0" → "−$1,250").
    private func fixedAxis() -> some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel {
                if let d = value.as(Double.self) {
                    Text(d, format: .number.precision(.fractionLength(0)))
                        .font(Theme.mono(9)).monospacedDigit().foregroundStyle(Theme.inkMuted)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Pieces

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(vm.instrument.symbol).font(Theme.mono(20, weight: .bold)).foregroundStyle(Theme.amber)
                    Text(vm.dollars(vm.state.midTicks)).font(Theme.mono(20, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                }
                Text("\(vm.instrument.name) · \(vm.preset.name) · seed \(vm.seed)")
                    .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("step \(vm.simulator.step)/\(vm.parameters.steps)").font(Theme.mono(11)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                    .frame(width: 130, alignment: .trailing)
                ProgressView(value: vm.progress).tint(Theme.amber).frame(width: 90)
            }
        }
    }

    private var strategyPicker: some View {
        Picker("Strategy", selection: $vm.strategyChoice) {
            ForEach(TerminalViewModel.StrategyChoice.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var signalsRow: some View {
        HStack(spacing: 8) {
            StatTile(label: "Microprice", value: vm.dollars(vm.state.micropriceTicks),
                     color: Theme.ink, footnote: vm.simulator.microprice.isFitted ? "Stoikov fit" : "weighted mid")
            StatTile(label: "Imbalance", value: Fmt.signed(vm.state.imbalance, 2),
                     color: Theme.ink, footnote: "OFI \(Fmt.signed(vm.state.orderFlowImbalance, 0))")
            StatTile(label: "σ est", value: Fmt.num(vm.state.sigmaTicksPerStep, 2) + "t",
                     color: Theme.ink, footnote: "true \(Fmt.num(vm.parameters.fundamentalVolatilityTicks, 2))t")
        }
    }

    private var makerQuoteLine: some View {
        HStack {
            Label {
                Text(vm.makerQuotes.bid.map(vm.dollars) ?? "—").font(Theme.mono(12)).monospacedDigit().frame(width: 60, alignment: .leading)
            } icon: { Circle().fill(Theme.bid).frame(width: 6, height: 6) }
            Text("my bid").font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
            Spacer()
            Text("my ask").font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
            Label {
                Text(vm.makerQuotes.ask.map(vm.dollars) ?? "—").font(Theme.mono(12)).monospacedDigit().frame(width: 60, alignment: .trailing)
            } icon: { Circle().fill(Theme.ask).frame(width: 6, height: 6) }
        }
        .foregroundStyle(Theme.ink)
        .padding(.top, 4)
    }

    private var tiles: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                StatTile(label: "P&L (MTM)", value: Fmt.money(vm.pnl, decimals: 0), color: Theme.pnlColor(vm.pnl))
                StatTile(label: "Inventory", value: "\(vm.inventory > 0 ? "+" : "")\(vm.inventory) lots",
                         color: vm.inventory == 0 ? Theme.ink : (vm.inventory > 0 ? Theme.bid : Theme.ask),
                         footnote: "\(vm.instrument.lotSize) sh/lot")
            }
            HStack(spacing: 8) {
                StatTile(label: "Fills", value: "\(vm.simulator.fills.count)",
                         footnote: "\(vm.simulator.fills.filter { $0.counterparty == .informedTrader }.count) vs informed")
                StatTile(label: "Markout 50", value: vm.meanMarkout50.map { Fmt.signed($0, 2) + "t" } ?? "—",
                         color: vm.meanMarkout50.map(Theme.pnlColor) ?? Theme.ink, footnote: "ticks/lot, − = adverse")
                StatTile(label: "Strategy", value: vm.strategyName, color: Theme.amber)
            }
        }
    }

    private var charts: some View {
        VStack(spacing: 8) {
            Panel(title: "P&L ($)") {
                Chart {
                    ForEach(Array(vm.pnlSeries.enumerated()), id: \.offset) { i, v in
                        LineMark(x: .value("Step", i), y: .value("P&L", v)).foregroundStyle(Theme.amber).lineStyle(.init(lineWidth: 1.5))
                    }
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(Theme.inkMuted.opacity(0.5)).lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                }
                .chartXAxis(.hidden)
                .chartYAxis { fixedAxis() }
                .frame(height: 110)
            }
            Panel(title: "Inventory (lots)") {
                Chart {
                    ForEach(Array(vm.inventorySeries.enumerated()), id: \.offset) { i, v in
                        LineMark(x: .value("Step", i), y: .value("Inv", v)).foregroundStyle(Theme.inkSecondary).lineStyle(.init(lineWidth: 1.5))
                    }
                    RuleMark(y: .value("Flat", 0)).foregroundStyle(Theme.inkMuted.opacity(0.5)).lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                }
                .chartXAxis(.hidden)
                .chartYAxis { fixedAxis() }
                .frame(height: 90)
            }
        }
    }

    private var controls: some View {
        Panel(title: "Controls") {
            HStack(spacing: 10) {
                Button { vm.isRunning ? vm.pause() : vm.play() } label: {
                    Label(vm.isRunning ? "Pause" : "Run", systemImage: vm.isRunning ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.simulator.isFinished)
                Button { vm.step(10) } label: { Label("+10", systemImage: "forward.frame") }.buttonStyle(.bordered)
                Button { vm.reset() } label: { Label("New seed", systemImage: "arrow.counterclockwise") }.buttonStyle(.bordered)
            }
            HStack {
                Text("Speed").font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                Picker("Speed", selection: $vm.speed) {
                    ForEach(TerminalViewModel.Speed.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).frame(width: 160)
                Spacer()
                Menu {
                    ForEach(ScenarioPreset.all(base: app.calibratedParameters)) { p in
                        Button(p.name) { vm.applyPreset(p) }
                    }
                } label: { Label(vm.preset.name, systemImage: "slider.horizontal.3") }
            }
            sliderRow("γ risk aversion", value: $vm.gamma, range: 0.002...0.05, format: "%.3f", disabled: vm.strategyChoice == .manual)
            sliderRow("μ informed fraction", value: $vm.informedFraction, range: 0...0.6, format: "%.2f")
            Toggle(isOn: $vm.maxInventoryEnabled) {
                Text("Hard inventory limit (±5 lots)").font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
            }.tint(Theme.amber)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, disabled: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(disabled ? Theme.inkMuted : Theme.inkSecondary).frame(width: 130, alignment: .leading)
            Slider(value: value, in: range).tint(Theme.amber).disabled(disabled)
            Text(String(format: format, value.wrappedValue)).font(Theme.mono(12)).foregroundStyle(Theme.ink).frame(width: 48, alignment: .trailing)
        }
    }

    private var manualControls: some View {
        Panel(title: "You are the market maker") {
            Text("Set your half-spread and skew. Positive skew lowers both quotes (you want to sell). Watch inventory and markouts — that is the interview game.")
                .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
            Stepper(value: $vm.manualHalfSpread, in: 0.5...10, step: 0.5) {
                HStack { Text("Half-spread"); Spacer(); Text("\(Fmt.num(vm.manualHalfSpread, 1)) ticks").font(Theme.mono(13)) }
            }
            Stepper(value: $vm.manualSkew, in: -10...10, step: 0.5) {
                HStack { Text("Skew"); Spacer(); Text("\(Fmt.signed(vm.manualSkew, 1)) ticks").font(Theme.mono(13)) }
            }
            Stepper(value: $vm.manualSize, in: 0...10) {
                HStack { Text("Size"); Spacer(); Text("\(vm.manualSize) lots").font(Theme.mono(13)) }
            }
        }
        .font(.system(size: 13)).foregroundStyle(Theme.ink)
    }

    private let fillRows = 8

    private var fillsTape: some View {
        Panel(title: "Fills") {
            // Always `fillRows` rows so the panel height is constant.
            ForEach(0..<fillRows, id: \.self) { i in
                if i < vm.recentFills.count {
                    fillRow(vm.recentFills[i])
                } else {
                    HStack {
                        if i == 0 { Text("No fills yet.").font(.system(size: 12)).foregroundStyle(Theme.inkMuted) }
                        Spacer()
                    }
                    .frame(height: 18)
                }
            }
        }
    }

    private func fillRow(_ f: MarketMakerFill) -> some View {
        HStack {
            Text(f.side == .bid ? "BUY" : "SELL").font(Theme.mono(11, weight: .bold))
                .foregroundStyle(f.side == .bid ? Theme.bid : Theme.ask).frame(width: 36, alignment: .leading)
            Text("\(f.quantity) @ \(vm.dollars(f.price))").font(Theme.mono(12)).monospacedDigit().foregroundStyle(Theme.ink)
            Spacer()
            Text(counterpartyLabel(f.counterparty)).font(.system(size: 10)).foregroundStyle(f.counterparty == .informedTrader ? Theme.amber : Theme.inkMuted)
            Text("t=\(f.step)").font(Theme.mono(10)).monospacedDigit().foregroundStyle(Theme.inkMuted).frame(width: 56, alignment: .trailing)
        }
        .frame(height: 18)
    }

    private func counterpartyLabel(_ p: Participant) -> String {
        switch p {
        case .informedTrader: return "informed"
        case .noiseTrader: return "noise"
        case .backgroundLiquidity: return "crowd"
        case .marketMaker: return "self"
        case .manual: return "manual"
        }
    }
}
