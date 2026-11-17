import AppKit
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI
import WebKit

/// The authoring viewport is independent of the Overview grid and panel width.
/// Keep existing fixed-pixel HTML and responsive HTML in the same coordinate space.
enum NativeReportCoverLayout {
    static let viewport = CGSize(width: 360, height: 308)
    static func height(for width: CGFloat) -> CGFloat { width * viewport.height / viewport.width }
}

/// Scoped to one Report plugin registration, never shared across workspaces.
/// Retain pixels and markup, not browsers, across tag-scoped card identities.
@MainActor final class NativeReportCoverCache {
    struct Key: Hashable {
        let source: ApplicationHTMLSource
        let dark: Bool
    }
    struct Entry {
        let document: ApplicationHTMLDocument
        var image: NSImage?
    }
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []

    func value(for key: Key) -> Entry? {
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return entry
    }
    func store(_ entry: Entry, for key: Key) {
        entries[key] = entry
        order.removeAll { $0 == key }; order.append(key)
        if order.count > 16 { entries.removeValue(forKey: order.removeFirst()) }
    }
    func remove(_ key: Key) {
        entries.removeValue(forKey: key); order.removeAll { $0 == key }
    }
}

extension EnvironmentValues {
    @Entry var nativeReportCoverCache: NativeReportCoverCache? = nil
}

/// Full cover markup is fetched for mounted cards, never shipped in the catalog.
struct NativeReportCover: View {
    let props: ApplicationThreadProps<NativeReportView>
    var playback: NativeReportCoverPlayback = .playing
    var onReady: () -> Void = {}
    var onPlaybackStarted: () -> Void = {}
    @State private var localCache = NativeReportCoverCache()
    @Environment(\.nativeReportCoverCache) private var sharedCache
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.threadCardAnimationVisibility) private var visibility
    @Environment(\.threadCardCloudAnimationsEnabled) private var animationsEnabled

    private var effectivePlayback: NativeReportCoverPlayback {
        if reduceMotion { return .reduced }
        if playback.isPlaying && (!animationsEnabled || visibility?.isVisible == false) { return .paused }
        return playback
    }

    var body: some View {
        let key = NativeReportCoverCache.Key(source: .init(pluginID: "report", queryID: "report.cover",
            input: props.entry.ref.json, contentRevision: props.entry.view.coverRevision), dark: colorScheme == .dark)
        GeometryReader { geometry in
            let viewport = NativeReportCoverLayout.viewport
            let scale = min(geometry.size.width / viewport.width, geometry.size.height / viewport.height)
            ReportCoverSession(props: props, key: key, cache: sharedCache ?? localCache,
                playback: effectivePlayback, onReady: onReady, onPlaybackStarted: onPlaybackStarted).id(key)
                .frame(width: viewport.width, height: viewport.height)
                // Scale the live browser and its cached poster together, without
                // changing CSS layout, stretching text or cropping authored content.
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
    }
}

private struct ReportCoverSession: View {
    let props: ApplicationThreadProps<NativeReportView>
    let key: NativeReportCoverCache.Key
    let cache: NativeReportCoverCache
    let playback: NativeReportCoverPlayback
    let onReady: () -> Void
    let onPlaybackStarted: () -> Void
    @State private var document: ApplicationHTMLDocument?
    @State private var image: NSImage?
    @State private var ready = false
    @State private var failure: String?

    init(props: ApplicationThreadProps<NativeReportView>, key: NativeReportCoverCache.Key, cache: NativeReportCoverCache,
         playback: NativeReportCoverPlayback, onReady: @escaping () -> Void, onPlaybackStarted: @escaping () -> Void) {
        self.props = props; self.key = key; self.cache = cache
        self.playback = playback; self.onReady = onReady
        self.onPlaybackStarted = onPlaybackStarted
        let cached = cache.value(for: key)
        _document = State(initialValue: cached?.document)
        _image = State(initialValue: cached?.image)
    }
    var body: some View {
        ZStack {
            NativePalette.overview.surface.swiftUI
            if let image { Image(nsImage: image).resizable() }
            else if let failure {
                Text(applicationText(props.context.locale, "封面暂不可用", "Cover unavailable"))
                    .font(NativeTypography.inter(size: 12)).foregroundStyle(.secondary).help(failure)
            } else if !ready { ProgressView().controlSize(.small) }
            if let document {
                ReportCoverHTML(html: document.html.string, dark: key.dark, playback: playback,
                    onPlaybackStarted: onPlaybackStarted, onReady: { image in
                    // Keep the rendered underlay after admission too: WebKit can
                    // commit its native layer one frame after its snapshot callback.
                    if let image { self.image = image }
                    ready = true
                    cache.store(.init(document: document, image: self.image), for: key)
                    onReady()
                }, onFailure: { message in
                    failure = message; self.document = nil; image = nil; ready = false
                    cache.remove(key)
                })
            }
        }
        .clipped()
        .task {
            guard document == nil else { return }
            do {
                let result = try await props.context.domain.query(NativeReportContracts.cover,
                    input: props.entry.ref.threadID, lifetime: props.context.lifetime)
                try Task.checkCancellation()
                guard result.contentRevision == key.source.contentRevision else {
                    throw PluginContractError("Report cover revision changed")
                }
                cache.store(.init(document: result), for: key)
                document = result
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
        .onChange(of: failure) { _, value in
            // A preload can fail after it becomes selected. Use the current
            // presentation, not the playback value captured by its fetch task.
            if value != nil {
                onReady()
                if playback.isPlaying { onPlaybackStarted() }
            }
        }
        .onChange(of: playback) { _, value in
            if failure != nil && value.isPlaying { onPlaybackStarted() }
        }
    }
}

private struct ReportCoverHTML: NSViewRepresentable {
    let html: String
    let dark: Bool
    let playback: NativeReportCoverPlayback
    let onPlaybackStarted: () -> Void
    let onReady: (NSImage?) -> Void
    let onFailure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PassiveCoverWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.addUserScript(WKUserScript(source: NativeReportCoverPlayback.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: NativeReportCoverPlayback.world))
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "mokusei-cover")
        let view = PassiveCoverWebView(frame: .zero, configuration: configuration)
        // WebKit's initial backing store is white even in a dark card. Reveal
        // only after a rendered snapshot; a retained cover bridges remounts.
        view.alphaValue = 0
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: PassiveCoverWebView, context: Context) {
        context.coordinator.onReady = onReady
        context.coordinator.onFailure = onFailure
        context.coordinator.onPlaybackStarted = onPlaybackStarted
        context.coordinator.playback = playback
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard context.coordinator.html != html else {
            context.coordinator.applyPlayback(to: view)
            return
        }
        context.coordinator.html = html
        view.load(URLRequest(url: URL(string: "mokusei-cover://document/index.html")!))
    }
    static func dismantleNSView(_ view: PassiveCoverWebView, coordinator: Coordinator) {
        coordinator.onReady = nil; coordinator.onFailure = nil; coordinator.onPlaybackStarted = nil
        coordinator.ready = false; coordinator.playbackTask?.cancel(); coordinator.playbackTask = nil
        view.evaluateJavaScript("globalThis.mokuseiCover?.pause()", in: nil,
            in: NativeReportCoverPlayback.world) { _ in }
        view.configuration.userContentController.removeAllUserScripts()
        view.stopLoading(); view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        var html: String?
        var onReady: ((NSImage?) -> Void)?
        var onFailure: ((String) -> Void)?
        var onPlaybackStarted: (() -> Void)?
        var ready = false
        var playback: NativeReportCoverPlayback = .reset
        var appliedPlayback: NativeReportCoverPlayback?
        var playbackTask: Task<Void, Never>?
        var duration = 0.0
        var holding = false
        var completedOnce = false
        var elapsed = 0.0
        var phaseStartedAt: TimeInterval?
        func applyPlayback(to webView: WKWebView) {
            guard ready, playback != appliedPlayback else { return }
            playbackTask?.cancel()
            if let phaseStartedAt { elapsed += ProcessInfo.processInfo.systemUptime - phaseStartedAt }
            phaseStartedAt = nil
            if playback == .reset || playback == .reduced || appliedPlayback == .reduced {
                holding = false; elapsed = 0
            }
            // A pause, redraw or Reduce Motion round-trip cannot grant another
            // collection play. Only leaving selection resets this admission.
            if playback == .reset { completedOnce = false }
            if playback == .reduced { completedOnce = true }
            appliedPlayback = playback
            let mode = playback
            // Page timers do not run with author JavaScript disabled. Native
            // ownership also cancels the hold/replay clock when the card leaves.
            playbackTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                var first = true
                do {
                    repeat {
                        try Task.checkCancellation()
                        let command: String
                        switch mode {
                        case .reset: command = "reset()"
                        case .reduced: command = "finish()"
                        case .paused: command = "pause()"
                        case .playing, .playingOnce:
                            command = self.holding || (mode == .playingOnce && self.completedOnce)
                                ? "finish()" : "play(\(self.elapsed))"
                        }
                        _ = try await webView.callAsyncJavaScript("return globalThis.mokuseiCover.\(command)",
                            arguments: [:], in: nil, contentWorld: NativeReportCoverPlayback.world)
                        try Task.checkCancellation()
                        guard mode.isPlaying else { return }
                        if first { self.onPlaybackStarted?(); first = false }
                        if mode == .playingOnce && (self.holding || self.completedOnce || self.duration == 0) {
                            self.completedOnce = true
                            return
                        }
                        guard self.duration > 0 else { return }
                        self.phaseStartedAt = ProcessInfo.processInfo.systemUptime
                        let remaining = max(0, (self.holding ? NativeReportCoverTiming.hold : self.duration) - self.elapsed)
                        try await Task.sleep(for: .seconds(remaining))
                        try Task.checkCancellation()
                        self.phaseStartedAt = nil; self.elapsed = 0; self.holding.toggle()
                    } while true
                } catch {
                    if !Task.isCancelled { self.onFailure?(error.localizedDescription) }
                }
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Cache a complete poster, independent of the point in a live cycle.
            // Reduce Motion can use the same underlay without exposing a first frame.
            webView.evaluateJavaScript("globalThis.mokuseiCover.finish(); globalThis.mokuseiCover.duration", in: nil,
                in: NativeReportCoverPlayback.world) { [weak self, weak webView] result in
                guard let self, let webView, self.onReady != nil else { return }
                switch result {
                case .failure(let error): self.onFailure?(error.localizedDescription); return
                case .success(let value):
                    guard let duration = value as? Double, duration.isFinite, duration >= 0,
                          duration <= NativeReportCoverTiming.maximumAnimation else {
                        self.onFailure?("Invalid cover animation duration"); return
                    }
                    self.duration = duration
                }
                webView.takeSnapshot(with: nil) { [weak self, weak webView] image, error in
                    guard let self, let webView, self.onReady != nil else { return }
                    guard let image else { self.onFailure?(error?.localizedDescription ?? "Cover snapshot unavailable"); return }
                    let initial: NativeReportCoverPlayback = self.playback == .reduced ? .reduced : .reset
                    let command = initial == .reduced ? "finish()" : "reset()"
                    webView.evaluateJavaScript("globalThis.mokuseiCover.\(command)", in: nil,
                        in: NativeReportCoverPlayback.world) { [weak self, weak webView] result in
                        guard let self, let webView, let onReady = self.onReady else { return }
                        if case .failure(let error) = result { self.onFailure?(error.localizedDescription); return }
                        self.ready = true; self.appliedPlayback = initial
                        self.completedOnce = initial == .reduced
                        onReady(image)
                        webView.alphaValue = 1
                        self.applyPlayback(to: webView)
                    }
                }
            }
        }
        // Serve only the admitted document. Response headers cannot be weakened
        // by author markup, and the custom scheme never resolves files or network.
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url,
                  url.absoluteString == "mokusei-cover://document/index.html", let html else {
                urlSchemeTask.didFailWithError(URLError(.unsupportedURL)); return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'; sandbox"
            ])!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data(html.utf8))
            urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onFailure?(error.localizedDescription)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onFailure?(error.localizedDescription)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onFailure?("Cover web content process terminated")
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url?.absoluteString
            decisionHandler(url == "mokusei-cover://document/index.html" ? .allow : .cancel)
        }
    }
}

private final class PassiveCoverWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
