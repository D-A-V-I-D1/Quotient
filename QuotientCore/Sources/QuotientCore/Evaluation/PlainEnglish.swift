//
//  PlainEnglish.swift
//  QuotientCore
//
//  Translates the evaluation layer's numbers into short written summaries
//  for readers without a quant background.
//
//  Design rules (see docs/PLAIN_ENGLISH.md):
//    * Every sentence is computed from the same `StrategyOutcome`,
//      `PairedComparison`, `PairsResult` and live values the technical views
//      display. There is no per-scenario canned text, so the prose can never
//      drift from the numbers.
//    * Wording is chosen by thresholds that are named constants below, not
//      scattered magic numbers.
//    * This file is presentation logic and depends only on the result
//      types; it has no knowledge of SwiftUI.
//

import Foundation

public enum PlainEnglish {

    // MARK: - Thresholds (named so the wording rules are auditable)

    /// p-value below which a paired difference is described as clear.
    static let clearSignificance = 0.01
    /// p-value below which a paired difference is described as likely real.
    static let likelySignificance = 0.05
    /// Ratio of standard deviations at or above which one strategy is called
    /// "far more consistent" than another.
    static let farMoreConsistentRatio = 3.0
    /// Ratio at or above which something is called "noticeably" more/less.
    static let noticeableRatio = 1.5
    /// Ratio band inside which two values are called "about the same".
    static let aboutTheSameBand = 1.15
    /// RMS inventory (lots) at or below which the maker "kept almost no position".
    static let nearFlatInventoryLots = 1.0
    /// Win rate at or above which a strategy is "almost always" positive.
    static let almostAlwaysWinRate = 0.95
    /// Win rate at or below which a strategy "almost never" ended positive.
    static let almostNeverWinRate = 0.05

    // MARK: - Compare screen

    /// One or two sentences on the whole report: who did best on average,
    /// who did best on a risk-adjusted basis, and whether those differ.
    public static func headline(_ report: MonteCarloReport) -> String {
        let outcomes = report.outcomes.filter { $0.fillCount.mean > 0 }
        guard outcomes.count >= 2,
              let bestMean = outcomes.max(by: { $0.finalPnL.mean < $1.finalPnL.mean }),
              // "Steadiest" = smallest run-to-run variation. Not Sharpe: when
              // every strategy loses, mean/sd ranks the *noisier* loser higher
              // (−172/288 beats −141/48), which reads as nonsense.
              let steadiest = outcomes.min(by: { $0.finalPnL.standardDeviation < $1.finalPnL.standardDeviation }) else {
            return report.outcomes.isEmpty ? "No results yet." : "Not enough trading activity to compare strategies in this scenario."
        }
        let n = report.configuration.trials
        let allLost = outcomes.allSatisfy { $0.finalPnL.mean < 0 }
        let bestPhrase = bestMean.finalPnL.mean >= 0
            ? "made the most on average (\(money(bestMean.finalPnL.mean)) per session)"
            : "lost the least on average (\(money(bestMean.finalPnL.mean)) per session)"
        // Treat near-identical variability as a tie rather than a distinction.
        let tiedOnSteadiness = bestMean.finalPnL.standardDeviation <= steadiest.finalPnL.standardDeviation * aboutTheSameBand
        var s = "Across \(n) simulated sessions on identical markets, "
        if bestMean.name == steadiest.name {
            s += "\(bestMean.name) \(bestPhrase) and also had the steadiest results from run to run, so it is the clear winner here."
        } else if tiedOnSteadiness {
            s += "\(bestMean.name) \(bestPhrase) and was about as steady from run to run as \(steadiest.name) (±\(money(bestMean.finalPnL.standardDeviation)) versus ±\(money(steadiest.finalPnL.standardDeviation)))."
        } else {
            s += "\(bestMean.name) \(bestPhrase), but \(steadiest.name) had the steadiest results from run to run (±\(money(steadiest.finalPnL.standardDeviation)) versus ±\(money(bestMean.finalPnL.standardDeviation))). "
            s += "When results this variable are involved, the steadier strategy is usually the one a trading desk would actually run."
        }
        if allLost {
            s += " Every strategy lost money in this scenario; the comparison is about who lost least and most predictably."
        } else if let worst = outcomes.min(by: { $0.finalPnL.mean < $1.finalPnL.mean }),
                  worst.finalPnL.mean < 0, bestMean.finalPnL.mean > 0, worst.name != bestMean.name {
            s += " \(worst.name), by contrast, lost about \(money(abs(worst.finalPnL.mean))) per session and finished positive in only \(percent(worst.winRate)) of sessions."
        }
        return s
    }

    /// 2–4 sentences describing one strategy's results, compared with a
    /// reference strategy from the same paired run.
    public static func summary(of outcome: StrategyOutcome, in report: MonteCarloReport) -> String {
        guard outcome.fillCount.mean > 0 else {
            return "\(outcome.name) never traded in this scenario, so it has no profit, loss or risk to report. Its quotes were never competitive enough to be filled."
        }
        let reference = report.outcomes.first { $0.name != outcome.name && $0.fillCount.mean > 0 }
        var sentences: [String] = []
        sentences.append(resultSentence(outcome, trials: report.configuration.trials))
        if let ref = reference, let cmp = report.comparison(outcome.name, ref.name) {
            sentences.append(comparisonSentence(outcome, ref, cmp))
        }
        if let adverse = adverseSelectionSentence(outcome, reference: reference) {
            sentences.append(adverse)
        }
        if let ref = reference, let caveat = winRateCaveat(outcome, ref) {
            sentences.append(caveat)
        }
        return sentences.joined(separator: " ")
    }

    // MARK: Sentence builders

    static func resultSentence(_ o: StrategyOutcome, trials: Int) -> String {
        let mean = o.finalPnL.mean
        let sd = o.finalPnL.standardDeviation
        let verb = mean >= 0 ? "made" : "lost"
        var s = "On average this strategy \(verb) about \(money(abs(mean))) per session"
        if sd == 0 {
            s += ", with identical results every run"
        } else if abs(mean) > 0, sd / abs(mean) <= 0.25 {
            s += ", and its results barely varied between runs (±\(money(sd)))"
        } else if abs(mean) > 0, sd / abs(mean) >= 2 {
            s += ", but that average hides huge swings (±\(money(sd)) from one run to the next)"
        } else {
            s += " (±\(money(sd)) from run to run)"
        }
        s += ". It finished positive in \(percent(o.winRate)) of sessions"
        if o.rmsInventory.mean <= nearFlatInventoryLots {
            s += " and kept almost no position open at any time."
        } else {
            let typical = Int(o.rmsInventory.mean.rounded()), peak = Int(o.maxAbsInventory.mean.rounded())
            s += ", carrying a typical position of about \(typical) lot\(typical == 1 ? "" : "s") and peaking at \(peak)."
        }
        return s
    }

    static func comparisonSentence(_ o: StrategyOutcome, _ ref: StrategyOutcome, _ cmp: PairedComparison) -> String {
        // The comparison struct is a − b; orient it so "diff" is o − ref.
        let sign: Double = cmp.a == o.name ? 1 : -1
        let dPnL = (cmp.finalPnL?.meanDifference ?? (o.finalPnL.mean - ref.finalPnL.mean)) * sign
        let p = cmp.finalPnL?.pValue ?? 1

        var s = "Compared with \(ref.name), it "
        if abs(dPnL) < 1 {
            s += "made about the same on average"
        } else if o.finalPnL.mean < 0 && ref.finalPnL.mean < 0 {
            // Both lost: "lost $31 more" reads better than "made $31 less".
            s += "lost about \(money(abs(dPnL))) \(dPnL > 0 ? "less" : "more") per session"
            s += " (\(significanceClause(p)))"
        } else {
            s += "made about \(money(abs(dPnL))) \(dPnL > 0 ? "more" : "less") per session"
            s += " (\(significanceClause(p)))"
        }

        var risk: [String] = []
        let sdRatio = ratio(ref.finalPnL.standardDeviation, o.finalPnL.standardDeviation)
        if let r = sdRatio, r >= farMoreConsistentRatio {
            risk.append("its results were far more consistent (about \(times(r)) less variable)")
        } else if let r = sdRatio, r >= noticeableRatio {
            risk.append("its results were noticeably more consistent")
        } else if let r = sdRatio, r <= 1 / farMoreConsistentRatio {
            risk.append("its results swung about \(times(1 / r)) more from run to run")
        } else if let r = sdRatio, r <= 1 / noticeableRatio {
            risk.append("its results were noticeably less consistent")
        }
        let ddRatio = ratio(ref.maxDrawdown.mean, o.maxDrawdown.mean)
        if let r = ddRatio, r >= noticeableRatio {
            risk.append("its worst losing stretch within a session was about \(times(r)) smaller")
        } else if let r = ddRatio, r <= 1 / noticeableRatio {
            risk.append("its worst losing stretch within a session was about \(times(1 / r)) larger")
        }
        let invRatio = ratio(ref.rmsInventory.mean, o.rmsInventory.mean)
        if let r = invRatio, r >= noticeableRatio {
            risk.append("it held a much smaller position")
        } else if let r = invRatio, r <= 1 / noticeableRatio {
            risk.append("it held a much larger position")
        }

        if risk.isEmpty {
            s += ", with similar risk."
        } else {
            // "but" when profit and risk point in opposite directions, "and" otherwise.
            let saferThanRef = (sdRatio ?? 1) >= noticeableRatio || (ddRatio ?? 1) >= noticeableRatio
            let riskierThanRef = (sdRatio ?? 1) <= 1 / noticeableRatio || (ddRatio ?? 1) <= 1 / noticeableRatio
            let opposite = (dPnL < -1 && saferThanRef) || (dPnL > 1 && riskierThanRef)
            s += (opposite ? ", but " : ", and ") + joinList(risk) + "."
        }
        return s
    }

    static func adverseSelectionSentence(_ o: StrategyOutcome, reference: StrategyOutcome?) -> String? {
        let h = o.meanMarkoutVsInformedTicks.keys.sorted().first { $0 >= 50 } ?? o.meanMarkoutVsInformedTicks.keys.sorted().first
        guard let h, let informed = o.meanMarkoutVsInformedTicks[h]?.mean else {
            if let h2 = o.meanMarkoutVsNoiseTicks.keys.sorted().first, let noise = o.meanMarkoutVsNoiseTicks[h2]?.mean {
                return "There were no better-informed traders in this scenario; each trade with ordinary flow \(noise >= 0 ? "earned" : "cost") it about \(ticks(abs(noise))) a share."
            }
            return nil
        }
        var s: String
        if informed < 0 {
            s = "Each trade against a better-informed trader cost it about \(ticks(abs(informed))) a share shortly afterwards"
            if let ref = reference, let refInf = ref.meanMarkoutVsInformedTicks[h]?.mean, refInf < 0 {
                let r = abs(refInf) / abs(informed)
                if r >= noticeableRatio { s += ", less than half of what \(ref.name) gave up" }
                else if r <= 1 / noticeableRatio { s += ", more than \(ref.name) gave up" }
                else { s += ", about the same as \(ref.name)" }
            }
        } else {
            s = "Unusually, its trades against better-informed traders did not lose money afterwards (\(ticks(informed)) a share)"
        }
        if let noise = o.meanMarkoutVsNoiseTicks[h]?.mean {
            s += "; trades with ordinary flow \(noise >= 0 ? "earned" : "cost") about \(ticks(abs(noise))) a share."
        } else {
            s += "."
        }
        return s
    }

    /// Explains the counter-intuitive case where the strategy with the lower
    /// win rate is the steadier one (or vice versa).
    static func winRateCaveat(_ o: StrategyOutcome, _ ref: StrategyOutcome) -> String? {
        let oSteadier = o.finalPnL.standardDeviation < ref.finalPnL.standardDeviation / noticeableRatio
        let refWinsMore = ref.winRate > o.winRate + 0.05
        let oWinsMore = o.winRate > ref.winRate + 0.05
        let refSteadier = ref.finalPnL.standardDeviation < o.finalPnL.standardDeviation / noticeableRatio

        if oSteadier && refWinsMore {
            if o.winRate <= almostNeverWinRate {
                return "\(ref.name) ended positive more often (\(percent(ref.winRate)) vs \(percent(o.winRate))), but that is luck at work: it also produced the far larger losses. Losing a small, predictable amount every time is the safer outcome here, and that is what this strategy did."
            }
            return "\(ref.name) 'won' more often (\(percent(ref.winRate)) vs \(percent(o.winRate))) by occasionally getting lucky, but it also occasionally lost far more. Consistency, not win rate, is the advantage being measured here."
        }
        if oWinsMore && refSteadier {
            return "This strategy ended positive more often than \(ref.name), but with much wider swings; a higher win rate is not the same as lower risk."
        }
        return nil
    }

    // MARK: - Pairs screen

    /// Summary of one pairs-trading path plus, if available, its Monte Carlo.
    public static func pairsSummary(_ r: PairsResult, parameters p: PairsParameters,
                                    monteCarlo: (mean: Double, tStatistic: Double, trials: Int)? = nil) -> String {
        var s: [String] = []
        let regime = p.reversionSpeed > 0
            ? "In this run the gap between the two stocks is set to drift back toward normal over time"
            : "In this run the gap between the two stocks wanders randomly and has no tendency to come back"
        s.append(regime + ".")

        if r.trades == 0 {
            s.append("The strategy never found the gap stretched far enough to trade, so it made and lost nothing.")
        } else {
            let pct = r.finalPnL * 100
            let verb = pct >= 0 ? "made" : "lost"
            s.append("It stepped in \(r.trades) time\(r.trades == 1 ? "" : "s") when the gap looked unusually wide or narrow, betting it would close, and \(verb) about \(number(abs(pct), 2))% of the money committed to each side.")
        }

        if let mc = monteCarlo {
            let pct = mc.mean * 100
            let t = mc.tStatistic
            if abs(t) >= 2.5 {
                s.append("Across \(mc.trials) random paths it averaged \(pct >= 0 ? "a gain" : "a loss") of about \(number(abs(pct), 2))%, and that average is too consistent to be luck.")
            } else {
                s.append("Across \(mc.trials) random paths it averaged \(pct >= 0 ? "a gain" : "a loss") of about \(number(abs(pct), 2))%, which is within the range luck alone would produce")
                s[s.count - 1] += p.reversionSpeed > 0 ? "." : ", exactly what should happen when there is no real pattern to exploit."
            }
        }
        return s.joined(separator: " ")
    }

    // MARK: - Terminal screen

    /// The live facts the Terminal summary is computed from.
    public struct LiveState: Sendable, Equatable {
        public var symbol: String
        public var inventoryLots: Int
        public var sharesPerLot: Int
        public var pnlDollars: Double
        public var fills: Int
        public var informedFills: Int
        /// Current and earlier quoted spread in ticks, if two-sided.
        public var quotedSpreadTicks: Int?
        public var earlierQuotedSpreadTicks: Int?
        /// Current estimated σ versus the calibration prior.
        public var sigmaEstimate: Double
        public var sigmaPrior: Double
        public var isFinished: Bool
        public var step: Int

        public init(symbol: String, inventoryLots: Int, sharesPerLot: Int, pnlDollars: Double, fills: Int, informedFills: Int,
                    quotedSpreadTicks: Int?, earlierQuotedSpreadTicks: Int?, sigmaEstimate: Double, sigmaPrior: Double,
                    isFinished: Bool, step: Int) {
            self.symbol = symbol; self.inventoryLots = inventoryLots; self.sharesPerLot = sharesPerLot
            self.pnlDollars = pnlDollars; self.fills = fills; self.informedFills = informedFills
            self.quotedSpreadTicks = quotedSpreadTicks; self.earlierQuotedSpreadTicks = earlierQuotedSpreadTicks
            self.sigmaEstimate = sigmaEstimate; self.sigmaPrior = sigmaPrior; self.isFinished = isFinished; self.step = step
        }
    }

    public static func liveSummary(_ s: LiveState) -> String {
        if s.step == 0 { return "Press Run. The algorithm will start quoting a bid and an ask around the current \(s.symbol) price." }
        var parts: [String] = []
        let shares = abs(s.inventoryLots) * s.sharesPerLot
        let position: String
        if s.inventoryLots == 0 { position = "flat (no position)" }
        else { position = "\(s.inventoryLots > 0 ? "long" : "short") \(shares) shares" }
        let pnl = s.pnlDollars >= 0 ? "up \(money(s.pnlDollars))" : "down \(money(abs(s.pnlDollars)))"
        parts.append("The algorithm is currently \(position) and \(pnl) after \(s.fills) fill\(s.fills == 1 ? "" : "s").")

        if let now = s.quotedSpreadTicks, let before = s.earlierQuotedSpreadTicks, now != before {
            let dir = now > before ? "widened" : "tightened"
            let why: String
            if s.sigmaEstimate > s.sigmaPrior * 1.25 && now > before { why = " because the market has become more volatile" }
            else if s.inventoryLots != 0 { why = " while leaning its prices to work off its position" }
            else { why = "" }
            parts.append("It has \(dir) its spread from \(before) to \(now) tick\(now == 1 ? "" : "s")\(why).")
        } else if s.inventoryLots != 0 {
            parts.append("It is shading its quotes to \(s.inventoryLots > 0 ? "sell" : "buy") its way back to flat.")
        }
        if s.informedFills > 0 {
            parts.append("\(s.informedFills) of its fills came from traders who knew where the price was heading.")
        }
        if s.isFinished { parts.append("Session complete.") }
        return parts.joined(separator: " ")
    }

    // MARK: - Glossary

    public struct GlossaryEntry: Sendable, Identifiable, Equatable {
        public var id: String { term }
        public let term: String
        public let definition: String
    }

    /// Plain-language definitions of the concepts on screen. Static by design:
    /// definitions are not numbers and cannot drift from a run.
    public static let glossary: [GlossaryEntry] = [
        GlossaryEntry(term: "Market maker",
                      definition: "A trader who continuously offers to both buy (the bid) and sell (the ask), earning the small gap between the two on each round trip. The algorithms in this app are market makers; everyone else in the simulation is trading against them."),
        GlossaryEntry(term: "Spread",
                      definition: "The gap between the price the market maker will buy at and the price it will sell at, measured in ticks (one tick is one cent here). Wider means more profit per round trip but fewer trades; tighter means the opposite."),
        GlossaryEntry(term: "Inventory",
                      definition: "The position the market maker is holding at a given moment: positive if it has bought more than it sold, negative if the reverse. Inventory is risk: if the price moves against it, the position loses money. RMS inventory is the typical size of that position over a session; a number near zero means the strategy stayed close to flat."),
        GlossaryEntry(term: "Session P&L",
                      definition: "Profit or loss at the end of one simulated trading session, in dollars, marking any open position at the current mid price. The table shows the average across all sessions and how much it varied (±)."),
        GlossaryEntry(term: "Sharpe ratio",
                      definition: "Return divided by how much that return bounced around. Two strategies can make the same average profit, but the one whose results swing less has the higher Sharpe. It measures risk-adjusted return, not raw return, which is why a strategy that makes less money can have a much higher Sharpe. Here it is computed per session and not annualised."),
        GlossaryEntry(term: "Max drawdown",
                      definition: "The biggest drop from a high point to a later low point in P&L within a session: the worst losing stretch you would have had to sit through. Smaller is safer."),
        GlossaryEntry(term: "Markout",
                      definition: "After the market maker trades, where did the price go? A markout measures the price move after a fill, in ticks per share, from the maker's point of view. Positive means the price moved in its favour; negative means it had just bought something that was about to fall or sold something about to rise."),
        GlossaryEntry(term: "Informed traders and adverse selection",
                      definition: "Some simulated traders know where the price is heading before the market does (from Glosten and Milgrom's 1985 model). They only trade when the market maker's quote is wrong, so the maker's fills against them are followed by the price moving against it. A negative markout against informed traders is therefore expected, and it is a sign the simulation captures a real cost of market making rather than a flaw in the strategy."),
        GlossaryEntry(term: "Win rate",
                      definition: "The share of sessions that ended with a profit. On its own it is misleading: a strategy can finish positive in every session by earning small, steady amounts, or in only half of them because it swings wildly between big wins and big losses. In some scenarios in this app the strategy with the lower win rate is the better one, because it loses small, predictable amounts while the higher-win-rate strategy occasionally loses far more. Read win rate together with the ± variation and the drawdown."),
        GlossaryEntry(term: "Paired trials",
                      definition: "Every strategy is run on exactly the same sequence of simulated market events, seed for seed, so the difference between them is due to the strategies alone and not to one of them getting an easier market. The p-value says how likely a difference that large would be if the strategies were actually equivalent; below 0.05 is usually treated as a real difference."),
        GlossaryEntry(term: "Reservation price (Avellaneda-Stoikov)",
                      definition: "The price at which the market maker is indifferent between buying and selling, given what it already holds. When it is long, it lowers both quotes to encourage selling and discourage buying; when short, the reverse. This is what stops the position from drifting without limit, and it is the core idea in the Avellaneda and Stoikov 2008 model."),
        GlossaryEntry(term: "Microprice",
                      definition: "A better guess at the 'true' price than the midpoint between bid and ask. If there is much more size waiting to buy than to sell, the next price move is more likely up, so the microprice sits above the mid. The A-S + Microprice strategy centres its quotes on this estimate instead of the mid."),
    ]

    // MARK: - Formatting helpers

    static func money(_ x: Double) -> String {
        guard x.isFinite else { return "an unknown amount" }
        // Whole dollars from $10 up, cents below. Round half away from zero
        // ourselves: NumberFormatter's default is banker's rounding (12.5 → 12).
        let v = abs(x)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.roundingMode = .halfUp
        f.maximumFractionDigits = v < 10 ? 2 : 0
        f.minimumFractionDigits = v < 10 && v != v.rounded() ? 2 : 0
        let body = f.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v)
        return (x < 0 ? "−$" : "$") + body
    }

    static func number(_ x: Double, _ decimals: Int) -> String {
        x.isFinite ? String(format: "%.\(decimals)f", x) : "–"
    }

    static func percent(_ x: Double) -> String { String(format: "%.0f%%", (x * 100).rounded()) }

    static func ticks(_ t: Double) -> String {
        let cents = t // one tick = one cent for every instrument in the snapshot
        if cents < 1 { return String(format: "%.1f cents", cents) }
        return String(format: "%.1f cent%@", cents, cents == 1 ? "" : "s")
    }

    /// a / b, or nil if not meaningful.
    static func ratio(_ a: Double, _ b: Double) -> Double? {
        guard a.isFinite, b.isFinite, b > 0, a >= 0 else { return nil }
        return a / b
    }

    static func times(_ r: Double) -> String {
        r >= 10 ? "\(Int(r.rounded()))×" : String(format: "%.1f×", r).replacingOccurrences(of: ".0×", with: "×")
    }

    static func significanceClause(_ p: Double) -> String {
        if p < clearSignificance { return "a clear difference, not noise" }
        if p < likelySignificance { return "probably a real difference" }
        return "a difference small enough to be luck"
    }

    static func joinList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}
