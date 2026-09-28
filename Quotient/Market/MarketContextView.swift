//
//  MarketContextView.swift
//  Quotient
//
//  Shows the hard-coded snapshot the simulation is grounded in — with its
//  as-of date front and centre so staleness is obvious — and lets the user
//  choose which instrument seeds the Terminal.
//

import SwiftUI
import QuotientCore

struct MarketContextView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let snap = app.snapshot {
                        header(snap)
                        instruments(snap)
                        volatilityAndRates(snap)
                        headlines(snap)
                        microstructure(snap)
                        refreshNote
                    } else if let err = app.loadError {
                        Panel(title: "Snapshot failed to load") { Text(err).font(Theme.mono(11)).foregroundStyle(Theme.ask) }
                    } else {
                        ProgressView().tint(Theme.amber)
                    }
                }
                .padding(12)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Market Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
        }
    }

    private func header(_ s: MarketSnapshot) -> some View {
        Panel {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AS OF \(s.asOfDate)").font(Theme.mono(15, weight: .bold)).foregroundStyle(Theme.amber)
                    Text("researched \(s.retrievedDate) · source: \(app.dataSource.sourceName)").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                }
                Spacer()
                if let age = app.snapshotAgeDays {
                    Text(app.snapshotIsStale ? "STALE · \(age)d" : "\(age)d old")
                        .font(Theme.mono(11, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background((app.snapshotIsStale ? Theme.amber : Theme.inkMuted).opacity(0.2), in: Capsule())
                        .foregroundStyle(app.snapshotIsStale ? Theme.amber : Theme.inkSecondary)
                }
            }
            Text(s.notes).font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
        }
    }

    private func instruments(_ s: MarketSnapshot) -> some View {
        Panel(title: "Reference instruments · tap to load in Terminal") {
            ForEach(s.instruments) { i in
                Button {
                    app.selectedSymbol = i.symbol
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(i.symbol).font(Theme.mono(14, weight: .bold)).foregroundStyle(i.symbol == app.selectedSymbol ? Theme.amber : Theme.ink)
                                Text(i.assetClass.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                            }
                            Text(i.name).font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("$" + Fmt.price(i.lastPrice)).font(Theme.mono(14, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text("spread ~\(Fmt.num(i.typicalSpreadTicks ?? 0, 0))t · vol×\(Fmt.num(i.volatilityMultiplier, 1))").font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                        }
                        if i.symbol == app.selectedSymbol { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.amber) }
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                Divider().overlay(Theme.hairline)
            }
            let p = app.calibratedParameters
            Text("Calibrated: σ ≈ \(Fmt.num(p.fundamentalVolatilityTicks, 2)) ticks per \(Fmt.num(p.secondsPerStep, 1))s step from VIX \(Fmt.num(s.volatility.vixClose, 2)) × multiplier; crowd half-spread \(p.crowdHalfSpreadTicks) tick(s).")
                .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
        }
    }

    private func volatilityAndRates(_ s: MarketSnapshot) -> some View {
        Panel(title: "Volatility & rates") {
            HStack(spacing: 8) {
                StatTile(label: "VIX", value: Fmt.num(s.volatility.vixClose, 2), footnote: "1m \(Fmt.num(s.volatility.vixOneMonthLow, 1))–\(Fmt.num(s.volatility.vixOneMonthHigh, 1))")
                StatTile(label: "Fed funds", value: "\(Fmt.num(s.rates.fedFundsLowerPercent, 2))–\(Fmt.num(s.rates.fedFundsUpperPercent, 2))%", footnote: "\(s.rates.lastDecision) \(s.rates.lastDecisionBasisPoints)bp \(s.rates.lastDecisionDate)")
            }
            HStack(spacing: 8) {
                StatTile(label: "10Y", value: Fmt.num(s.rates.tenYearYieldPercent, 2) + "%")
                StatTile(label: "2Y", value: Fmt.num(s.rates.twoYearYieldPercent, 2) + "%")
                StatTile(label: "Next FOMC", value: s.rates.nextMeetingDate)
            }
        }
    }

    private func headlines(_ s: MarketSnapshot) -> some View {
        Panel(title: "Context") {
            ForEach(s.headlines) { h in
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.date).font(Theme.mono(10)).foregroundStyle(Theme.amber)
                    Text(h.headline).font(.system(size: 12)).foregroundStyle(Theme.ink)
                    if let url = URL(string: h.sourceURL) {
                        Link(url.host() ?? h.sourceURL, destination: url).font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func microstructure(_ s: MarketSnapshot) -> some View {
        Panel(title: "Microstructure") {
            Text("Minimum tick $\(Fmt.num(s.microstructure.minimumTickUSD, 3)).").font(.system(size: 12)).foregroundStyle(Theme.ink)
            Text(s.microstructure.notes).font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
            if !s.pairs.isEmpty {
                Text("Pairs: " + s.pairs.map { "\($0.symbolA)/\($0.symbolB)" }.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private var refreshNote: some View {
        Panel(title: "Refreshing this data") {
            Text("Everything on this screen comes from one file: QuotientCore/Sources/QuotientCore/MarketData/ReferenceData/market_snapshot.json, loaded through the MarketDataSource protocol. Edit the file to refresh the numbers; implement a new MarketDataSource to go live. No other code changes.")
                .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
        }
    }
}
