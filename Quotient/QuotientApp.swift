//
//  QuotientApp.swift
//  Quotient
//
//  Created by David De la Rosa on 9/28/26.
//

import SwiftUI

@main
struct QuotientApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
                .task { await model.load() }
        }
    }
}
