# ReferenceData — the hard-coded market snapshot

`market_snapshot.json` is the **only** place real-world numbers enter Quotient.
It was hand-researched on **2026-09-28** and describes the **2026-09-25** close.
It is static and will go stale; the app shows its age on the Market Context
screen.

## Format

One JSON document decoded into `MarketSnapshot` (see `../MarketDataSource.swift`).
Fields:

| Field | Meaning |
|---|---|
| `schemaVersion` | Must equal `MarketSnapshot.currentSchemaVersion` (currently 1). |
| `asOfDate` | Trading date the values describe, `yyyy-MM-dd`. |
| `retrievedDate` | Date the research was done. |
| `instruments[]` | Symbol, last price, tick size, typical spread (ticks), ADV, a volatility multiplier vs. the index, source URL, notes. |
| `volatility` | VIX close and one-month range, with source. |
| `rates` | Fed funds range, last decision, next meeting, 10Y and 2Y yields, sources. |
| `headlines[]` | A few dated one-line macro/market items with sources. |
| `pairs[]` | Correlated pairs for the stat-arb demo; both symbols must exist in `instruments`. |
| `microstructure` | Minimum tick and any rule notes. |

Every number carries a `sourceURL` and an as-of date. Prices are used to seed
the simulated mid; VIX × `volatilityMultiplier` sets per-step volatility via
`Calibration.sigmaTicksPerStep`; `typicalSpreadTicks` sets the background
crowd's spread. Everything else is flavour shown in the UI.

## How to refresh the numbers (takes ~15 minutes)

1. Open `market_snapshot.json`.
2. For each instrument, update `lastPrice` and `priceAsOfDate` from a source
   you actually looked at, and update `sourceURL` if it changed.
3. Update `volatility.vixClose` and the one-month range; `rates.*`;
   replace `headlines` with 3–5 current items.
4. Set `asOfDate` to the trading date the prices describe and `retrievedDate`
   to today.
5. Run `swift test --filter MarketDataTests` from `QuotientCore/`. The decoder
   validates the schema and the tests check the calibration math still lands
   in a sane range.

Do not change `schemaVersion` unless you also change the `MarketSnapshot`
struct; bump both together and the decoder will reject mismatched files.

## How to go live (a real data feed)

1. Create `Sources/QuotientCore/MarketData/LiveMarketDataSource.swift`:

   ```swift
   public struct LiveMarketDataSource: MarketDataSource {
       public var sourceName: String { "YourVendor" }
       public func loadSnapshot() async throws -> MarketSnapshot {
           // Fetch quotes / VIX / rates, map into MarketSnapshot, set
           // asOfDate to today. Throw MarketDataError.invalid on bad data.
       }
   }
   ```
2. Where the app constructs `BundledSnapshotDataSource()` (one line in
   `Quotient/App/AppModel.swift`), construct your source instead — or keep
   both and offer a picker.
3. Nothing in `Simulation/`, `Strategies/`, `Signals/` or `Evaluation/`
   changes. They consume `MarketSnapshot` through `Calibration` only.

For **live order flow** (as opposed to reference levels), the analogous seam is
`MarketMakingStrategy` + `MarketState`: a replay/feed driver produces
`MarketState` snapshots and routes `QuoteIntent`s to a venue, replacing
`MarketSimulator`. See the top-level README roadmap.
