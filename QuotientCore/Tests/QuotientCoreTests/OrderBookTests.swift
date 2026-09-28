import Testing
@testable import QuotientCore

@Suite("OrderBook") struct OrderBookTests {

    @Test("resting limit orders populate the book without matching")
    func restingOrders() {
        let book = OrderBook()
        book.submitLimit(side: .bid, price: 100, quantity: 5, owner: .noiseTrader)
        book.submitLimit(side: .ask, price: 102, quantity: 3, owner: .noiseTrader)
        #expect(book.bestBid == 100)
        #expect(book.bestAsk == 102)
        #expect(book.midTicks == 101)
        #expect(book.spreadTicks == 2)
        #expect(book.best.bidQuantity == 5)
        #expect(book.best.askQuantity == 3)
        #expect(book.checkInvariants() == nil)
    }

    @Test("price priority: better prices fill first")
    func pricePriority() {
        let book = OrderBook()
        book.submitLimit(side: .ask, price: 103, quantity: 1, owner: .noiseTrader)
        book.submitLimit(side: .ask, price: 101, quantity: 1, owner: .noiseTrader)
        book.submitLimit(side: .ask, price: 102, quantity: 1, owner: .noiseTrader)
        let r = book.submitMarket(side: .bid, quantity: 2, owner: .noiseTrader)
        #expect(r.fills.map(\.price) == [101, 102])
        #expect(book.bestAsk == 103)
        #expect(book.checkInvariants() == nil)
    }

    @Test("time priority: first in at a price fills first")
    func timePriority() {
        let book = OrderBook()
        let first = book.submitLimit(side: .bid, price: 100, quantity: 1, owner: .noiseTrader).orderID
        let second = book.submitLimit(side: .bid, price: 100, quantity: 1, owner: .marketMaker).orderID
        let r = book.submitMarket(side: .ask, quantity: 1, owner: .noiseTrader)
        #expect(r.fills.count == 1)
        #expect(r.fills[0].makerOrderID == first)
        #expect(book.order(id: first) == nil)
        #expect(book.order(id: second) != nil)
    }

    @Test("partial fills leave the remainder resting")
    func partialFill() {
        let book = OrderBook()
        let id = book.submitLimit(side: .ask, price: 100, quantity: 10, owner: .noiseTrader).orderID
        let r = book.submitMarket(side: .bid, quantity: 4, owner: .noiseTrader)
        #expect(r.filledQuantity == 4)
        #expect(book.order(id: id)?.remainingQuantity == 6)
        #expect(book.best.askQuantity == 6)
        #expect(book.checkInvariants() == nil)
    }

    @Test("market order larger than the book fills what exists and drops the rest (IOC)")
    func marketOrderExhaustsBook() {
        let book = OrderBook()
        book.submitLimit(side: .ask, price: 100, quantity: 2, owner: .noiseTrader)
        let r = book.submitMarket(side: .bid, quantity: 5, owner: .noiseTrader)
        #expect(r.filledQuantity == 2)
        #expect(r.restingQuantity == 0)
        #expect(book.bestAsk == nil)
        #expect(book.liveOrderCount == 0)
    }

    @Test("crossing limit order matches at resting prices and rests the remainder")
    func crossingLimit() {
        let book = OrderBook()
        book.submitLimit(side: .ask, price: 100, quantity: 1, owner: .noiseTrader)
        book.submitLimit(side: .ask, price: 101, quantity: 1, owner: .noiseTrader)
        // Buy 3 at 101: takes 100 (price improvement) and 101, rests 1 at 101 as a bid.
        let r = book.submitLimit(side: .bid, price: 101, quantity: 3, owner: .noiseTrader)
        #expect(r.fills.map(\.price) == [100, 101])
        #expect(r.restingQuantity == 1)
        #expect(book.bestBid == 101)
        #expect(book.bestAsk == nil)
        #expect(book.checkInvariants() == nil)
    }

    @Test("limit order does not match through its limit price")
    func limitRespected() {
        let book = OrderBook()
        book.submitLimit(side: .ask, price: 105, quantity: 1, owner: .noiseTrader)
        let r = book.submitLimit(side: .bid, price: 104, quantity: 1, owner: .noiseTrader)
        #expect(r.fills.isEmpty)
        #expect(book.bestBid == 104)
        #expect(book.bestAsk == 105)
    }

    @Test("cancel removes the order and updates aggregates")
    func cancel() {
        let book = OrderBook()
        let a = book.submitLimit(side: .bid, price: 100, quantity: 2, owner: .noiseTrader).orderID
        let b = book.submitLimit(side: .bid, price: 100, quantity: 3, owner: .noiseTrader).orderID
        #expect(book.cancel(a))
        #expect(book.best.bidQuantity == 3)
        #expect(book.order(id: a) == nil)
        #expect(book.cancel(a) == false, "double cancel is a no-op")
        #expect(book.cancel(99_999) == false, "unknown id is a no-op")
        #expect(book.checkInvariants() == nil)
        #expect(book.cancel(b))
        #expect(book.bestBid == nil, "empty level is removed")
        #expect(book.checkInvariants() == nil)
    }

    @Test("cancelled order in the middle of a queue is skipped by the matcher (lazy deletion)")
    func lazyDeletionSkipsTombstones() {
        let book = OrderBook()
        let a = book.submitLimit(side: .ask, price: 100, quantity: 1, owner: .noiseTrader).orderID
        let b = book.submitLimit(side: .ask, price: 100, quantity: 1, owner: .noiseTrader).orderID
        let c = book.submitLimit(side: .ask, price: 100, quantity: 1, owner: .noiseTrader).orderID
        #expect(book.cancel(b))
        let r = book.submitMarket(side: .bid, quantity: 2, owner: .noiseTrader)
        #expect(r.fills.map(\.makerOrderID) == [a, c])
        #expect(book.bestAsk == nil)
        #expect(book.checkInvariants() == nil)
    }

    @Test("cancelAll by owner only removes that owner's orders")
    func cancelAllOwner() {
        let book = OrderBook()
        book.submitLimit(side: .bid, price: 100, quantity: 1, owner: .marketMaker)
        book.submitLimit(side: .ask, price: 102, quantity: 1, owner: .marketMaker)
        book.submitLimit(side: .bid, price: 99, quantity: 1, owner: .noiseTrader)
        #expect(book.cancelAll(owner: .marketMaker) == 2)
        #expect(book.bestBid == 99)
        #expect(book.bestAsk == nil)
    }

    @Test("depth snapshot is best-first and tracks market-maker quantity")
    func depth() {
        let book = OrderBook()
        book.submitLimit(side: .bid, price: 98, quantity: 4, owner: .noiseTrader)
        book.submitLimit(side: .bid, price: 100, quantity: 1, owner: .marketMaker)
        book.submitLimit(side: .bid, price: 99, quantity: 2, owner: .noiseTrader)
        let d = book.depth(.bid, levels: 3)
        #expect(d.map(\.price) == [100, 99, 98])
        #expect(d[0].marketMakerQuantity == 1)
        #expect(d[1].marketMakerQuantity == 0)
        #expect(book.quantity(.bid, topLevels: 2) == 3)
    }

    @Test("bestPrice(excluding:) skips levels where only the excluded participant rests")
    func bestExcluding() {
        let book = OrderBook()
        book.submitLimit(side: .ask, price: 101, quantity: 1, owner: .marketMaker)
        book.submitLimit(side: .ask, price: 103, quantity: 1, owner: .noiseTrader)
        #expect(book.bestAsk == 101)
        #expect(book.bestPrice(.ask, excluding: .marketMaker) == 103)
        #expect(book.bestPrice(.bid, excluding: .marketMaker) == nil)
        #expect(book.midTicks(excluding: .marketMaker) == nil)
    }

    @Test("fills carry owner attribution and aggressor side")
    func attribution() {
        let book = OrderBook()
        book.submitLimit(side: .bid, price: 100, quantity: 1, owner: .marketMaker)
        let r = book.submitMarket(side: .ask, quantity: 1, owner: .informedTrader)
        #expect(r.fills[0].makerOwner == .marketMaker)
        #expect(r.fills[0].takerOwner == .informedTrader)
        #expect(r.fills[0].aggressorSide == .ask)
    }

    @Test("sequence numbers strictly increase")
    func sequenceMonotone() {
        let book = OrderBook()
        let s0 = book.currentSequence
        book.submitLimit(side: .bid, price: 100, quantity: 1, owner: .noiseTrader)
        let s1 = book.currentSequence
        book.submitMarket(side: .ask, quantity: 1, owner: .noiseTrader)
        let s2 = book.currentSequence
        #expect(s0 < s1 && s1 < s2)
    }

    @Test("randomised operations never violate invariants or cross the book")
    func fuzz() {
        var rng = SeededRandom(seed: 42)
        let book = OrderBook()
        var live: [OrderID] = []
        for _ in 0..<20_000 {
            let roll = rng.nextDouble()
            let side: Side = rng.nextBool(probability: 0.5) ? .bid : .ask
            let qty = rng.nextGeometric(successProbability: 0.4)
            if roll < 0.5 {
                let price = Ticks(1000 + Int(rng.nextGaussian() * 5))
                let r = book.submitLimit(side: side, price: price, quantity: qty, owner: .noiseTrader)
                if r.restingQuantity > 0 { live.append(r.orderID) }
            } else if roll < 0.75 {
                book.submitMarket(side: side, quantity: qty, owner: .noiseTrader)
            } else if !live.isEmpty {
                let idx = Int(rng.nextDouble() * Double(live.count))
                book.cancel(live.remove(at: idx))
            }
            if let b = book.bestBid, let a = book.bestAsk { #expect(b < a) }
        }
        #expect(book.checkInvariants() == nil)
    }

    @Test("throughput sanity: 200k mixed operations complete quickly")
    func throughput() {
        var rng = SeededRandom(seed: 7)
        let book = OrderBook()
        var live: [OrderID] = []
        live.reserveCapacity(1000)
        let start = ContinuousClock.now
        for _ in 0..<200_000 {
            let side: Side = rng.nextBool(probability: 0.5) ? .bid : .ask
            if rng.nextBool(probability: 0.6) {
                let r = book.submitLimit(side: side, price: Ticks(1000 + Int(rng.nextGaussian() * 6)), quantity: 1, owner: .noiseTrader)
                if r.restingQuantity > 0 { live.append(r.orderID) }
            } else if rng.nextBool(probability: 0.5), !live.isEmpty {
                book.cancel(live.removeLast())
            } else {
                book.submitMarket(side: side, quantity: 2, owner: .noiseTrader)
            }
        }
        let elapsed = ContinuousClock.now - start
        // Generous bound: a debug build on CI. Release builds are ~10× faster.
        #expect(elapsed < .seconds(5), "200k ops took \(elapsed)")
        #expect(book.checkInvariants() == nil)
    }
}
