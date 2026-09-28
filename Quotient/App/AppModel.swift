//
//  AppModel.swift
//  Quotient
//
//  App-wide state: the market snapshot (loaded through the `MarketDataSource`
//  protocol — swap `BundledSnapshotDataSource()` for a live implementation
//  here and nothing else changes) and the instrument currently selected.
//

import Foundation
import Observation
import QuotientCore

@Observable
final class AppModel {
    /// The ONE place the data source is chosen.
    let dataSource: any MarketDataSource = BundledSnapshotDataSource()

    private(set) var snapshot: MarketSnapshot?
    private(set) var loadError: String?
    var selectedSymbol: String = "SPY"

    /// Simulation parameters calibrated from the snapshot for the selected symbol.
    var calibratedParameters: SimulationParameters {
        guard let snapshot, let p = try? Calibration.parameters(from: snapshot, symbol: selectedSymbol) else {
            return .example
        }
        return p
    }

    var selectedInstrument: ReferenceInstrument? { snapshot?.instrument(selectedSymbol) }

    /// Days since the snapshot's as-of date; the UI flags anything over two weeks.
    var snapshotAgeDays: Int? { snapshot?.ageInDays() }
    var snapshotIsStale: Bool { (snapshotAgeDays ?? 0) > 14 }

    func load() async {
        do {
            snapshot = try await dataSource.loadSnapshot()
            if snapshot?.instrument(selectedSymbol) == nil, let first = snapshot?.instruments.first {
                selectedSymbol = first.symbol
            }
        } catch {
            loadError = "\(error)"
        }
    }
}
