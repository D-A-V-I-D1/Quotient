//
//  Theme.swift
//  Quotient
//
//  Visual identity: near-black base, a single amber accent for brand and
//  chrome, and green/red reserved STRICTLY for bid/ask and P&L sign so they
//  never collide with the data they encode. Series colours for multi-strategy
//  charts are amber / grey / blue — never green or red.
//

import SwiftUI

enum Theme {
    // Surfaces
    static let background = Color(red: 0.043, green: 0.043, blue: 0.051)   // #0B0B0D
    static let panel = Color(red: 0.086, green: 0.086, blue: 0.098)        // #161619
    static let panelElevated = Color(red: 0.125, green: 0.125, blue: 0.141)
    static let hairline = Color.white.opacity(0.08)

    // Brand / chrome
    static let amber = Color(red: 0.961, green: 0.651, blue: 0.137)        // #F5A623
    static let amberDim = amber.opacity(0.35)

    // Ink
    static let ink = Color(white: 0.93)
    static let inkSecondary = Color(white: 0.62)
    static let inkMuted = Color(white: 0.42)

    // Reserved semantics — do not use for chrome or series identity.
    static let bid = Color(red: 0.188, green: 0.820, blue: 0.345)          // green, buy/bid/gain
    static let ask = Color(red: 1.0, green: 0.271, blue: 0.227)            // red, sell/ask/loss

    // Strategy series (categorical, fixed order; never green/red).
    static let series: [Color] = [
        Color(white: 0.78),                                                // Fixed Spread — grey
        amber,                                                             // Avellaneda-Stoikov — amber
        Color(red: 0.353, green: 0.784, blue: 0.980),                      // A-S + Microprice — blue
    ]

    static func seriesColor(for name: String) -> Color {
        switch name {
        case "Fixed Spread": return series[0]
        case "Avellaneda-Stoikov": return series[1]
        case "A-S + Microprice": return series[2]
        default: return inkSecondary
        }
    }

    static func pnlColor(_ value: Double) -> Color {
        value > 0 ? bid : (value < 0 ? ask : inkSecondary)
    }

    // Typography
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let label = Font.system(size: 11, weight: .semibold).smallCaps()
}

// MARK: - Reusable chrome

struct Panel<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.amber)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var color: Color = Theme.ink
    var footnote: String? = nil
    var body: some View {
        // Every row has a fixed height so a tile never changes size when its
        // value or footnote changes; a resizing tile re-flows the whole screen.
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Theme.inkMuted)
                .lineLimit(1).frame(height: 12, alignment: .leading)
            Text(value).font(Theme.mono(17, weight: .semibold)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6).frame(height: 22, alignment: .leading)
            Text(footnote ?? " ").font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.inkMuted)
                .lineLimit(1).frame(height: 12, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.panelElevated, in: RoundedRectangle(cornerRadius: 8))
    }
}

enum Fmt {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.roundingMode = .halfUp
        f.usesGroupingSeparator = true
        return f
    }()

    /// "+$1,234" / "−$2,607". Grouping separators match the plain-English prose.
    static func money(_ x: Double, decimals: Int = 0) -> String {
        let sign = x < 0 ? "−" : (x > 0 ? "+" : "")
        grouped.minimumFractionDigits = decimals
        grouped.maximumFractionDigits = decimals
        let body = grouped.string(from: NSNumber(value: abs(x))) ?? String(format: "%.\(decimals)f", abs(x))
        return sign + "$" + body
    }
    static func price(_ x: Double) -> String { String(format: "%.2f", x) }
    static func num(_ x: Double, _ d: Int = 2) -> String { x.isFinite ? String(format: "%.\(d)f", x) : "–" }
    static func signed(_ x: Double, _ d: Int = 2) -> String { (x > 0 ? "+" : "") + num(x, d) }
    static func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }
    static func p(_ p: Double?) -> String {
        guard let p else { return "–" }
        return p < 0.0001 ? "p<0.0001" : String(format: "p=%.3f", p)
    }
}
