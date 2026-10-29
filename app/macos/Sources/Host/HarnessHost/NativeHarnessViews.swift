import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

/// Stable thread identity preserves plugin interaction state across revisions.
/// Teardown revokes the old lease synchronously before its async wire release.
@MainActor
public struct NativeHarnessThreadView: View {
    private let host: NativeHarnessHost
    private let input: HarnessThreadInput
    private let presentation: HarnessConversationPresentation
    private let routes: NativeHarnessThreadRoutes?
    private let source: NativeHarnessConversationSource?
    private let onIndexChange: (ThreadConversationIndex) -> Void
    @State private var surface: NativeHarnessThreadSurface?
    @State private var failure: String?

    public init(host: NativeHarnessHost, input: HarnessThreadInput,
                presentation: HarnessConversationPresentation = .main(excludedExecutionIDs: []),
                source: NativeHarnessConversationSource? = nil,
                routes: NativeHarnessThreadRoutes? = nil,
                onIndexChange: @escaping (ThreadConversationIndex) -> Void = { _ in }) {
        self.host = host; self.input = input; self.presentation = presentation; self.routes = routes; self.onIndexChange = onIndexChange
        self.source = source
    }

    private var identity: [JSONText] { [input.thread.id, input.thread.harnessID] }
    public var body: some View {
        Group {
            if let surface, !surface.isReleased { surface.view() }
            else if let failure {
                NativeHarnessStatusView(message: "此 Harness 的渲染模块暂时不可用；其他 Thread 不受影响。",
                                        english: "This Harness view is unavailable; other threads are unaffected.", detail: failure)
            } else { NativeHarnessStatusView.loading }
        }
        .task(id: identity) { open() }
        .onChange(of: input) { _, _ in update() }
        .onChange(of: presentation) { _, _ in update() }
        .onDisappear { surface?.invalidate(); surface = nil }
    }

    private func open() {
        surface?.invalidate(); failure = nil
        do { surface = try host.makeThreadSurface(input: input, presentation: presentation, source: source, routes: routes, onIndexChange: onIndexChange) }
        catch { surface = nil; failure = error.localizedDescription }
    }
    private func update() {
        guard let surface, surface.threadID == input.thread.id, surface.harnessID == input.thread.harnessID,
              !surface.isReleased else { open(); return }
        do { try surface.update(input: input, presentation: presentation, routes: routes, onIndexChange: onIndexChange) }
        catch { failure = error.localizedDescription }
    }
}

@MainActor
struct NativeHarnessStatusView: View {
    @Environment(\.locale) private var locale
    let message: String
    let english: String
    /// Loading replaces the whole reading surface, so it centers on the same
    /// column as the conversation instead of hanging off the detail's left edge.
    var centered = false
    var detail: String?
    var retry: (() -> Void)?
    private var isChinese: Bool { locale.language.languageCode?.identifier == "zh" }

    static var loading: NativeHarnessStatusView {
        NativeHarnessStatusView(message: "正在读取…", english: "Loading…", centered: true)
    }

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 10) {
            Text(isChinese ? message : english)
            if let detail { Text(detail).textSelection(.enabled) }
            if let retry { Button(isChinese ? "重试" : "Retry", action: retry).buttonStyle(.plain) }
        }
        .font(.system(size: 13)).foregroundStyle(.secondary)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: centered ? .infinity : nil,
               alignment: centered ? .center : .leading)
        .accessibilityElement(children: .contain)
    }
}
