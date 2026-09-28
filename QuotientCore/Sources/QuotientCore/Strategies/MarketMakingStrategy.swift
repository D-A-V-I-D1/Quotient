//
//  MarketMakingStrategy.swift
//  QuotientCore
//
//  The interface between "pricing logic" and "the market". A strategy never
//  touches the order book directly: it is handed a `MarketState` snapshot and
//  returns a `QuoteIntent`. The simulator (or, one day, a live execution
//  layer) is responsible for turning intents into orders.
//
//  WHY this boundary: it is the seam that makes the whole system swappable.
//  The same strategy value can be driven by the simulator, by a replay of
//  recorded data, or by a live feed, because it only ever sees `MarketState`.
//  It also makes strategies trivially unit-testable: construct a state, call
//  `quotes(for:)`, assert on the numbers.
//

import Foundation

/// Everything a strategy is allowed to know at quote time.
public struct MarketState: Sendable, Equatable {
    /// Current step index (0-based) and total steps in the session.
    public let step: Int
    public let totalSteps: Int
    /// Best bid/ask mid in ticks (may be fractional).
    public let midTicks: Double
    /// Microprice estimate in ticks (falls back to weighted mid, then mid).
    public let micropriceTicks: Double
    /// Depth imbalance in [-1, 1] at the top of book (0 if unavailable).
    public let imbalance: Double
    /// Rolling order-flow imbalance (lots), positive = net buying pressure.
    public let orderFlowImbalance: Double
    /// Current quoted spread in ticks.
    public let spreadTicks: Ticks
    /// Strategy's signed inventory in lots (+ long, − short).
    public let inventory: Int
    /// Estimated mid volatility per step, in ticks.
    public let sigmaTicksPerStep: Double
    /// Best bid / ask in ticks.
    public let bestBid: Ticks
    public let bestAsk: Ticks

    public var stepsRemaining: Int { max(0, totalSteps - step) }
    public var timeFraction: Double { totalSteps == 0 ? 1 : Double(step) / Double(totalSteps) }

    public init(step: Int, totalSteps: Int, midTicks: Double, micropriceTicks: Double,
                imbalance: Double, orderFlowImbalance: Double, spreadTicks: Ticks,
                inventory: Int, sigmaTicksPerStep: Double, bestBid: Ticks, bestAsk: Ticks) {
        self.step = step
        self.totalSteps = totalSteps
        self.midTicks = midTicks
        self.micropriceTicks = micropriceTicks
        self.imbalance = imbalance
        self.orderFlowImbalance = orderFlowImbalance
        self.spreadTicks = spreadTicks
        self.inventory = inventory
        self.sigmaTicksPerStep = sigmaTicksPerStep
        self.bestBid = bestBid
        self.bestAsk = bestAsk
    }
}

/// What a strategy wants resting in the book after this decision.
/// A nil price means "do not quote that side".
public struct QuoteIntent: Sendable, Equatable {
    public var bidPrice: Ticks?
    public var askPrice: Ticks?
    public var bidSize: Int
    public var askSize: Int

    public init(bidPrice: Ticks?, askPrice: Ticks?, bidSize: Int, askSize: Int) {
        self.bidPrice = bidPrice
        self.askPrice = askPrice
        self.bidSize = bidSize
        self.askSize = askSize
    }

    public static let none = QuoteIntent(bidPrice: nil, askPrice: nil, bidSize: 0, askSize: 0)

    /// Sanity: a two-sided quote must not be crossed or locked.
    public var isValid: Bool {
        if let b = bidPrice, let a = askPrice { return b < a }
        return true
    }
}

public protocol MarketMakingStrategy: Sendable {
    /// Short identifier for tables and charts.
    var name: String { get }
    /// One-paragraph description for the UI / README.
    var summary: String { get }
    /// Produce the desired quotes given the current state. `mutating` so a
    /// strategy may keep internal state (e.g. its own signal estimators).
    mutating func quotes(for state: MarketState) -> QuoteIntent
    /// Clear internal state between trials.
    mutating func reset()
}

public extension MarketMakingStrategy {
    mutating func reset() {}
}
