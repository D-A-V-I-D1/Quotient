//
//  FixedSpreadMarketMaker.swift
//  QuotientCore
//
//  LEVEL 1 — the naive baseline.
//
//  Quote a constant number of ticks either side of the mid, constant size,
//  never skew, never widen. This is what a first attempt at market making
//  looks like, and it fails in two instructive ways the simulator surfaces:
//
//    1. Inventory drift. With symmetric quotes and random order flow, the
//       position is a random walk in inventory space; its RMS grows like √t
//       and there is nothing pulling it back. Mark-to-market P&L variance
//       explodes with it (Avellaneda–Stoikov, 2008, §1 motivates exactly this).
//    2. Adverse selection. Informed traders only trade when the quote is on
//       the wrong side of the true value, so this maker's fills against them
//       are systematically followed by the mid moving against it. Markouts
//       are negative; the fixed spread never widens to compensate
//       (Glosten–Milgrom, 1985).
//
//  The optional `maxInventory` is a crude circuit breaker that stops quoting
//  the side that would increase the position past the limit. It is off by
//  default so the failure mode is visible; turning it on shows how much of
//  the naive maker's loss is inventory risk versus adverse selection.
//

import Foundation

public struct FixedSpreadMarketMaker: MarketMakingStrategy, Equatable {
    public var name: String { "Fixed Spread" }
    public var summary: String {
        "Quotes \(halfSpreadTicks) tick(s) either side of the mid with size \(sizeLots), no inventory skew and no volatility adjustment. The baseline whose failure modes motivate everything else."
    }

    /// Distance from mid to each quote, in ticks (total spread = 2 × this,
    /// after rounding to the grid).
    public var halfSpreadTicks: Double
    /// Lots per side.
    public var sizeLots: Int
    /// Optional hard position limit in lots. nil = unbounded (the instructive default).
    public var maxInventory: Int?

    public init(halfSpreadTicks: Double = 1.5, sizeLots: Int = 1, maxInventory: Int? = nil) {
        precondition(halfSpreadTicks > 0 && sizeLots > 0)
        self.halfSpreadTicks = halfSpreadTicks
        self.sizeLots = sizeLots
        self.maxInventory = maxInventory
    }

    public mutating func quotes(for state: MarketState) -> QuoteIntent {
        // Snap to nearest tick (same convention as every other strategy, so
        // realised spreads are comparable), then guard against a locked quote.
        var bid: Ticks? = Ticks((state.midTicks - halfSpreadTicks).rounded(.toNearestOrAwayFromZero))
        var ask: Ticks? = Ticks((state.midTicks + halfSpreadTicks).rounded(.toNearestOrAwayFromZero))
        if let b = bid, let a = ask, b >= a { ask = b + 1 }
        if let cap = maxInventory {
            if state.inventory >= cap { bid = nil }
            if state.inventory <= -cap { ask = nil }
        }
        return QuoteIntent(bidPrice: bid, askPrice: ask, bidSize: sizeLots, askSize: sizeLots)
    }
}
