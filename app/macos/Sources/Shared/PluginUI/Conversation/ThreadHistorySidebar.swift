import MokuseiCore
import SwiftUI

private struct HistorySidebarAnchor: PreferenceKey {
    static let defaultValue: [JSONText: Anchor<CGRect>] = [:]
    static func reduce(value: inout [JSONText: Anchor<CGRect>], nextValue: () -> [JSONText: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// A lightweight index, independent of the document's bounded content window.
/// Hovering reads only the manifest summary; it never acquires a turn resource.
struct ThreadHistorySidebar: View {
    let rows: [ThreadConversationRow]
    let selected: JSONText?
    let current: JSONText?
    let availableWidth: CGFloat
    let focusRevision: Int
    let select: (JSONText) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered: JSONText?
    @State private var keyboardPreview = false
    @State private var dismissTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @State private var previewHeight: CGFloat = 130
    @State private var top: CGFloat = 0
    @State private var viewport: CGFloat = 0
    @State private var position = ScrollPosition(y: 0)
    @State private var keyboardRow: JSONText?
    @FocusState private var keyboardFocused: Bool

    private var focused: JSONText? { keyboardFocused ? keyboardRow : nil }
    private var preview: JSONText? { hovered ?? (keyboardPreview ? focused : nil) }

    private var window: Range<Int> {
        let start = min(rows.count, max(0, Int(top / 24) - 8))
        return start..<min(rows.count, start + Int(ceil(viewport / 24)) + 17)
    }

    @ViewBuilder private var indexView: some View {
        let window = window
        NativeScrollView(.vertical, showsIndicators: false) {
            // Fixed-height marks allow direct offset navigation and a bounded
            // mounted window, even when Home/End skips thousands of entries.
            VStack(spacing: 0) {
                Color.clear.frame(height: CGFloat(window.lowerBound) * 24).accessibilityHidden(true)
                ForEach(Array(rows[window].enumerated()), id: \.element.id) { offset, row in
                    entry(row, index: window.lowerBound + offset)
                }
                Color.clear.frame(height: CGFloat(rows.count - window.upperBound) * 24).accessibilityHidden(true)
            }.padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        // Keep the native responder outside recycled entries. A Home/End jump
        // can unmount the old mark before the new mark acquires a native view.
        .focusable().focusEffectDisabled().focused($keyboardFocused)
        .onChange(of: keyboardFocused) { _, active in
            if active { keyboardRow = selected; reveal(selected) }
            else { keyboardPreview = false }
        }
        .frame(width: 44)
        .frame(maxHeight: CGFloat(rows.count) * 24 + 16)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            viewport = height
            reveal(focused ?? selected)
        }
        .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.y + $0.contentInsets.top) } action: { _, value in
            top = value
        }
        .onChange(of: selected, initial: true) { _, id in
            keyboardRow = id
            reveal(id)
        }
        .onChange(of: focusRevision) { _, _ in focus(selected, preview: false) }
        .onChange(of: rows.map(\.id)) { _, ids in
            if let hovered, !ids.contains(hovered) { clearHover() }
            if let focused, !ids.contains(focused) { focus(selected, preview: keyboardPreview) }
        }
    }

    private var interactiveIndex: some View {
        indexView
        .onKeyPress(.upArrow) { moveFocus(-1); return .handled }
        .onKeyPress(.downArrow) { moveFocus(1); return .handled }
        .onKeyPress(.home) { focus(rows.first?.id); return .handled }
        .onKeyPress(.end) { focus(rows.last?.id); return .handled }
        .onKeyPress(.return) { activateFocused() }
        .onKeyPress(.space) { activateFocused() }
        .overlayPreferenceValue(HistorySidebarAnchor.self) { anchors in
            previewOverlay(anchors)
        }
    }

    var body: some View {
        interactiveIndex
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { dismissPreview() }
        }
        .onDisappear { dismissPreview() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localize("对话目录"))
        .accessibilityValue(focused.flatMap { id in rows.first { $0.id == id }?.execution?.prompt } ?? "")
        .accessibilityHint(localize("使用上下方向键选择轮次，按回车阅读"))
        .nativeReadingObservation("state", role: "history.sidebar", value: observation)
    }

    private var observation: JSONValue {
        .object([
            "selectedRow": selected.map { JSONValue.string($0) } ?? .null,
            "currentRow": current.map { JSONValue.string($0) } ?? .null,
            "focusedRow": focused.map { JSONValue.string($0) } ?? .null,
            "previewRow": preview.map { JSONValue.string($0) } ?? .null,
            "rowCount": .integer(rows.count)
        ])
    }

    private func previewOverlay(_ anchors: [JSONText: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            if let id = preview, let anchor = anchors[id],
               let row = rows.first(where: { $0.id == id }) {
                let rect = geometry[anchor]
                if rect.maxY > 0 && rect.minY < geometry.size.height {
                    ThreadHistoryPreview(row: row, current: id == current)
                        .id(id)
                        .frame(width: min(340, max(0, availableWidth - 60)), alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                        // Include the gap in the hover region so crossing from
                        // a mark to its summary does not retire the preview.
                        .padding(.leading, 4)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { showHover(id) }
                            else { dismissHover(id) }
                        }
                        .offset(x: 44, y: max(0, min(rect.midY - previewHeight / 2, geometry.size.height - previewHeight)))
                        .accessibilityHidden(true)
                        .onDisappear { dismissHover(id) }
                }
            }
        }
    }

    private func entry(_ row: ThreadConversationRow, index: Int) -> some View {
        let active = row.id == selected
        let emphasized = active || hovered == row.id || focused == row.id
        let prompt = row.execution?.prompt ?? ""
        let title = prompt.isEmpty ? localize("历史对话") : prompt
        let label = localize("第 {count} 轮对话").replacingOccurrences(of: "{count}", with: String(index + 1)) + ": " + title
        return Button { keyboardRow = row.id; select(row.id) } label: {
            Rectangle().fill(emphasized ? NativePalette.thread.inkStrong.swiftUI : NativePalette.thread.muted.swiftUI)
                .opacity(emphasized || contrast == .increased ? 1 : 0.55)
                .frame(width: active ? 26 : emphasized ? 22 : 16, height: active ? 2 : 1.5)
                .frame(width: 44, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false)
        .id(row.id)
        .onHover { inside in
            if inside { showHover(row.id) }
            else { dismissHover(row.id) }
        }
        .onDisappear { dismissHover(row.id) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: emphasized)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
        .accessibilityLabel(label)
        .accessibilityValue(row.id == current ? localize("当前轮次") : localize("历史对话"))
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .accessibilityHint(localize("按回车阅读这轮对话"))
        .anchorPreference(key: HistorySidebarAnchor.self, value: .bounds) { [row.id: $0] }
        .nativeReadingAction("entry." + nativeReadingInteractionKey(row.id),
            role: row.id == current ? "history.current" : "history.open",
            label: label, value: .string(row.id)) { select(row.id) }
    }

    private func moveFocus(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == (focused ?? selected) } ?? 0
        focus(rows[min(rows.count - 1, max(0, index + delta))].id)
    }
    private func focus(_ id: JSONText?, preview: Bool = true) {
        clearHover()
        keyboardPreview = preview
        keyboardRow = id
        keyboardFocused = true
        reveal(id)
    }
    private func showHover(_ id: JSONText) {
        dismissTask?.cancel(); dismissTask = nil
        keyboardPreview = false
        hovered = id
    }
    private func dismissHover(_ id: JSONText) {
        guard hovered == id else { return }
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            // Exit can precede the neighboring region's enter in AppKit's
            // tracking delivery. Re-entry cancels this specific dismissal.
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard hovered == id else { return }
            hovered = nil
            dismissTask = nil
        }
    }
    private func dismissPreview() {
        clearHover()
        keyboardPreview = false
    }
    private func clearHover() {
        dismissTask?.cancel(); dismissTask = nil
        hovered = nil
    }
    private func activateFocused() -> KeyPress.Result {
        guard let focused else { return .ignored }
        select(focused)
        return .handled
    }
    private func reveal(_ id: JSONText?) {
        guard let id, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let offset = max(0, min(CGFloat(rows.count) * 24 + 16 - viewport, CGFloat(index) * 24 + 20 - viewport / 2))
        top = offset
        position.scrollTo(y: offset)
    }
    private func localize(_ value: String) -> String { NativePluginLocalization.localize(value, locale: locale) }
}

private struct ThreadHistoryPreview: View {
    let row: ThreadConversationRow
    let current: Bool
    @Environment(\.locale) private var locale
    @State private var summary = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(NativeTypography.inter(size: 14, weight: 600)).lineLimit(2)
                .foregroundStyle(NativePalette.thread.inkStrong.swiftUI)
            if !summary.isEmpty {
                Text(summary).font(NativeTypography.inter(size: 13)).lineLimit(3)
                    .foregroundStyle(NativePalette.thread.muted.swiftUI)
            }
            if current {
                Text(localize("当前轮次")).font(NativeTypography.inter(size: 11))
                    .foregroundStyle(NativePalette.thread.muted.swiftUI)
            } else if let at = row.execution?.completedAt {
                Text(formatThreadTimestamp(at)).font(NativeTypography.mono(size: 11))
                    .foregroundStyle(NativePalette.thread.muted.swiftUI)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(NativePalette.thread.surface.swiftUI, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(NativePalette.thread.line.swiftUI))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .task(id: String((row.execution?.answer ?? "").prefix(1024))) {
            let text = await NativeMarkdownSummary.plainText(String((row.execution?.answer ?? "").prefix(1024)), limit: 1024)
            if !Task.isCancelled { summary = text }
        }
    }
    private var title: String {
        let prompt = row.execution?.prompt ?? ""
        return prompt.isEmpty ? localize("历史对话") : String(prompt.prefix(240)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private func localize(_ value: String) -> String { NativePluginLocalization.localize(value, locale: locale) }
}
