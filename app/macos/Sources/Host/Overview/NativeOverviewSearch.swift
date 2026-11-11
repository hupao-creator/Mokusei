import Foundation
import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

public struct NativeSearchPreparation: Equatable, Sendable {
    let phase: String
    let reason: String
    let progress: Double?
    let indexing: Bool
    let pending: Int
    init?(_ value: JSONValue?) {
        guard let value, let phase = value["phase"]?.stringValue,
              ["preparing", "downloading", "verifying", "loading", "idle", "ready", "failed"].contains(phase) else { return nil }
        self.phase = phase
        reason = value["reason"]?.stringValue ?? ""
        indexing = value["indexing"]?.boolValue == true
        pending = max(0, value["pendingDocuments"]?.intValue ?? 0)
        let total = value["totalBytes"]?.numberValue ?? 0
        let completed = value["completedBytes"]?.numberValue ?? 0
        progress = total > 0 && completed.isFinite && total.isFinite ? min(1, max(0, completed / total)) : nil
    }
    var failed: Bool { phase == "failed" || !reason.isEmpty }
    var visible: Bool { failed || indexing || !["idle", "ready"].contains(phase) }
}

struct OverviewSearchPreparation: View {
    let state: NativeSearchPreparation
    let retry: () -> Void
    @Environment(\.locale) private var locale
    private var chinese: Bool { locale.language.languageCode?.identifier == "zh" }
    private var label: String {
        if state.failed { return chinese ? "语义搜索暂不可用" : "Semantic search unavailable" }
        if state.phase == "downloading", let progress = state.progress {
            return chinese ? "下载中 \(Int(progress * 100))%" : "Downloading \(Int(progress * 100))%"
        }
        if state.indexing { return chinese ? "索引中 · 剩余 \(state.pending) 条" : "Indexing · \(state.pending) remaining" }
        return chinese ? "准备语义搜索" : "Preparing semantic search"
    }
    var body: some View {
        if state.visible {
            HStack(spacing: 5) {
                if state.failed {
                    Button(action: retry) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(chinese ? "重试语义搜索" : "Retry semantic search")
                        .accessibilityIdentifier("overview-search-retry")
                } else { ProgressView().controlSize(.mini) }
                Text(label).lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: 175).help(label)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("overview-search-preparation")
        }
    }
}

/// Searches public catalog metadata in the supplied eligible collection.
/// Every whitespace-delimited term must match at least one field.
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
