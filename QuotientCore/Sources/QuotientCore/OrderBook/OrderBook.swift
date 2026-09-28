//
//  OrderBook.swift
//  QuotientCore
//
//  A price-time priority limit order book with an integrated matching engine.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  DESIGN NOTES (the "design an order book" interview answer, in code)
//  ─────────────────────────────────────────────────────────────────────────────
//
//  Requirements
//    1. Best bid / best ask lookup            — hot path, every quote update
//    2. Match an incoming order               — walk levels from the best inward
//    3. Cancel by order id                     — the single most frequent message
//                                               on real venues (cancel:trade ≈ 20:1+)
//    4. Insert a resting limit at any price    — common
//    5. Depth snapshot for N levels            — display + imbalance signals
//
//  Data structure chosen
//    * Per side: a `[Ticks: PriceLevel]` dictionary for O(1) level lookup by
//      price, PLUS a sorted array of the *occupied* prices (`sortedPrices`).
//      Bids are kept descending and asks ascending so the best price is always
//      element 0 and matching walks from index 0.
//    * Each `PriceLevel` holds a FIFO array of `Order`s (time priority) and
//      cached aggregates (total quantity, live order count).
//    * A book-wide `[OrderID: Ticks]` index maps an order id to the level it
//      rests on, giving cancels a direct path to the right level.
//
//  Complexity (L = occupied levels per side, n = orders in a level)
//    best quote            O(1)
//    insert at new price   O(L)     (binary search + array insert; L is small,
//                                     typically tens, so this beats a balanced
//                                     tree's pointer-chasing in practice)
//    insert at existing    O(1) amortised (append to FIFO)
//    match one fill        O(1) amortised (pop from head via cursor)
//    cancel                O(1) amortised via tombstoning (see below)
//    depth(N)              O(N)
//
//  Cancels: lazy deletion
//    Removing from the middle of a FIFO array is O(n). Instead, cancel marks
//    the order as dead in a `[OrderID: Bool]`-style tombstone set, decrements
//    the level's cached quantity immediately (so signals stay correct), and the
//    matcher skips dead orders when it reaches them. Dead orders are compacted
//    away when a level's head cursor passes them or the level empties. This is
//    the same trade-off real engines make with intrusive linked lists: the goal
//    is O(1) on the hot path with no allocation.
//
//  Alternatives considered
//    * Balanced BST / red-black tree of levels (std::map): O(log L) everywhere,
//      but pointer chasing is cache-hostile. Real engines avoid it.
//    * Dense array indexed by tick ("price ladder"): O(1) everything, but
//      needs a bounded price band and re-centering; the right choice for a
//      latency-critical C++ engine (see README roadmap), overkill here.
//    * Heap: O(1) best, but no O(1) lookup of arbitrary levels for cancels.
//
//  Ordering guarantees
//    Price priority is strict (better price fills first). Within a level,
//    priority is by `sequence` (arrival order). An order that is modified
//    must be cancelled and re-entered — it loses its place. Market orders
//    never rest: whatever cannot be filled is dropped (IOC semantics).
//
//  Failure modes handled
//    * Crossed/locked market: an incoming limit that crosses is matched first,
//      so the resting book is never crossed.
//    * Cancel of unknown / already-filled id: returns false, no state change.
//    * Empty opposite side on a market order: partial fill, rest cancelled.
//    * Self-trade: NOT prevented at the engine level (the simulator never
//      lets the same participant cross itself; a real venue would offer
//      self-trade-prevention flags — see roadmap).
//
//  Concurrency
//    Single-threaded by design. One book == one symbol == one thread is how
//    production engines scale (sharding by symbol), and it keeps the event
//    sequence deterministic, which the paired Monte Carlo relies on.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation

public final class OrderBook {

    // MARK: - Price level

    /// FIFO queue of orders at one price plus cached aggregates.
    struct PriceLevel {
        let price: Ticks
        /// Orders in arrival order. `head` is the index of the first *live*
        /// order; everything before it has been fully filled and compacted.
        var orders: [Order] = []
        var head: Int = 0
        /// Sum of remaining quantity over *live* orders (tombstoned excluded).
        var totalQuantity: Int = 0
        var liveOrderCount: Int = 0
        var marketMakerQuantity: Int = 0

        var isEmpty: Bool { liveOrderCount == 0 }

        /// Compact away consumed prefix once it dominates, to bound memory.
        mutating func compactIfNeeded() {
            if head > 32 && head * 2 > orders.count {
                orders.removeFirst(head)
                head = 0
            }
        }
    }

    /// One side of the book.
    struct BookSide {
        let side: Side
        var levels: [Ticks: PriceLevel] = [:]
        /// Occupied prices sorted best-first (desc for bids, asc for asks).
        var sortedPrices: [Ticks] = []

        var bestPrice: Ticks? { sortedPrices.first }

        /// Comparator: does `a` have priority over `b` on this side?
        @inline(__always)
        func isBetter(_ a: Ticks, _ b: Ticks) -> Bool {
            side == .bid ? a > b : a < b
        }

        /// Binary search for the insertion index of `price` in `sortedPrices`.
        func insertionIndex(for price: Ticks) -> Int {
            var lo = 0, hi = sortedPrices.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if isBetter(sortedPrices[mid], price) { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        mutating func removeLevel(_ price: Ticks) {
            levels.removeValue(forKey: price)
            let idx = insertionIndex(for: price)
            if idx < sortedPrices.count && sortedPrices[idx] == price {
                sortedPrices.remove(at: idx)
            }
        }
    }

    // MARK: - State

    private(set) var bids = BookSide(side: .bid)
    private(set) var asks = BookSide(side: .ask)

    /// order id -> price level it rests at. Presence == order is live.
    private var orderIndex: [OrderID: (side: Side, price: Ticks, owner: Participant)] = [:]
    /// Tombstones for cancelled-but-not-yet-compacted orders.
    private var cancelled: Set<OrderID> = []

    private var nextOrderID: OrderID = 1
    private var sequence: UInt64 = 0

    /// Total traded volume since creation (lots).
    public private(set) var tradedVolume: Int = 0
    /// Last trade price, if any.
    public private(set) var lastTradePrice: Ticks?

    public init() {}

    // MARK: - Queries

    public var bestBid: Ticks? { bids.bestPrice }
    public var bestAsk: Ticks? { asks.bestPrice }

    public var best: BestQuotes {
        BestQuotes(
            bidPrice: bids.bestPrice,
            bidQuantity: bids.bestPrice.map { bids.levels[$0]!.totalQuantity } ?? 0,
            askPrice: asks.bestPrice,
            askQuantity: asks.bestPrice.map { asks.levels[$0]!.totalQuantity } ?? 0
        )
    }

    /// Mid in ticks (fractional when the spread is odd).
    public var midTicks: Double? { best.midTicks }

    public var spreadTicks: Ticks? { best.spreadTicks }

    /// Number of live orders in the book.
    public var liveOrderCount: Int { orderIndex.count }

    /// Current logical time.
    public var currentSequence: UInt64 { sequence }

    public func order(id: OrderID) -> Order? {
        guard let loc = orderIndex[id] else { return nil }
        let side = loc.side == .bid ? bids : asks
        guard let level = side.levels[loc.price] else { return nil }
        // Linear scan within a level is only used for diagnostics/tests.
        return level.orders[level.head...].first { $0.id == id }
    }

    /// Top `count` levels for a side, best first.
    public func depth(_ side: Side, levels count: Int) -> [PriceLevelSnapshot] {
        let s = side == .bid ? bids : asks
        return s.sortedPrices.prefix(count).map { p in
            let lvl = s.levels[p]!
            return PriceLevelSnapshot(
                price: p, quantity: lvl.totalQuantity,
                orderCount: lvl.liveOrderCount,
                marketMakerQuantity: lvl.marketMakerQuantity
            )
        }
    }

    /// Best price on `side` ignoring orders owned by `participant`.
    ///
    /// WHY: a market maker that estimates volatility from the full-book mid
    /// sees its own quote updates as price moves (its skew shifts the mid by
    /// half a tick every time it re-quotes at the touch). That inflated σ by
    /// ~40% in development and made Avellaneda–Stoikov quote too wide. A real
    /// maker knows its own orders, so "the market without me" is observable.
    /// O(L) in occupied levels, but stops at the first non-own level.
    public func bestPrice(_ side: Side, excluding participant: Participant) -> Ticks? {
        let s = side == .bid ? bids : asks
        for p in s.sortedPrices {
            let lvl = s.levels[p]!
            let own = participant == .marketMaker ? lvl.marketMakerQuantity : 0
            if lvl.totalQuantity - own > 0 { return p }
        }
        return nil
    }

    /// Mid in ticks of the book excluding `participant`'s orders.
    public func midTicks(excluding participant: Participant) -> Double? {
        guard let b = bestPrice(.bid, excluding: participant), let a = bestPrice(.ask, excluding: participant) else { return nil }
        return Double(a + b) / 2
    }

    /// Total quantity within `levels` of the top on a side.
    public func quantity(_ side: Side, topLevels count: Int) -> Int {
        depth(side, levels: count).reduce(0) { $0 + $1.quantity }
    }

    // MARK: - Submit

    /// Submit a limit order. Crossing quantity is matched immediately at the
    /// resting orders' prices (price improvement goes to the taker, as on real
    /// venues); the remainder rests.
    @discardableResult
    public func submitLimit(side: Side, price: Ticks, quantity: Int, owner: Participant) -> SubmitResult {
        precondition(quantity > 0, "quantity must be positive")
        let id = allocateID()
        var remaining = quantity
        let fills = match(side: side, limitPrice: price, quantity: &remaining, takerID: id, takerOwner: owner)
        if remaining > 0 {
            rest(Order(id: id, side: side, price: price, originalQuantity: quantity,
                       remainingQuantity: remaining, owner: owner, sequence: sequence))
        }
        return SubmitResult(orderID: id, fills: fills, restingQuantity: remaining)
    }

    /// Submit a market order: fills against the opposite side until exhausted
    /// or the book runs out. Unfilled remainder is cancelled (IOC).
    @discardableResult
    public func submitMarket(side: Side, quantity: Int, owner: Participant) -> SubmitResult {
        precondition(quantity > 0, "quantity must be positive")
        let id = allocateID()
        var remaining = quantity
        let fills = match(side: side, limitPrice: nil, quantity: &remaining, takerID: id, takerOwner: owner)
        return SubmitResult(orderID: id, fills: fills, restingQuantity: 0)
    }

    /// Cancel a resting order. Returns false if the id is unknown, filled, or
    /// already cancelled. O(1) amortised — see file header.
    @discardableResult
    public func cancel(_ id: OrderID) -> Bool {
        guard let loc = orderIndex.removeValue(forKey: id) else { return false }
        cancelled.insert(id)
        sequence += 1

        // Adjust cached aggregates now so signals reflect the cancel instantly.
        var side = loc.side == .bid ? bids : asks
        guard var level = side.levels[loc.price] else { return false }
        if let idx = level.orders[level.head...].firstIndex(where: { $0.id == id }) {
            let qty = level.orders[idx].remainingQuantity
            level.totalQuantity -= qty
            level.liveOrderCount -= 1
            if loc.owner == .marketMaker { level.marketMakerQuantity -= qty }
            // If it is at the head we can pop it eagerly, which keeps the
            // common "cancel my own top-of-queue quote" case allocation-free.
            if idx == level.head {
                level.head += 1
                skipDead(in: &level)
            }
        }
        if level.isEmpty {
            side.removeLevel(loc.price)
        } else {
            level.compactIfNeeded()
            side.levels[loc.price] = level
        }
        if loc.side == .bid { bids = side } else { asks = side }
        return true
    }

    /// Cancel every live order belonging to `owner`. Used by strategies to
    /// pull quotes before re-quoting. O(k) in the number of that owner's orders.
    public func cancelAll(owner: Participant) -> Int {
        let ids = orderIndex.filter { $0.value.owner == owner }.map(\.key)
        var n = 0
        for id in ids where cancel(id) { n += 1 }
        return n
    }

    // MARK: - Internals

    private func allocateID() -> OrderID {
        defer { nextOrderID += 1 }
        sequence += 1
        return nextOrderID
    }

    /// Core matching loop. Walks the opposite side best-first while the taker
    /// has quantity and the level price is acceptable.
    private func match(side takerSide: Side, limitPrice: Ticks?, quantity remaining: inout Int,
                       takerID: OrderID, takerOwner: Participant) -> [Fill] {
        var fills: [Fill] = []
        var opposite = takerSide == .bid ? asks : bids

        while remaining > 0, let bestPrice = opposite.bestPrice {
            // Price check: a buy limit at P matches asks <= P; a sell at P matches bids >= P.
            if let lim = limitPrice {
                let acceptable = takerSide == .bid ? bestPrice <= lim : bestPrice >= lim
                if !acceptable { break }
            }
            var level = opposite.levels[bestPrice]!
            skipDead(in: &level)

            while remaining > 0, level.head < level.orders.count {
                var maker = level.orders[level.head]
                let qty = min(remaining, maker.remainingQuantity)
                maker.remainingQuantity -= qty
                remaining -= qty
                level.totalQuantity -= qty
                if maker.owner == .marketMaker { level.marketMakerQuantity -= qty }
                sequence += 1
                fills.append(Fill(
                    makerOrderID: maker.id, takerOrderID: takerID, price: bestPrice,
                    quantity: qty, aggressorSide: takerSide,
                    makerOwner: maker.owner, takerOwner: takerOwner, sequence: sequence
                ))
                tradedVolume += qty
                lastTradePrice = bestPrice

                if maker.isFilled {
                    level.liveOrderCount -= 1
                    orderIndex.removeValue(forKey: maker.id)
                    level.head += 1
                    skipDead(in: &level)
                } else {
                    level.orders[level.head] = maker
                }
            }

            if level.isEmpty {
                opposite.removeLevel(bestPrice)
            } else {
                level.compactIfNeeded()
                opposite.levels[bestPrice] = level
                break // taker exhausted at this level
            }
        }

        if takerSide == .bid { asks = opposite } else { bids = opposite }
        return fills
    }

    /// Advance `head` past tombstoned orders, reclaiming their tombstones.
    private func skipDead(in level: inout PriceLevel) {
        while level.head < level.orders.count, cancelled.contains(level.orders[level.head].id) {
            cancelled.remove(level.orders[level.head].id)
            level.head += 1
        }
    }

    private func rest(_ order: Order) {
        var side = order.side == .bid ? bids : asks
        if var level = side.levels[order.price] {
            level.orders.append(order)
            level.totalQuantity += order.remainingQuantity
            level.liveOrderCount += 1
            if order.owner == .marketMaker { level.marketMakerQuantity += order.remainingQuantity }
            side.levels[order.price] = level
        } else {
            var level = PriceLevel(price: order.price)
            level.orders = [order]
            level.totalQuantity = order.remainingQuantity
            level.liveOrderCount = 1
            level.marketMakerQuantity = order.owner == .marketMaker ? order.remainingQuantity : 0
            side.levels[order.price] = level
            side.sortedPrices.insert(order.price, at: side.insertionIndex(for: order.price))
        }
        orderIndex[order.id] = (order.side, order.price, order.owner)
        if order.side == .bid { bids = side } else { asks = side }
    }

    // MARK: - Invariants (debug / tests)

    /// Verifies internal consistency. Returns a description of the first
    /// violated invariant, or nil if the book is consistent.
    public func checkInvariants() -> String? {
        if let b = bestBid, let a = bestAsk, b >= a {
            return "crossed book: bid \(b) >= ask \(a)"
        }
        for s in [bids, asks] {
            for (i, p) in s.sortedPrices.enumerated() {
                guard let lvl = s.levels[p] else { return "sortedPrices has \(p) with no level" }
                if i > 0, !s.isBetter(s.sortedPrices[i - 1], p) { return "sortedPrices out of order on \(s.side)" }
                var live = 0, qty = 0, mm = 0
                for o in lvl.orders[lvl.head...] where !cancelled.contains(o.id) {
                    live += 1; qty += o.remainingQuantity
                    if o.owner == .marketMaker { mm += o.remainingQuantity }
                    if orderIndex[o.id] == nil { return "live order \(o.id) missing from index" }
                }
                if live != lvl.liveOrderCount { return "liveOrderCount mismatch at \(p): \(live) vs \(lvl.liveOrderCount)" }
                if qty != lvl.totalQuantity { return "totalQuantity mismatch at \(p): \(qty) vs \(lvl.totalQuantity)" }
                if mm != lvl.marketMakerQuantity { return "marketMakerQuantity mismatch at \(p)" }
                if live == 0 { return "empty level \(p) retained" }
            }
            if s.levels.count != s.sortedPrices.count { return "levels/sortedPrices count mismatch on \(s.side)" }
        }
        return nil
    }
}
