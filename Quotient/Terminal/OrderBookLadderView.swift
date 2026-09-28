//
//  OrderBookLadderView.swift
//  Quotient
//
//  Depth ladder: asks stacked above the spread (red), bids below (green),
//  the maker's own resting size marked in amber. Bar length is size relative
//  to the deepest level shown, so the imbalance is visible at a glance.
//

import SwiftUI
import QuotientCore

struct OrderBookLadderView: View {
    let bids: [PriceLevelSnapshot]
    let asks: [PriceLevelSnapshot]
    let makerQuotes: (bid: Ticks?, ask: Ticks?)
    let instrument: Instrument
    let midTicks: Double
    let spreadTicks: Ticks

    /// Rows drawn per side. Always this many, padding with blanks.
    /// WHY: if the row count followed the live depth, the ladder's height
    /// would change every tick and everything below it would jump.
    let rowsPerSide = 6
    private let rowHeight: CGFloat = 20

    private var maxQty: Int { max(1, (bids + asks).map(\.quantity).max() ?? 1) }

    var body: some View {
        VStack(spacing: 2) {
            header
            ForEach(0..<rowsPerSide, id: \.self) { i in
                // Asks: deepest at the top, best just above the spread row.
                let idx = rowsPerSide - 1 - i
                if idx < asks.count { row(asks[idx], side: .ask) } else { blankRow }
            }
            spreadRow
            ForEach(0..<rowsPerSide, id: \.self) { i in
                if i < bids.count { row(bids[i], side: .bid) } else { blankRow }
            }
        }
        .transaction { $0.animation = nil }
    }

    private var blankRow: some View {
        Color.clear.frame(height: rowHeight)
    }

    private var header: some View {
        HStack {
            Text("PRICE").frame(width: 84, alignment: .leading)
            Text("SIZE").frame(width: 44, alignment: .trailing)
            Spacer()
            Text("MM").frame(width: 28)
        }
        .font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, 6)
    }

    private var spreadRow: some View {
        HStack {
            Text("mid " + Fmt.price(instrument.price(fromTicks: midTicks)))
            Spacer()
            Text("spread \(spreadTicks)t · \(Fmt.price(Double(spreadTicks) * instrument.tickSize))")
        }
        .font(Theme.mono(11)).foregroundStyle(Theme.amber)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(Theme.amber.opacity(0.08))
    }

    private func row(_ lvl: PriceLevelSnapshot, side: Side) -> some View {
        let color = side == .bid ? Theme.bid : Theme.ask
        let isMaker = lvl.marketMakerQuantity > 0
        return HStack(spacing: 0) {
            Text(Fmt.price(instrument.price(fromTicks: lvl.price)))
                .font(Theme.mono(13, weight: isMaker ? .bold : .regular))
                .foregroundStyle(color)
                .frame(width: 84, alignment: .leading)
            Text("\(lvl.quantity)")
                .font(Theme.mono(13)).foregroundStyle(Theme.ink)
                .frame(width: 44, alignment: .trailing)
            GeometryReader { geo in
                let w = geo.size.width * CGFloat(lvl.quantity) / CGFloat(maxQty)
                ZStack(alignment: side == .bid ? .leading : .trailing) {
                    Rectangle().fill(Color.clear)
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.28)).frame(width: max(2, w))
                    if isMaker {
                        let mw = geo.size.width * CGFloat(lvl.marketMakerQuantity) / CGFloat(maxQty)
                        RoundedRectangle(cornerRadius: 2).fill(Theme.amber.opacity(0.9)).frame(width: max(2, mw))
                    }
                }
            }
            .frame(height: 14)
            .padding(.horizontal, 8)
            Group {
                if isMaker { Text("●").foregroundStyle(Theme.amber) } else { Text(" ") }
            }
            .font(.system(size: 10)).frame(width: 28)
        }
        .padding(.horizontal, 6)
        .frame(height: rowHeight)
        .background(isMaker ? Theme.amber.opacity(0.06) : Color.clear)
    }
}
