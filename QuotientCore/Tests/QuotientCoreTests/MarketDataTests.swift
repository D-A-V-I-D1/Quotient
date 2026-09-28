import Testing
import Foundation
@testable import QuotientCore

@Suite("MarketData") struct MarketDataTests {

    @Test("bundled snapshot decodes, validates, and is dated")
    func bundled() async throws {
        let src = BundledSnapshotDataSource()
        let snap = try await src.loadSnapshot()
        #expect(snap.schemaVersion == MarketSnapshot.currentSchemaVersion)
        #expect(snap.asOfDate == "2026-09-25")
        #expect(snap.retrievedDate == "2026-09-28")
        #expect(snap.instruments.count >= 5)
        #expect(snap.instrument("SPY")?.lastPrice == 771.35)
        #expect(snap.volatility.vixClose == 14.87)
        #expect(snap.rates.fedFundsUpperPercent == 4.00)
        #expect(!snap.headlines.isEmpty)
        for i in snap.instruments {
            #expect(i.sourceURL.hasPrefix("https://"), "\(i.symbol) needs a source URL")
        }
        for p in snap.pairs {
            #expect(snap.instrument(p.symbolA) != nil && snap.instrument(p.symbolB) != nil)
        }
        let age = snap.ageInDays(now: MarketSnapshot.isoDate("2026-10-05")!)
        #expect(age == 10)
    }

    @Test("decoder rejects wrong schema and bad values")
    func validation() throws {
        let good = try JSONEncoder().encode(Fixtures.snapshot)
        _ = try MarketSnapshotDecoder.decode(good)

        let badSchema = try JSONEncoder().encode(Fixtures.snapshot(withSchema: 99))
        #expect(throws: MarketDataError.unsupportedSchema(found: 99, expected: 1)) {
            try MarketSnapshotDecoder.decode(badSchema)
        }
        let badPrice = try JSONEncoder().encode(Fixtures.snapshot(price: -1))
        #expect(throws: MarketDataError.self) { try MarketSnapshotDecoder.decode(badPrice) }
        let badDate = try JSONEncoder().encode(Fixtures.snapshot(asOf: "yesterday"))
        #expect(throws: MarketDataError.self) { try MarketSnapshotDecoder.decode(badDate) }
    }

    @Test("in-memory source round-trips and conforms to the same protocol")
    func inMemory() async throws {
        let src: any MarketDataSource = InMemoryMarketDataSource(snapshot: Fixtures.snapshot, sourceName: "Test")
        let s = try await src.loadSnapshot()
        #expect(s == Fixtures.snapshot)
        #expect(src.sourceName == "Test")
    }

    @Test("calibration: VIX-implied per-step σ is in a sane range and scales with price")
    func calibration() throws {
        // $100 stock, 16% annual vol, 1¢ tick, 0.1 s steps, no dampening:
        // steps/yr = 252·23400/0.1 = 5.9e7 → σ_$ = 100·0.16/7679 ≈ 0.00208 → 0.21 ticks.
        let raw = Calibration.sigmaTicksPerStep(price: 100, annualisedVol: 0.16, tickSize: 0.01, secondsPerStep: 0.1, dampening: 1)
        #expect(abs(raw - 0.208) < 0.005)
        let damped = Calibration.sigmaTicksPerStep(price: 100, annualisedVol: 0.16, tickSize: 0.01, secondsPerStep: 0.1)
        #expect(abs(damped - 0.208 * Calibration.highFrequencyDampening) < 0.005)
        let p = try Calibration.parameters(from: Fixtures.snapshot, symbol: "TEST")
        #expect(p.instrument.symbol == "TEST")
        #expect(p.initialMidTicks == 10_000)
        #expect(p.fundamentalVolatilityTicks > 0.05 && p.fundamentalVolatilityTicks < 5)
        #expect(p.crowdHalfSpreadTicks == 1)
        #expect(throws: MarketDataError.self) { try Calibration.parameters(from: Fixtures.snapshot, symbol: "NOPE") }
    }

    @Test("real snapshot calibrates every instrument to runnable parameters")
    func calibrateAll() async throws {
        let snap = try await BundledSnapshotDataSource().loadSnapshot()
        for i in snap.instruments {
            let p = try Calibration.parameters(from: snap, symbol: i.symbol)
            #expect(p.fundamentalVolatilityTicks > 0 && p.fundamentalVolatilityTicks < 10, "\(i.symbol) σ=\(p.fundamentalVolatilityTicks)")
            #expect(p.initialMidTicks > 0)
            var short = p; short.steps = 100
            let r = MarketSimulator(parameters: short, strategy: AvellanedaStoikovMarketMaker(gamma: 0.01), seed: 1).run()
            let allFinite = r.midTicks.allSatisfy { $0.isFinite }
            #expect(allFinite)
        }
    }
}

enum Fixtures {
    static let snapshot = snapshot()

    static func snapshot(withSchema schema: Int = 1, price: Double = 100, asOf: String = "2026-09-25") -> MarketSnapshot {
        MarketSnapshot(
            schemaVersion: schema, asOfDate: asOf, retrievedDate: "2026-09-28", notes: "fixture",
            instruments: [ReferenceInstrument(symbol: "TEST", name: "Test Co", assetClass: "stock", lastPrice: price,
                                              priceAsOfDate: asOf, tickSize: 0.01, typicalSpreadTicks: 1,
                                              averageDailyVolumeShares: 1_000_000, volatilityMultiplier: 1.0,
                                              sourceURL: "https://example.com", notes: nil)],
            volatility: VolatilityContext(vixClose: 16, vixAsOfDate: asOf, vixOneMonthLow: 14, vixOneMonthHigh: 18, sourceURL: "https://example.com"),
            rates: RatesContext(fedFundsLowerPercent: 3.75, fedFundsUpperPercent: 4.0, lastDecisionDate: "2026-09-16", lastDecision: "hike",
                                lastDecisionBasisPoints: 25, nextMeetingDate: "2026-10-28", tenYearYieldPercent: 5.18, twoYearYieldPercent: 4.81, sourceURLs: []),
            headlines: [], pairs: [],
            microstructure: MicrostructureContext(minimumTickUSD: 0.01, notes: "", sourceURL: "https://example.com")
        )
    }
}
