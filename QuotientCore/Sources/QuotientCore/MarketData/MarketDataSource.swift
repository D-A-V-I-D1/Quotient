//
//  MarketDataSource.swift
//  QuotientCore
//
//  The seam between "the data the algorithm consumes" and everything else.
//
//  Today there is exactly one production implementation:
//  `BundledSnapshotDataSource`, which loads a hand-researched JSON file dated
//  the day it was compiled. The point of the protocol is that this is the ONLY
//  place that knows where market context comes from:
//
//    * Refreshing the numbers   = edit `ReferenceData/market_snapshot.json`.
//    * Going live               = write `struct LiveMarketDataSource:
//                                 MarketDataSource` that calls a real API and
//                                 returns the same `MarketSnapshot` type.
//
//  Neither change touches the strategies, the simulator or the UI, because
//  they only ever see `MarketSnapshot` and `SimulationParameters`.
//  See ReferenceData/README.md for the step-by-step.
//

import Foundation

public protocol MarketDataSource: Sendable {
    /// Human-readable identifier shown in the UI ("Bundled snapshot", "Polygon.io", …).
    var sourceName: String { get }
    /// Load the current market context. `async throws` so a network-backed
    /// implementation fits the same signature without changing callers.
    func loadSnapshot() async throws -> MarketSnapshot
}

// MARK: - Snapshot schema

/// A dated bundle of real-world reference values. Schema is versioned so a
/// future live source (or an updated JSON) can be validated on load.
public struct MarketSnapshot: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// The trading date the values describe (ISO 8601 date, e.g. "2026-09-25").
    public let asOfDate: String
    /// When the research was performed (ISO 8601 date).
    public let retrievedDate: String
    /// Free-text notes on provenance and caveats.
    public let notes: String
    public let instruments: [ReferenceInstrument]
    public let volatility: VolatilityContext
    public let rates: RatesContext
    public let headlines: [MacroHeadline]
    public let pairs: [ReferencePair]
    public let microstructure: MicrostructureContext

    public func instrument(_ symbol: String) -> ReferenceInstrument? {
        instruments.first { $0.symbol == symbol }
    }

    /// Days since `asOfDate`, or nil if the date fails to parse.
    public func ageInDays(now: Date = Date()) -> Int? {
        guard let d = MarketSnapshot.isoDate(asOfDate) else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: d, to: now).day
    }

    public static func isoDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}

public struct ReferenceInstrument: Sendable, Codable, Equatable, Identifiable {
    public var id: String { symbol }
    public let symbol: String
    public let name: String
    /// "etf", "stock", "index".
    public let assetClass: String
    /// Last close, USD (or index points).
    public let lastPrice: Double
    public let priceAsOfDate: String
    /// Minimum price increment, USD.
    public let tickSize: Double
    /// Typical quoted spread in ticks at the touch, if known.
    public let typicalSpreadTicks: Double?
    /// Approximate average daily volume in shares, if known.
    public let averageDailyVolumeShares: Double?
    /// Multiplier applied to the market-wide (VIX-implied) volatility to
    /// approximate this instrument's own volatility. 1.0 for a broad index ETF.
    public let volatilityMultiplier: Double
    public let sourceURL: String
    public let notes: String?
}

public struct VolatilityContext: Sendable, Codable, Equatable {
    /// CBOE VIX close (annualised % implied vol of the S&P 500).
    public let vixClose: Double
    public let vixAsOfDate: String
    public let vixOneMonthLow: Double
    public let vixOneMonthHigh: Double
    public let sourceURL: String
}

public struct RatesContext: Sendable, Codable, Equatable {
    public let fedFundsLowerPercent: Double
    public let fedFundsUpperPercent: Double
    public let lastDecisionDate: String
    /// "hike", "cut", "hold".
    public let lastDecision: String
    public let lastDecisionBasisPoints: Int
    public let nextMeetingDate: String
    public let tenYearYieldPercent: Double
    public let twoYearYieldPercent: Double
    public let sourceURLs: [String]
}

public struct MacroHeadline: Sendable, Codable, Equatable, Identifiable {
    public var id: String { date + headline }
    public let date: String
    public let headline: String
    public let sourceURL: String
}

public struct ReferencePair: Sendable, Codable, Equatable, Identifiable {
    public var id: String { symbolA + "/" + symbolB }
    public let symbolA: String
    public let symbolB: String
    public let rationale: String
}

public struct MicrostructureContext: Sendable, Codable, Equatable {
    /// Baseline minimum tick for NMS stocks priced ≥ $1, USD.
    public let minimumTickUSD: Double
    public let notes: String
    public let sourceURL: String
}

// MARK: - Implementations

/// Loads the hand-researched snapshot shipped inside the package.
public struct BundledSnapshotDataSource: MarketDataSource {
    public var sourceName: String { "Bundled snapshot" }
    public init() {}

    public func loadSnapshot() async throws -> MarketSnapshot {
        guard let url = Bundle.module.url(forResource: "market_snapshot", withExtension: "json") else {
            throw MarketDataError.resourceMissing("market_snapshot.json")
        }
        let data = try Data(contentsOf: url)
        return try MarketSnapshotDecoder.decode(data)
    }
}

/// Wraps an in-memory snapshot. For tests, previews and dependency injection.
public struct InMemoryMarketDataSource: MarketDataSource {
    public let sourceName: String
    public let snapshot: MarketSnapshot
    public init(snapshot: MarketSnapshot, sourceName: String = "In-memory") {
        self.snapshot = snapshot
        self.sourceName = sourceName
    }
    public func loadSnapshot() async throws -> MarketSnapshot { snapshot }
}

public enum MarketDataError: Error, Equatable, CustomStringConvertible {
    case resourceMissing(String)
    case unsupportedSchema(found: Int, expected: Int)
    case invalid(String)

    public var description: String {
        switch self {
        case .resourceMissing(let n): return "Missing resource: \(n)"
        case .unsupportedSchema(let f, let e): return "Snapshot schema \(f) not supported (expected \(e))"
        case .invalid(let why): return "Invalid snapshot: \(why)"
        }
    }
}

public enum MarketSnapshotDecoder {
    /// Decode and validate. Validation catches the mistakes a hand-edited JSON
    /// is most likely to contain, and fails loudly rather than letting a bad
    /// number silently mis-calibrate the simulation.
    public static func decode(_ data: Data) throws -> MarketSnapshot {
        let snap = try JSONDecoder().decode(MarketSnapshot.self, from: data)
        guard snap.schemaVersion == MarketSnapshot.currentSchemaVersion else {
            throw MarketDataError.unsupportedSchema(found: snap.schemaVersion, expected: MarketSnapshot.currentSchemaVersion)
        }
        guard MarketSnapshot.isoDate(snap.asOfDate) != nil else { throw MarketDataError.invalid("asOfDate not yyyy-MM-dd") }
        guard !snap.instruments.isEmpty else { throw MarketDataError.invalid("no instruments") }
        for i in snap.instruments {
            guard i.lastPrice > 0 else { throw MarketDataError.invalid("\(i.symbol) lastPrice must be > 0") }
            guard i.tickSize > 0 else { throw MarketDataError.invalid("\(i.symbol) tickSize must be > 0") }
            guard i.volatilityMultiplier > 0 else { throw MarketDataError.invalid("\(i.symbol) volatilityMultiplier must be > 0") }
        }
        guard snap.volatility.vixClose > 0 else { throw MarketDataError.invalid("vixClose must be > 0") }
        for p in snap.pairs {
            guard snap.instrument(p.symbolA) != nil, snap.instrument(p.symbolB) != nil else {
                throw MarketDataError.invalid("pair \(p.id) references unknown instrument")
            }
        }
        return snap
    }
}
