import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Searches public catalog metadata only, after Overview's visibility and merge
/// rules. Every whitespace-delimited term must match at least one field.
struct NativeOverviewSearch {
    let terms: [String]
    init(_ query: String) { terms = query.split(whereSeparator: \.isWhitespace).map(String.init) }
    var sceneKey: String { NativeOverviewSelection.jsonString(.array(terms.map { .text($0) })) }
    func matches(_ fields: [String]) -> Bool {
        terms.allSatisfy { term in
            fields.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                       locale: Locale(identifier: "en_US_POSIX")) != nil }
        }
    }
    func filter(_ collection: NativeOverviewCollection,
                directoryTags: [JSONText: String] = [:]) -> NativeOverviewCollection {
        guard !terms.isEmpty else { return collection }
        return .init(threads: collection.threads.filter {
            matches([$0.title.string, $0.cwd.string,
                     directoryTags[$0.cwd] ?? NativeOverviewSelection.directoryTag($0)] + $0.tags.map(\.string))
        }, applications: collection.applications.filter {
            matches([$0.entry.title.string] + $0.entry.tags.tags.map(\.string) +
                    $0.entry.tags.semanticTags.map(\.string) + $0.entry.tags.directoryTags.map(\.string))
        })
    }
}


struct OverviewThreadSearchField: View {
    static let identifier = "overview-thread-search"
    private static let lineHeight: CGFloat = 17
    private static let verticalInset = (OverviewTagMetrics.buttonHeight - lineHeight) / 2
    let text: String
    let placeholder: String
    /// A scoped search can have no placeholder, so the editor keeps a stable
    /// spoken identity independent of the visible hint.
    var label: String? = nil
    let focusRequest: Int
    let onChange: (String) -> Void
    let onExit: () -> Void
    @Environment(\.locale) private var locale
    /// The search field reuses the native composer editor and its emphasized
    /// caret. Focus and select-all travel through native selection requests so
    /// repeated openings still replace the previous query.
    @State private var selectionRequest: NativeComposerSelectionRequest?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            NativeComposerTextInput(value: Binding(get: { text }, set: { onChange(Self.singleLine($0)) }),
                placeholder: placeholder, automaticFocus: false,
                minHeight: OverviewTagMetrics.buttonHeight, maxHeight: OverviewTagMetrics.buttonHeight,
                fontSize: 13, lineHeight: Self.lineHeight,
                insets: .init(top: Self.verticalInset, left: 6, bottom: Self.verticalInset, right: 6),
                onSubmit: {}, onEscape: onExit, selectionRequest: selectionRequest,
                singleLine: true, emphasizedInsertionPoint: true)
                .accessibilityLabel(label ?? placeholder)
                .accessibilityIdentifier(Self.identifier)
            if !text.isEmpty {
                Button {
                    onChange("")
                    selectionRequest = .init(range: NSRange(location: 0, length: 0))
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel(locale.language.languageCode?.identifier == "zh" ? "清空搜索" : "Clear search")
            }
        }
        .font(.system(size: 13))
        .task(id: focusRequest) {
            guard focusRequest > 0 else { return }
            selectionRequest = .init(range: NSRange(location: 0, length: text.utf16.count))
        }
    }
    /// A pasted or dropped line break must not survive in a single-line query.
    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
    }
}
