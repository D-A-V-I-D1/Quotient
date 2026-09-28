# Plain-English layer

The Compare, Pairs and Terminal screens can describe their results in prose
for readers without a quant background. The prose is **generated from the same
result values the technical views display**, never from per-scenario canned
text, so it cannot drift from the numbers.

## Where it lives

- Generation logic: `QuotientCore/Sources/QuotientCore/Evaluation/PlainEnglish.swift`
- Tests: `QuotientCore/Tests/QuotientCoreTests/PlainEnglishTests.swift`
- UI: `Quotient/Shared/GlossaryView.swift` (info sheet), the `Plain English /
  Technical` picker in `CompareView`, the extended "What this shows" panel in
  `PairsView`, and the "In plain English" panel in `TerminalView`.

## Inputs

| Screen | Source of truth | Entry point |
|---|---|---|
| Compare | `MonteCarloReport` → `StrategyOutcome`, `PairedComparison` | `PlainEnglish.headline(_:)`, `PlainEnglish.summary(of:in:)` |
| Pairs | `PairsResult`, `PairsParameters`, optional Monte Carlo (mean, t, n) | `PlainEnglish.pairsSummary(_:parameters:monteCarlo:)` |
| Terminal | `PlainEnglish.LiveState` built by `TerminalViewModel` from the live `MarketSimulator` | `PlainEnglish.liveSummary(_:)` |
| Glossary | static | `PlainEnglish.glossary` |

## How a Compare summary is built

`summary(of:in:)` returns two to four sentences:

1. **Result** — mean P&L with a verb chosen by sign, variability phrased from
   the sd/|mean| ratio, win rate, and inventory (near-flat vs. typical/peak lots).
2. **Comparison** — against the first *other* strategy in the report that
   traded. Uses the `PairedComparison` mean difference and p-value (oriented so
   the difference is always "this minus reference"), then ratios of sd,
   drawdown and RMS inventory. The connector is "but" when profit and risk point
   in opposite directions, "and" otherwise.
3. **Adverse selection** — markout vs. informed counterparties at the 50-step
   horizon (or the first available), compared with the reference's, plus the
   markout vs. ordinary flow. Switches to an "ordinary flow only" form when the
   scenario has no informed traders.
4. **Win-rate caveat** — only emitted when win rate and consistency disagree
   (the steadier strategy has the lower win rate, or vice versa).

Zero-fill strategies short-circuit to a single sentence and are excluded as
comparison references.

## Wording thresholds

All thresholds are named `static let`s at the top of `PlainEnglish`:
`clearSignificance` (0.01), `likelySignificance` (0.05),
`farMoreConsistentRatio` (3×), `noticeableRatio` (1.5×), `aboutTheSameBand`,
`nearFlatInventoryLots` (1 lot), `almostAlwaysWinRate`, `almostNeverWinRate`.
Change the wording rule by changing the constant; the tests assert on the
phrases each branch produces.

## Extending it when metrics change

1. Add the metric to `PerformanceMetrics` / `StrategyOutcome` as usual.
2. Add a sentence builder in `PlainEnglish` (a `static func … -> String?`
   returning nil when the metric is absent) and append it in `summary(of:in:)`.
3. Add a shape to `PlainEnglishTests` that exercises the new branch, including
   the absent/degenerate case, and assert the text contains no `nan`/`inf`.
4. If the metric needs a definition, append a `GlossaryEntry`.

Keep string-building out of SwiftUI views; the views only call these functions.
