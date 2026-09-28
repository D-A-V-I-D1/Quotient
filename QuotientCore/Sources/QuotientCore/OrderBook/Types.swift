//
//  Types.swift
//  QuotientCore
//
//  Core value types shared by the order book, simulator and strategies.
//

import Foundation

/// Side of the book an order rests on / the direction of a trade.
public enum Side: String, Sendable, Codable, CaseIterable, Hashable {
    case bid
    case ask

    public var opposite: Side { self == .bid ? .ask : .bid }

    /// +1 for a buy, -1 for a sell. Used to sign inventory and markouts.
    public var sign: Int { self == .bid ? 1 : -1 }
}

/// Prices are integers in units of the instrument's tick.
///
/// WHY integer ticks and not `Double`:
///   * Doubles can't represent most decimal prices exactly (e.g. 0.1), so
///     equality/ordering comparisons in a price-time matching engine become
///     fragile. Exchanges (CME, Nasdaq ITCH, etc.) transmit prices as scaled
///     integers for this reason.
///   * Integers make price levels hashable and comparable in O(1) with no
///     epsilon logic, and make the dense "price ladder" data structure possible.
///
/// `Instrument.tickSize` converts to/from a human-readable `Double`.
public typealias Ticks = Int64

/// Opaque, monotonically increasing order identifier.
public typealias OrderID = UInt64

/// Which class of participant owns an order. The book itself is agnostic; this
/// exists so fills can be attributed (the strategy's P&L, markouts, and
/// per-agent statistics all depend on knowing who was on each side).
public enum Participant: UInt8, Sendable, Codable, Hashable {
    /// The market-making strategy under evaluation.
    case marketMaker
    /// Background liquidity ("the crowd") that keeps the book populated.
    case backgroundLiquidity
    /// Uninformed / liquidity-motivated aggressive traders.
    case noiseTrader
    /// Traders who observe the fundamental before it is public (Glosten–Milgrom).
    case informedTrader
    /// A human tapping buttons in the app.
    case manual
}

/// An order as it is held in the book.
public struct Order: Sendable, Hashable, Identifiable {
    public let id: OrderID
    public let side: Side
    public let price: Ticks
    public let originalQuantity: Int
    public internal(set) var remainingQuantity: Int
    public let owner: Participant
    /// Logical time of arrival — a sequence number, not a wall clock.
    /// WHY: time priority must be a strict total order; wall clocks can tie or
    /// go backwards. Real venues do the same (sequence numbers in the feed).
    public let sequence: UInt64

    public var isFilled: Bool { remainingQuantity == 0 }
}

/// One execution between a resting (maker) order and an incoming (taker) order.
public struct Fill: Sendable, Hashable {
    public let makerOrderID: OrderID
    public let takerOrderID: OrderID
    public let price: Ticks
    public let quantity: Int
    /// The side of the *aggressor* (taker). A `.bid` aggressor lifted the ask.
    public let aggressorSide: Side
    public let makerOwner: Participant
    public let takerOwner: Participant
    /// Matching-engine sequence at which the fill occurred.
    public let sequence: UInt64
}

/// Result of submitting an order.
public struct SubmitResult: Sendable {
    public let orderID: OrderID
    public let fills: [Fill]
    /// Quantity that remained after matching. For limit orders this now rests
    /// in the book; for market orders it was cancelled (no liquidity).
    public let restingQuantity: Int
    public var filledQuantity: Int { fills.reduce(0) { $0 + $1.quantity } }
}

/// Aggregate view of a price level for display and signal computation.
public struct PriceLevelSnapshot: Sendable, Hashable, Identifiable {
    public var id: Ticks { price }
    public let price: Ticks
    public let quantity: Int
    public let orderCount: Int
    /// Quantity at this level owned by the market maker (for highlighting).
    public let marketMakerQuantity: Int
}

/// Top-of-book summary.
public struct BestQuotes: Sendable, Hashable {
    public let bidPrice: Ticks?
    public let bidQuantity: Int
    public let askPrice: Ticks?
    public let askQuantity: Int

    public var midTicks: Double? {
        guard let b = bidPrice, let a = askPrice else { return nil }
        return Double(a + b) / 2
    }
    public var spreadTicks: Ticks? {
        guard let b = bidPrice, let a = askPrice else { return nil }
        return a - b
    }
}

/// Static description of a tradable instrument.
public struct Instrument: Sendable, Hashable, Codable {
    public let symbol: String
    public let name: String
    /// Dollar value of one tick (e.g. 0.01 for US equities above $1).
    public let tickSize: Double
    /// Shares per lot. Quantities in the book are in lots.
    public let lotSize: Int

    public init(symbol: String, name: String, tickSize: Double, lotSize: Int = 100) {
        precondition(tickSize > 0 && lotSize > 0)
        self.symbol = symbol
        self.name = name
        self.tickSize = tickSize
        self.lotSize = lotSize
    }

    public func price(fromTicks t: Ticks) -> Double { Double(t) * tickSize }
    public func price(fromTicks t: Double) -> Double { t * tickSize }
    public func ticks(fromPrice p: Double) -> Ticks { Ticks((p / tickSize).rounded()) }
}
