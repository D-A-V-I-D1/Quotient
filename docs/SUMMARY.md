# Quotient — Project Summary

A written summary of what Quotient is, what its results show, the bugs found
while building it, and how it maps to the questions quant trading and quant
developer interviews actually ask. Everything here is backed by code and tests
in this repository. The numbers come from `docs/RESULTS.md`, which is generated
by `ResultsReportTests` rather than typed by hand. The project was built with
Anthropic's Claude Fable 5.1 from a detailed brief I wrote; see "About this
project" in the README.

## One-paragraph description

Quotient is a market-making simulation written in Swift and shipped as an iOS
app. The core package implements a price-time-priority limit order book and
matching engine, a market simulator with Glosten-Milgrom informed flow and
Avellaneda-Stoikov inventory dynamics, three market-making strategies of
increasing sophistication (fixed spread, Avellaneda-Stoikov, Avellaneda-Stoikov
centred on Stoikov's microprice), and a paired Monte Carlo evaluation layer
with t-tests, drawdowns, RMS inventory and markouts by counterparty. The app
shows the book, the quotes and the P&L live, lets you switch strategies or
quote manually, runs the Monte Carlo on device, and grounds its starting
conditions in a dated snapshot of real market levels loaded through a
`MarketDataSource` protocol designed to be swapped for a live feed.

## How I describe this project

- Built a price-time priority limit order book and matching engine in Swift with
  O(1) amortised cancel via tombstoning, sequence-number time priority and a
  fuzz-tested invariant checker, and documented the data-structure trade-offs
  against a tick-indexed ladder and a balanced tree.
- Implemented Avellaneda-Stoikov (2008) reservation-price and optimal-spread
  quoting with online volatility estimation, plus a variant centred on
  Stoikov's (2018) microprice, and evaluated them against a naive maker with
  paired Monte Carlo (common random numbers, 200 trials per regime) and paired
  t-tests. In a trending regime the naive maker's inventory random-walks to a
  120-lot RMS and loses about $18k per session while the A-S maker stays flat
  and positive.
- Designed a discrete-event market simulator with Glosten-Milgrom informed
  traders and a delayed public price, and measured adverse selection directly
  through markouts split by counterparty: fills against informed traders mark
  out at −2 to −9 ticks, fills against uninformed flow at +1 to +2.

## What the results actually show

Full tables: `docs/RESULTS.md`. Highlights, 200 paired trials each:

| Regime | Fixed spread | Avellaneda-Stoikov | A-S + microprice | Read |
|---|---|---|---|---|
| Baseline (20% informed) | $674 ± 375, Sharpe 2.0, RMS inv 11 | $564 ± 87, Sharpe 12.0, RMS inv 0.75 | $558 ± 63, Sharpe 9.7 | Naive earns ~$110 more on average (p<0.0001) but with 4x the sd and 15x the drawdown. A-S is the risk-adjusted winner. |
| Inventory only (μ=0) | $1485 ± 580, max inv 44 | $1001 ± 78, Sharpe 20 | $855 ± 41 | Pure A-S setting. Skew costs edge, buys enormous variance reduction. Microprice *hurts* here (−$146, p<0.0001): with no informed flow, imbalance has no information and the lean is noise. |
| Adverse selection (45% informed) | −$84 ± 1052 | $2 ± 91 | −$3 ± 91 | Nobody wins. Markouts vs informed −4 to −6 ticks for all. A-S's only achievement is losing with 10x less variance. |
| Trending (drift + informed lead) | −$17,940 ± 6353, 0% win, RMS inv 120 | $529 ± 75, 100% win | $504 ± 58 | The textbook failure. Naive maker sells into the trend all session; reservation-price skew stops A-S from doing so. |
| News heavy (jumps every ~50 steps) | −$433 ± 622 | −$364 ± 73, 0% win | −$384 ± 75 | All lose. A-S widens to 15 ticks but still gets picked off on every jump because of the information delay. Wider spreads do not fix stale quotes. |

Three results I did not expect:

1. **The naive maker is often the highest-mean earner.** Being at the touch with
   a tight spread collects a lot of uninformed flow. The A-S maker's lower mean
   is the price of its skew. The case for A-S is risk-adjusted, not raw.
2. **The microprice variant is not uniformly better.** It helps slightly in
   Baseline and Trending (p<0.0001 on Sharpe or P&L), and hurts in Inventory
   Only. Whether imbalance predicts the mid depends on whether informed flow
   is present to make it informative. A signal is only as good as the regime.
3. **No strategy here survives a jump-dominated regime.** Inventory control and
   spread width address inventory risk, not stale quotes. That would need
   event detection, quote pulling, or speed, none of which are modelled.

## Bugs found and fixed (all with regression tests)

- **Self-referential mid feedback loop.** Strategies originally centred on the
  full-book mid, which included their own quotes. When a large order wiped out
  one side of the crowd, the maker's own far quote became that side's best
  price, the mid jumped toward it, σ spiked, the spread widened, and the loop
  ran away to a mid of −6.7 million ticks. Fix: the maker sees the market
  *excluding its own orders*. Test: `midExcludesOwnQuotesSoNoFeedbackLoop`.
- **Self-trade on re-quote.** The new bid was placed before the stale ask was
  cancelled; a large skew crossed the maker's own ask. Fix: cancel all stale
  sides, then place. Test: `makerNeverTradesWithItself`.
- **Crowd RNG desynchronised by the maker's fills.** Churn draws were made per
  *live* level, so the maker's behaviour changed the crowd's random stream and
  broke "same seed, same market." Fix: a fixed number of draws per step.
  Test: `commonRandomNumbersHoldAcrossStrategies` (checks arrival, informed and
  churn counters are identical across strategies).
- **Non-tradable pairs P&L.** P&L accrued on the re-fitted regression residual,
  which is mean-reverting by construction; the θ=0 negative control showed
  spurious profit. Fix: lock β at entry. Test: `randomWalkControl`.
- **Own-quote volatility inflation.** The maker's re-quotes moved the mid by
  half a tick and inflated its σ estimate ~40%. Fix: estimate σ on the
  external mid. Covered by the feedback-loop test and `bestExcluding`.

## Interview mapping

**"Design an order book."** `QuotientCore/Sources/QuotientCore/OrderBook/OrderBook.swift`
header. Per side: dictionary price → level for O(1) lookup, sorted array of
occupied prices for O(1) best and O(L) insert (L small), FIFO per level for
time priority, id → location index for O(1) cancel with lazy tombstoning.
Alternatives: tick-indexed ladder (O(1) everything, needs re-centring; the
right answer in C++ for latency), red-black tree (O(log L), cache-hostile).
Guarantees: strict price priority, sequence-number time priority,
modify = cancel + re-enter, market orders are IOC, resting book never crossed.
Failure modes: unknown cancel is a no-op, empty side, self-trade prevention is
a venue feature not modelled. Scaling: one book per symbol per thread.

**"Make me a market on X."** The three strategies are the three stages of the
game. Fixed spread is the first answer everyone gives. The reservation price is
"after I get hit on the bid, I lower both quotes." Spread widening with σ is
"I am less sure, so I quote wider." Markouts are how a maker tells it is being
picked off. The Manual mode in the app is the interview game itself, played
against simulated informed flow.

**"Why did A-S make less money than the naive maker?"** Because its skew
gives up edge to get flat. The P&L decomposition into spread capture and
inventory P&L makes this visible, and the trending regime shows what the naive
maker's extra edge costs when the market moves.

**"What would you need to run this on real data?"** A `MarketDataSource` that
returns live levels (one struct), and a replay/feed driver producing
`MarketState` and routing `QuoteIntent` (replacing `MarketSimulator`). Then:
latency modelling, queue position, fees, tick-constrained names, risk limits,
kill switches, and a great deal of validation. None of this is a claim of
profitability.

**"What is the microprice?"** `lim E[M_τ | I, S]`: the expected mid after the
imbalance state resolves, estimated from a Markov chain of (imbalance, spread)
transitions split into no-mid-change (Q) and mid-change (R) matrices,
`G¹ = (I−Q)⁻¹ r`, `B = (I−Q)⁻¹ R`, `G* = Σ Bⁱ G¹`. The weighted mid is the
first-order heuristic it refines. Implementation: `MicropriceEstimator.swift`.

## Research summary with dates

See `docs/RESEARCH.md` for citations and URLs. Market snapshot: Friday
2026-09-25 closes researched 2026-09-28 (SPX 7,743; SPY $771.35; VIX 14.87;
fed funds 3.75–4.00% after a 25 bp hike on 2026-09-16; 10Y 5.18%). File:
`QuotientCore/Sources/QuotientCore/MarketData/ReferenceData/market_snapshot.json`.

## What's next

1. `LiveMarketDataSource` conforming to `MarketDataSource` (Polygon, Alpaca or
   an exchange sandbox) for reference levels. The seam already exists.
2. A replay driver that feeds recorded L2 snapshots through `MarketState` so
   the strategies can be evaluated on historical microstructure.
3. Port `OrderBook` to a tick-indexed C++ or Rust ladder and benchmark
   messages/second against this Swift implementation for a throughput story.
4. Latency and queue-position modelling in the simulator; fees and rebates.
5. Guéant-Lehalle-Fernandez-Tapia closed-form quotes with a hard inventory
   bound as a fourth strategy; a Cartea-Jaimungal running inventory penalty.
6. Jump/event detection that pulls quotes, to address the News Heavy result.
