# Research Notes

Compiled 2026-09-28 for the Quotient project. Three parts: the theory the code
implements (with citations), what quant interviews actually probe, and the
open-source landscape this project is positioned against. Citations marked
"retrieved" were fetched on 2026-09-28; formula statements were cross-checked
against the papers' standard presentations.

## A. Theory implemented

### A1. Avellaneda & Stoikov (2008) — the Level 2 strategy
Avellaneda, M. and Stoikov, S. (2008). "High-frequency trading in a limit order
book." *Quantitative Finance* 8(3), 217–224.
Author copy: https://people.orie.cornell.edu/sfs33/LimitOrderBook.pdf (retrieved)

Setup: mid-price `dS = σ dW` (arithmetic Brownian motion), a market maker with
inventory `q`, CARA utility with risk aversion `γ`, and fill intensity for a
quote at distance `δ` from the mid of `λ(δ) = A·exp(−k·δ)`.

Results used verbatim in `AvellanedaStoikovMarketMaker`:

- Reservation (indifference) price: `r(s, q, t) = s − q·γ·σ²·(T − t)`
- Optimal **total** spread: `δᵃ + δᵇ = γ·σ²·(T − t) + (2/γ)·ln(1 + γ/k)`
- Quotes are placed symmetrically around `r`, i.e. bid = r − spread/2, ask = r + spread/2.

The paper assumes continuous prices (no tick), no adverse selection, and a
finite horizon `T`. All three are simplifications this project addresses in
its simulator, not in the formula.

### A2. Guéant, Lehalle & Fernandez-Tapia (2013)
"Dealing with the inventory risk: a solution to the market making problem."
*Mathematics and Financial Economics* 7(4), 477–507. arXiv:1105.3115
https://arxiv.org/abs/1105.3115 (retrieved)

Adds an inventory bound `|q| ≤ Q` and reduces the HJB equation to a linear ODE
system, giving closed-form asymptotic quotes. Quotient borrows the *hard
inventory bound* idea as an explicit risk control (`maxInventory`), which the
original A-S paper lacks.

### A3. Cartea, Jaimungal & Penalva (2015)
*Algorithmic and High-Frequency Trading*. Cambridge University Press.
https://www.cambridge.org/us/universitypress/subjects/mathematics/mathematical-finance/algorithmic-and-high-frequency-trading (retrieved)

Related papers:
- Cartea, Jaimungal & Ricci (2014). "Buy Low, Sell High: A High Frequency Trading Perspective." *SIAM J. Financial Mathematics* 5(1), 415–444. https://papers.ssrn.com/sol3/papers.cfm?abstract_id=1964781
- Cartea & Jaimungal (2015). "Risk Metrics and Fine Tuning of High-Frequency Trading Strategies." *Mathematical Finance* 25(3), 576–611. https://onlinelibrary.wiley.com/doi/10.1111/mafi.12023

The textbook's treatment is the source for the *running inventory penalty*
formulation (penalise `φ·q²` continuously rather than only via terminal utility),
and for using short-term alpha signals to shift the reference price. Quotient's
Level 3 strategy shifts the A-S reference price from the mid to the microprice
in that spirit. This is framed as an extension motivated by Cartea et al. and
Stoikov (2018), not as a reproduction of a specific published model.

### A4. Glosten & Milgrom (1985) — the adverse-selection model in the simulator
"Bid, Ask and Transaction Prices in a Specialist Market with Heterogeneously
Informed Traders." *Journal of Financial Economics* 14(1), 71–100.
https://www.sciencedirect.com/science/article/pii/0304405X85900443 (retrieved)
PDF: https://milgrom.people.stanford.edu/wp-content/uploads/1984/09/Bid-Ask-and-Transaction-Prices.pdf

A fraction `μ` of arriving traders know the asset's true value `V`; the rest
trade for liquidity reasons regardless of price. A competitive, risk-neutral
dealer sets `ask = E[V | buy]` and `bid = E[V | sell]`; the spread exists purely
as compensation for losing to informed traders. Transaction prices reveal
information, so the dealer's quotes update after each trade.

Quotient's simulator implements this mechanically: each arriving aggressive
order is informed with probability `informedFraction`; informed traders see the
fundamental value before it becomes public and buy only when `V > ask` (sell
when `V < bid`). Markouts on the market maker's fills then measure the realised
adverse-selection cost directly.

### A5. Stoikov (2018) — the microprice signal
"The Micro-Price: A High Frequency Estimator of Future Prices." *Quantitative
Finance* 18(12), 1959–1966. SSRN 2970694 (2017).
https://www.tandfonline.com/doi/abs/10.1080/14697688.2018.1489139 (retrieved)

Defines the microprice as `lim E[M_τ | state]`, the expected mid-price after
the state (imbalance, spread) has evolved through several mid changes, estimated
from a discretised Markov chain of observed transitions. The simpler
imbalance-weighted mid `P_w = I·P_a + (1−I)·P_b`, with `I = Q_b / (Q_b + Q_a)`,
is the first-order heuristic the microprice refines.

`MicropriceEstimator` implements the paper's construction: accumulate transition
counts between (imbalance-bucket, spread-bucket) states split into
"no mid change" (Q) and "mid change" (R, with the change size), then compute
`G¹ = (I − Q)⁻¹·r` and `B = (I − Q)⁻¹·R`, and sum `G* = Σ Bⁿ·G¹` over a fixed
number of mid changes.

### A6. Cont, Kukanov & Stoikov (2014) — order flow imbalance
"The Price Impact of Order Book Events." *Journal of Financial Econometrics*
12(1), 47–88. https://arxiv.org/abs/1011.6402 (retrieved)

Shows that short-horizon price changes are driven linearly by order-flow
imbalance at the best quotes, with slope inversely related to depth. Quotient
exposes both a depth imbalance (`Signals.imbalance`) and an event-based OFI
accumulator (`OrderFlowImbalance`).

### A7. Recent related work (context, not implemented)
- Gašperov & Kostanjčar (2021). "Market making with signals through deep
  reinforcement learning." *IEEE Access* 9, 61611–61622.
- Guo, Lin & Huang (2023). "Market Making with Deep Reinforcement Learning from
  Limit Order Books." arXiv:2305.15821. https://arxiv.org/abs/2305.15821
- Falces Marin et al. (2022). "A reinforcement learning approach to improve the
  performance of the Avellaneda-Stoikov market-making algorithm." *PLOS ONE*.

No verifiable, widely cited "OFI-enhanced Avellaneda-Stoikov" paper was found.
The microprice-referenced variant in this project is therefore described as an
extension, not as an implementation of a named model.

## B. What quant interviews probe (and how this project maps to it)

Sources are prep guides and blogs, not firm statements; treat firm-specific
claims as secondhand.

- Optiver guide: https://www.techinterview.org/companies/optiver-interview-guide/
- Market-making game formats: https://www.tradermath.org/market-games ,
  https://www.quantt.co.uk/resources/quant-trader-interview-questions ,
  https://www.quantquestions.app/market-making-game
- SIG vs Jane Street styles: https://applr.ai/en/blog/2026-09-13-sig-vs-jane-street
- Quant trading prep overview: https://www.tradermath.org/knowledge-base/the-ultimate-guide-to-quant-trading-interviews
- Order book / matching engine design:
  https://www.techinterview.org/post/3233477310/limit-order-book-matching-engine-interview/ ,
  https://www.techinterview.org/post/3233477258/matching-engine-price-time-priority-system-design/ ,
  https://www.tryexponent.com/blog/quant-developer-interview-guide

**Quant trader track.** "Make me a market on X" games test whether you (1)
centre quotes on your expected value, (2) size the spread to your uncertainty,
(3) shift quotes after a fill (inventory skew), and (4) widen or skew when one
side keeps getting hit (suspect informed flow). Steps 3 and 4 are literally the
reservation-price and adverse-selection mechanics in this codebase; the
Terminal screen makes both visible.

**Quant developer track.** "Design an order book" follow-ups: O(1) cancel via
an id→node index, FIFO within a level, sorted levels vs. a tick-indexed array,
sequence numbers instead of wall clocks for time priority, modify-loses-priority,
IOC semantics for market orders, self-trade prevention, single-threaded per
symbol with sharding, snapshot + journal replay for recovery. The header of
`OrderBook.swift` answers each one and states the complexity of every
operation.

**Probability / EV.** The evaluation layer is a worked example: paired
comparison with common random numbers, a t-test on the difference, and the
observation that a fill at fair value has zero expected edge (which is exactly
why markouts on informed fills are negative).

## C. Open-source landscape and differentiation

| Project | What it does | Typically lacks |
|---|---|---|
| [Hummingbot Avellaneda strategy](https://hummingbot.org/strategies/v1-strategies/avellaneda-market-making/) | Live crypto bot implementing A-S with auto-estimated intensity | Offline simulator, adverse-selection model, markouts, significance tests |
| [fedecaccia/avellaneda-stoikov](https://github.com/fedecaccia/avellaneda-stoikov) | Python A-S with P&L/inventory plots | Real matching engine, statistical comparison |
| [ABIDES](https://github.com/jpmorganchase/abides-jpmc-public) | Multi-agent discrete-event exchange simulator | Lightweight setup, built-in A-S study, paired Monte Carlo |
| [mbt_gym](https://github.com/JJJerome/mbt_gym) | Gym environments for model-based market making | Real order book (stylised Poisson fills), UI |
| [hftbacktest](https://github.com/nkaz001/hftbacktest) | Tick-level backtester with queue position and latency | Counterfactual paired runs; recorded data only |
| [Liquibook](https://github.com/enewhuis/liquibook) | Header-only C++ matching engine | Strategies, analytics |
| [OrderBook-rs](https://github.com/joaquinbejar/OrderBook-rs) | Thread-safe Rust limit order book | Strategy layer |
| backtrader / zipline / vectorbt | Bar-based Python backtesting | Limit order book, queue model, market-making semantics |

**What Quotient does that the above generally do not, together:**
1. A real price-time matching engine integrated with the strategy (not a stylised fill model).
2. An explicit Glosten-Milgrom informed-flow model plus markout analysis at several horizons.
3. Paired Monte Carlo with common random numbers, confidence intervals and a t-test, so naive vs. A-S vs. microprice-A-S see identical market paths.
4. P&L decomposition into spread capture, inventory mark-to-market and adverse selection.
5. Deterministic, seeded, replayable simulation with a test suite.
6. A native Swift core and an iOS visualisation front-end, described honestly as an exploration tool rather than a production system.
7. A stated limitations section (continuous-time assumptions, tick effects, latency).
