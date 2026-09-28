//
//  ContentView.swift
//  Quotient
//
//  Created by David De la Rosa on 9/28/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Terminal", systemImage: "chart.bar.doc.horizontal") { TerminalView() }
            Tab("Compare", systemImage: "chart.xyaxis.line") { CompareView() }
            Tab("Pairs", systemImage: "arrow.left.arrow.right") { PairsView() }
            Tab("Market", systemImage: "globe.americas") { MarketContextView() }
        }
        .background(Theme.background)
    }
}

#Preview {
    ContentView().environment(AppModel()).preferredColorScheme(.dark).tint(Theme.amber)
}
