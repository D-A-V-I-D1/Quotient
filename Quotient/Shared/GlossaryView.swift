//
//  GlossaryView.swift
//  Quotient
//
//  Plain-language definitions, presented as a sheet from an ⓘ button on the
//  Compare, Pairs and Terminal screens. Content comes from
//  `PlainEnglish.glossary` in QuotientCore.
//

import SwiftUI
import QuotientCore

struct GlossaryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    Text("What the numbers mean, for readers without a finance or statistics background. Tap a term to expand it.")
                        .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                    ForEach(PlainEnglish.glossary) { entry in
                        GlossaryRow(entry: entry, isExpanded: expanded.contains(entry.id)) {
                            withAnimation(.snappy(duration: 0.32, extraBounce: 0)) {
                                if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                            }
                        }
                    }
                }
                .padding(12)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("What the numbers mean")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

/// One expandable term. The definition is always in the hierarchy; expanding
/// animates its height and opacity together, so the card grows and the text
/// uncovers as one motion instead of the text popping in after the resize.
private struct GlossaryRow: View {
    let entry: PlainEnglish.GlossaryEntry
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(entry.term).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.amber)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                Text(entry.definition)
                    .font(.system(size: 13)).foregroundStyle(Theme.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .frame(maxHeight: isExpanded ? .infinity : 0, alignment: .top)
                    .clipped()
                    .opacity(isExpanded ? 1 : 0)
                    .accessibilityHidden(!isExpanded)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isExpanded ? Theme.panelElevated : Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isExpanded ? Theme.amber.opacity(0.35) : Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

/// The ⓘ toolbar button that presents the glossary.
struct GlossaryButton: View {
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Image(systemName: "info.circle") }
            .accessibilityLabel("What the numbers mean")
            .sheet(isPresented: $showing) { GlossaryView() }
    }
}

/// Body text style for generated plain-English paragraphs.
struct PlainText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.ink)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
