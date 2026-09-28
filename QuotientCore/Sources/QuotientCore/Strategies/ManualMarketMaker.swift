//
//  ManualMarketMaker.swift
//  QuotientCore
//
//  A "strategy" whose parameters are set by a human. Lets the app user play
//  the market-making game against the same simulated flow the algorithms
//  face: choose a half-spread and a skew, watch the inventory and markouts.
//
//  Conforming to `MarketMakingStrategy` means the manual player is evaluated
//  by exactly the same machinery as the algorithms — nothing is special-cased.
//

import Foundation

public struct ManualMarketMaker: MarketMakingStrategy, Equatable {
    public var name: String { "Manual" }
    public var summary: String { "You set the half-spread and skew; the same simulated order flow hits your quotes." }

    public var halfSpreadTicks: Double
    /// Positive skew lowers both quotes (you want to sell); negative raises them.
    public var skewTicks: Double
    public var sizeLots: Int
    public var quoteBid: Bool
    public var quoteAsk: Bool

    public init(halfSpreadTicks: Double = 1.5, skewTicks: Double = 0, sizeLots: Int = 1, quoteBid: Bool = true, quoteAsk: Bool = true) {
        self.halfSpreadTicks = halfSpreadTicks
        self.skewTicks = skewTicks
        self.sizeLots = sizeLots
        self.quoteBid = quoteBid
        self.quoteAsk = quoteAsk
    }

    public mutating func quotes(for state: MarketState) -> QuoteIntent {
        let centre = state.midTicks - skewTicks
        var bid: Ticks? = quoteBid ? Ticks((centre - halfSpreadTicks).rounded(.toNearestOrAwayFromZero)) : nil
        var ask: Ticks? = quoteAsk ? Ticks((centre + halfSpreadTicks).rounded(.toNearestOrAwayFromZero)) : nil
        if let b = bid, let a = ask, b >= a { ask = b + 1 }
        if sizeLots <= 0 { bid = nil; ask = nil }
        return QuoteIntent(bidPrice: bid, askPrice: ask, bidSize: max(1, sizeLots), askSize: max(1, sizeLots))
    }
}
