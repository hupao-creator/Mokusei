import Foundation
import MokuseiCore
import MokuseiPluginAPI
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
    let text: String
    let placeholder: String
    let focusRequest: Int
    let onChange: (String) -> Void
    let onExit: () -> Void
    @Environment(\.locale) private var locale
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: Binding(get: { text }, set: { onChange($0) }), selection: $selection)
                .textFieldStyle(.plain).focused($focused)
                .accessibilityIdentifier(Self.identifier)
                .nativeOnExitCommand(perform: onExit)
            if !text.isEmpty {
                Button { onChange(""); focused = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel(locale.language.languageCode?.identifier == "zh" ? "清空搜索" : "Clear search")
            }
        }
        .font(.system(size: 13))
        .task(id: focusRequest) {
            guard focusRequest > 0 else { return }
            focused = true
            selection = TextSelection(range: text.startIndex..<text.endIndex)
        }
    }
}
