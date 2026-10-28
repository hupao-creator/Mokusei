import Foundation
import Observation
import MokuseiCore
import MokuseiPluginUI
import SwiftUI

/// Moku capsules opt into directory completion. The editor remains a generic
/// text field, and selected directories remain owned by its shared draft.
@MainActor @Observable public final class NativeMokuDirectoryMentions {
    public private(set) var selectionRequest: NativeComposerSelectionRequest?
    public private(set) var status = Status.loading
    public private(set) var enabled = false
    public private(set) var directories: [NativeComposerDirectory] = []
    public private(set) var editor = NativeComposerEditorState(text: "", selection: .init(location: 0, length: 0), focused: false, composing: false)
    private var dismissed: QueryKey?
    private var rejected: QueryKey?
    private var activeKey: QueryKey?
    private var activeIndex = 0
    @ObservationIgnored private var loadRevision = 0
    @ObservationIgnored private var ranking: (query: String, values: [NativeComposerDirectory])?

    public enum Status: Sendable { case loading, ready, error }
    public init() {}

    public var isOpen: Bool { enabled && editor.focused && !editor.composing && query != nil && dismissed != key }
    public var limitRejected: Bool { rejected == key }
    public var matches: [NativeComposerDirectory] { limitRejected ? [] : Array(ranked.prefix(50)) }
    public var hasMore: Bool { !limitRejected && ranked.count > 50 }
    public var index: Int { min(activeKey == key ? activeIndex : 0, max(0, matches.count - 1)) }

    /// Reopening the input reloads the catalog; a late response from an older
    /// opening cannot replace a newer request or reopen a closed menu.
    public func load(enabled: Bool, using loader: (() async throws -> [NativeComposerDirectory])?) async {
        loadRevision &+= 1
        let revision = loadRevision
        self.enabled = enabled && loader != nil
        guard self.enabled, let loader else { selectionRequest = nil; return }
        status = .loading
        do {
            let values = try await loader()
            guard !Task.isCancelled, self.enabled, revision == loadRevision else { return }
            var seen = Set<JSONText>()
            directories = values.filter { seen.insert($0.path).inserted }
            ranking = nil
            status = .ready
        } catch {
            guard !Task.isCancelled, self.enabled, revision == loadRevision else { return }
            status = .error
        }
    }

    public func update(_ state: NativeComposerEditorState) {
        let wasFocused = editor.focused
        let oldKey = key
        if let request = selectionRequest, !state.composing,
           state.text == editor.text, state.selection == request.range { selectionRequest = nil }
        editor = state
        if oldKey != key || (!wasFocused && state.focused) {
            dismissed = nil; rejected = nil
        }
    }

    /// Returning true consumes only a completion key. IME keys never reach this
    /// hook, and an empty Tab menu retains the editor's ordinary focus behavior.
    public func handle(_ event: NativeComposerKeyEvent, draft: NativeComposerDraft) -> Bool {
        guard !editor.composing, isOpen else { return false }
        switch event.key {
        case .escape:
            dismissed = key
            return true
        case .up, .down:
            let count = matches.count
            activeIndex = count == 0 ? 0 : (index + (event.key == .down ? 1 : -1) + count) % count
            activeKey = key
            return true
        case .enter, .tab:
            guard !event.shift else { return false }
            let options = matches
            if !options.isEmpty { choose(options[index], draft: draft) }
            return event.key == .enter || !options.isEmpty
        }
    }

    public func choose(_ directory: NativeComposerDirectory, draft: NativeComposerDraft) {
        guard enabled, !editor.composing, !draft.isDisposed, draft.text == editor.text, let query else { return }
        let exists = draft.directories.contains { $0.path == directory.path }
        guard exists || draft.directories.count < NativeComposerDraft.maximumDirectories else {
            rejected = key
            return
        }
        let source = editor.text as NSString
        guard NSMaxRange(query.range) <= source.length else { return }
        let previousKey = key
        draft.insertDirectory(directory)
        guard draft.directories.contains(where: { $0.path == directory.path }) else { return }
        draft.text = source.replacingCharacters(in: query.range, with: "")
        let selection = NSRange(location: query.range.location, length: 0)
        editor = .init(text: draft.text, selection: selection, focused: true, composing: false)
        dismissed = previousKey
        selectionRequest = NativeComposerSelectionRequest(range: selection)
    }

    private var key: QueryKey { QueryKey(text: editor.text, selection: editor.selection) }
    private var query: MentionQuery? { nativeMokuMentionQuery(editor.text, selection: editor.selection) }
    private var ranked: [NativeComposerDirectory] {
        // Read both observable inputs even on a cache hit so catalog reloads
        // and editor changes still invalidate SwiftUI's consumers.
        let catalog = directories
        let needle = query?.text.lowercased() ?? ""
        guard !needle.isEmpty else { return catalog }
        // Scoring uses NSString's literal UTF-16 matching. Swift String equality
        // folds canonical equivalents (é vs e + accent), which can rank
        // differently, so the cache must compare the exact normalized units.
        if let ranking, ranking.query.utf16.elementsEqual(needle.utf16) { return ranking.values }
        let pathSearch = needle.contains("/") || needle.contains("\\")
        let values = catalog.enumerated().compactMap { index, directory -> (Int, NativeComposerDirectory, MentionScore)? in
            guard let score = nativeMokuMentionScore((pathSearch ? directory.path : directory.name).string, query: needle) else { return nil }
            return (index, directory, score)
        }.sorted {
            if $0.2.grade != $1.2.grade { return $0.2.grade < $1.2.grade }
            if $0.2.start != $1.2.start { return $0.2.start < $1.2.start }
            if $0.2.gaps != $1.2.gaps { return $0.2.gaps < $1.2.gaps }
            return $0.0 < $1.0
        }.map { $0.1 }
        // Selection, hover, geometry and each row's index read must not rescan
        // and sort the full catalog. This cache is scoped to this picker/load.
        ranking = (needle, values)
        return values
    }

    private struct QueryKey: Equatable { let text: String; let selection: NSRange }
}

/// Unadorned completion content, mounted inside the real capsule's glass.
/// Its parent owns expansion and hit routing; there is no floating panel.
struct NativeMokuDirectoryMentionList: View {
    let mentions: NativeMokuDirectoryMentions
    let maxHeight: CGFloat
    let onChoose: (NativeComposerDirectory) -> Void
    @State private var contentHeight: CGFloat = 260
    @Environment(\.locale) private var locale

    var body: some View {
        menu.frame(height: min(contentHeight, min(260, max(0, maxHeight))))
            .accessibilityIdentifier("moku-directory-completion")
    }

    private var menu: some View {
        let matches = mentions.matches
        let selectedIndex = mentions.index
        return ScrollViewReader { proxy in
            NativeScrollView(.vertical) {
                VStack(spacing: 0) {
                    if matches.isEmpty {
                        statusRow(emptyLabel)
                    } else {
                        ForEach(Array(matches.enumerated()), id: \.element.path) { index, directory in
                            NativeMokuDirectoryOption(directory: directory, selected: index == selectedIndex,
                                                      choose: { onChoose(directory) })
                                .id(directory.path)
                        }
                    }
                    if mentions.hasMore { statusRow(localize("仅显示前 50 项，继续输入以缩小范围")) }
                }
                .padding(5)
                .onGeometryChange(for: CGFloat.self) { $0.size.height + 2 } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: ActiveOption(paths: matches.map(\.path), index: selectedIndex), initial: true) { _, active in
                guard active.paths.indices.contains(active.index) else { return }
                proxy.scrollTo(active.paths[active.index])
            }
        }
        .font(NativeTypography.inter(size: 13))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localize("已知目录"))
    }

    private func statusRow(_ text: String) -> some View {
        Text(text).font(NativeTypography.inter(size: 13)).lineSpacing(5.2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }
    private var emptyLabel: String {
        if mentions.limitRejected { return localize("每条消息最多引用 50 个目录") }
        switch mentions.status {
        case .loading: return localize("正在查找目录…")
        case .ready: return localize("没有匹配的目录")
        case .error: return localize("读取目录失败，请重新打开输入框重试")
        }
    }
    private func localize(_ value: String) -> String {
        guard locale.language.languageCode?.identifier != "zh" else { return value }
        return ["已知目录": "Known directories", "每条消息最多引用 50 个目录": "Each message can mention up to 50 directories",
            "正在查找目录…": "Looking for directories…", "没有匹配的目录": "No matching directories",
            "读取目录失败，请重新打开输入框重试": "Could not read directories. Reopen the input to try again",
            "仅显示前 50 项，继续输入以缩小范围": "Showing the first 50 items. Keep typing to narrow the results"][value] ?? value
    }
    private struct ActiveOption: Equatable { let paths: [JSONText]; let index: Int }
}

private struct NativeMokuDirectoryOption: View {
    let directory: NativeComposerDirectory
    let selected: Bool
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                NativeIcon(name: "Folder", size: 17)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(directory.name.string).font(NativeTypography.inter(size: 13, weight: 500)).frame(height: 18.2)
                    Text(directory.path.string).font(NativeTypography.inter(size: 11)).frame(height: 15.4)
                        .foregroundStyle(.secondary)
                }.lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).focusable(false)
            .accessibilityLabel(directory.name.string + ", " + directory.path.string)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MentionQuery { let range: NSRange; let text: String }
private struct MentionScore { let grade: Int; let start: Int; let gaps: Int }

private func nativeMokuMentionQuery(_ text: String, selection: NSRange) -> MentionQuery? {
    let units = Array(text.utf16)
    guard selection.length == 0, selection.location >= 0, selection.location <= units.count else { return nil }
    var start = selection.location
    while start > 0 {
        let previous = units[start - 1]
        if previous == 0x40 {
            let at = start - 1
            guard at == 0 || nativeMokuMentionWhitespace(units[at - 1]) else { return nil }
            return MentionQuery(range: NSRange(location: at, length: selection.location - at),
                text: String(decoding: units[start..<selection.location], as: UTF16.self))
        }
        if previous == 0x22 || nativeMokuMentionWhitespace(previous) { return nil }
        start -= 1
    }
    return nil
}

private func nativeMokuMentionWhitespace(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
         0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
    default: false
    }
}

private func nativeMokuMentionScore(_ text: String, query: String) -> MentionScore? {
    let value = text.lowercased() as NSString
    let needle = query as NSString
    let found = value.range(of: query, options: .literal)
    if found.location != NSNotFound {
        return MentionScore(grade: value.isEqual(to: query) ? 0 : found.location == 0 ? 1 : 2, start: found.location, gaps: 0)
    }
    var cursor = 0, first = -1
    // JavaScript's for-of iterates Unicode scalar values; offsets remain UTF-16.
    for character in query.unicodeScalars {
        let scalar = String(character)
        let match = value.range(of: scalar, options: .literal, range: NSRange(location: cursor, length: value.length - cursor))
        guard match.location != NSNotFound else { return nil }
        if first < 0 { first = match.location }
        cursor = NSMaxRange(match)
    }
    return MentionScore(grade: 3, start: first, gaps: cursor - first - needle.length)
}
