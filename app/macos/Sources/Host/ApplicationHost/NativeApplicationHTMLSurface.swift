import AppKit
import CryptoKit
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import QuartzCore
import SwiftUI
import WebKit

/// An isolated application-owned HTML document surface. Domain access remains
/// in the scoped host reader, outside WebKit.
@MainActor
public struct NativeApplicationHTMLSurface: View {
    public let source: ApplicationHTMLSource
    public let thread: ApplicationThreadRef
    public let theme: PluginTheme
    public let suppressed: Bool
    public let locale: JSONText
    private let zoomPreferencesURL: URL?
    private let readDocument: @MainActor (ApplicationHTMLSource) async throws -> ApplicationHTMLDocument
    private let openExternal: @MainActor (URL) async throws -> Void
    private let onBack: () -> Void
    private let onSettings: () -> Void
    private let onNativeNavigationChange: (Bool) -> Void
    private let onFailure: (ApplicationHTMLFailure) -> Void
    @Environment(\.nativeHTMLPreloader) private var preloader

    public init(source: ApplicationHTMLSource, thread: ApplicationThreadRef, theme: PluginTheme,
                suppressed: Bool, locale: JSONText = "zh-CN", zoomPreferencesURL: URL? = nil,
                readDocument: @escaping @MainActor (ApplicationHTMLSource) async throws -> ApplicationHTMLDocument,
                openExternal: @escaping @MainActor (URL) async throws -> Void,
                onBack: @escaping () -> Void, onSettings: @escaping () -> Void,
                onNativeNavigationChange: @escaping (Bool) -> Void,
                onFailure: @escaping (ApplicationHTMLFailure) -> Void) {
        self.source = source; self.thread = thread; self.theme = theme
        self.suppressed = suppressed; self.locale = locale; self.readDocument = readDocument
        self.zoomPreferencesURL = zoomPreferencesURL
        self.openExternal = openExternal; self.onBack = onBack; self.onSettings = onSettings
        self.onNativeNavigationChange = onNativeNavigationChange; self.onFailure = onFailure
    }

    public var body: some View {
        HTMLDocumentSession(source: source, thread: thread, theme: theme, suppressed: suppressed,
            locale: locale, zoomPreferencesURL: zoomPreferencesURL, preloader: preloader,
            readDocument: readDocument, openExternal: openExternal,
            onBack: onBack, onSettings: onSettings,
            onNativeNavigationChange: onNativeNavigationChange, onFailure: onFailure)
            .id(HTMLDocumentIdentity(source: source, thread: thread))
    }
}

private struct HTMLDocumentIdentity: Hashable {
    let source: ApplicationHTMLSource
    let thread: ApplicationThreadRef
}

@MainActor
private struct HTMLDocumentSession: View {
    let source: ApplicationHTMLSource
    let thread: ApplicationThreadRef
    let theme: PluginTheme
    let suppressed: Bool
    let locale: JSONText
    let zoomPreferencesURL: URL?
    let preloader: NativeApplicationHTMLPreloader?
    let readDocument: @MainActor (ApplicationHTMLSource) async throws -> ApplicationHTMLDocument
    let openExternal: @MainActor (URL) async throws -> Void
    let onBack: () -> Void
    let onSettings: () -> Void
    let onNativeNavigationChange: (Bool) -> Void
    let onFailure: (ApplicationHTMLFailure) -> Void
    @State private var document: ApplicationHTMLDocument?
    @State private var failure: String?
    @State private var refresh = UUID()
    @State private var loadedGeneration = UUID()
    @State private var ready = false
    @State private var scrollHidden = false
    @State private var hovered = false
    @FocusState private var navigationFocused: Bool

    private var english: Bool { locale.string.hasPrefix("en") }
    private var collapsed: Bool { scrollHidden && !hovered && !navigationFocused }

    var body: some View {
        ZStack(alignment: .topLeading) {
            NativeAppKitPalette.thread.canvas.swiftUI
            if let document {
                HTMLWebDocument(document: document, thread: thread, theme: theme, suppressed: suppressed, locale: locale,
                    zoomPreferencesURL: zoomPreferencesURL, preloader: preloader,
                    openExternal: openExternal, onReady: {
                        ready = true; onNativeNavigationChange(true)
                    }, onFailure: fail, onNavigation: { intent in
                        guard !suppressed else { return }
                        switch intent {
                        case .back: onBack()
                        case .settings: onSettings()
                        }
                    }, onPresentation: { hidden in
                        scrollHidden = hidden
                    }, onHover: { hovered = $0 })
                    .id(loadedGeneration)
            }
            if let failure {
                VStack(spacing: 12) {
                    NativeIcon(name: "CircleAlert", size: 20)
                    Text(english ? "Unable to display this document." : "无法显示此文档。")
                    Text(failure).font(.caption).foregroundStyle(NativeAppKitPalette.thread.muted.swiftUI)
                        .textSelection(.enabled)
                    Button(english ? "Retry" : "重试", action: reload)
                }
                .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
            } else if !ready {
                ProgressView(english ? "Loading document…" : "正在读取文档…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if ready {
                HTMLNavigationPortal(content: AnyView(navigation), collapsed: collapsed, suppressed: suppressed,
                    zoomPreferencesURL: zoomPreferencesURL,
                    onBack: onBack, onSettings: onSettings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
        .preferredColorScheme(theme == .dark ? .dark : .light)
        .task(id: refresh) {
            document = nil; failure = nil; ready = false; scrollHidden = false; hovered = false
            onNativeNavigationChange(false)
            do {
                let result = try await readDocument(source)
                try Task.checkCancellation()
                guard result.contentRevision == source.contentRevision else {
                    throw PluginContractError(english
                        ? "HTML document changed; reopen the current revision."
                        : "HTML 文档已更新，请重新打开当前版本。")
                }
                loadedGeneration = UUID(); document = result
            } catch is CancellationError {
                // A newer source or a departing view owns subsequent results.
            } catch {
                guard !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
        .onChange(of: suppressed) { _, hidden in
            if hidden { hovered = false; navigationFocused = false }
        }
        .onDisappear { onNativeNavigationChange(false) }
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 76, height: 18)
                .overlay(alignment: .trailing) { NativeAppKitPalette.thread.line.swiftUI.frame(width: 1) }
                .accessibilityHidden(true)
            Button(action: onBack) {
                NativeIcon(name: "ArrowLeft", size: 17, strokeWidth: 1.8)
                    .frame(width: navigationButtonSize.width, height: navigationButtonSize.height)
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).focused($navigationFocused)
            .help(english ? "Back to overview" : "返回俯瞰")
            .accessibilityLabel(english ? "Back to overview" : "返回俯瞰")
        }
        .padding(5).frame(width: navigationSize.width, height: navigationSize.height)
        .foregroundStyle(NativeAppKitPalette.thread.ink.swiftUI)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(english ? "Window and back navigation" : "窗口与返回导航")
        .onKeyPress(phases: .down) { press in
            guard !suppressed else { return .ignored }
            let modifiers = press.modifiers.intersection([.command, .control, .option, .shift])
            if modifiers == .command && press.characters == "," {
                onSettings(); return .handled
            }
            if modifiers.isEmpty && press.key == .escape || modifiers == .option && press.key == .leftArrow {
                onBack(); return .handled
            }
            return .ignored
        }
    }

    private var navigationButtonSize: CGSize {
        CGSize(width: 32, height: 30)
    }

    private var navigationSize: CGSize {
        CGSize(width: 132, height: 42)
    }

    private func fail(_ message: String) {
        document = nil; ready = false; failure = message
        onNativeNavigationChange(false)
        onFailure(ApplicationHTMLFailure(thread: thread, message: message))
    }

    private func reload() {
        document = nil; ready = false; refresh = UUID()
    }
}

private enum HTMLNavigationIntent: String { case back, settings }

private typealias HTMLViewRepresentable = NSViewRepresentable

@MainActor
private struct HTMLWebDocument: HTMLViewRepresentable {
    let document: ApplicationHTMLDocument
    let thread: ApplicationThreadRef
    let theme: PluginTheme
    let suppressed: Bool
    let locale: JSONText
    let zoomPreferencesURL: URL?
    let preloader: NativeApplicationHTMLPreloader?
    let openExternal: @MainActor (URL) async throws -> Void
    let onReady: () -> Void
    let onFailure: (String) -> Void
    let onNavigation: (HTMLNavigationIntent) -> Void
    let onPresentation: (Bool) -> Void
    let onHover: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> HTMLDocumentContainer {
        let container = HTMLDocumentContainer()
        context.coordinator.install(in: container)
        return container
    }

    func updateNSView(_ view: HTMLDocumentContainer, context: Context) {
        context.coordinator.input = self
        view.onHover = onHover
        view.suppressed = suppressed
        (view.documentView as? HTMLDocumentWebView)?.applyAppearance(theme)
    }

    static func dismantleNSView(_ view: HTMLDocumentContainer, coordinator: Coordinator) {
        coordinator.dispose()
        view.releaseDocument()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var input: HTMLWebDocument
        private weak var webView: WKWebView?
        private var active = true
        private var disposed = false
        private var preloader: NativeApplicationHTMLPreloader?
        private var warmupNavigation: WKNavigation?
        private let documentURL: URL
        private static let world = WKContentWorld.world(name: "Mokusei.HTML.Presentation")
        private static let handler = "presentation"

        init(_ input: HTMLWebDocument) {
            self.input = input
            documentURL = HTMLDocumentScheme.documentURL(threadID: input.thread.threadID)
        }

        func install(in container: HTMLDocumentContainer) {
            preloader = input.preloader
            let prepared = preloader?.take() ?? PreparedHTMLDocument()
            let view = prepared.view
            warmupNavigation = prepared.warmupNavigation
            view.stopLoading()
            prepared.scheme.bind(url: documentURL, html: input.document.html)
            let controller = view.configuration.userContentController
            // This content world is inaccessible to document scripts. Its only
            // messages are validated presentation observations and real keys.
            controller.add(self, contentWorld: Self.world, name: Self.handler)
            controller.addUserScript(WKUserScript(source: Self.observerScript,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
            view.zoomPreferences = HTMLZoomPreferences.shared(at: input.zoomPreferencesURL)
            view.restoreZoom(for: documentURL)
            view.navigationDelegate = self; view.uiDelegate = self
            view.applyAppearance(input.theme)
            view.setDocumentAccessibilityLabel(input.locale.string.hasPrefix("en") ? "HTML document" : "HTML 文档")
            webView = view
            container.onHover = input.onHover
            container.suppressed = input.suppressed
            // A hidden, idle prewarmed WebKit page is throttled. Attach it to
            // the document portal and establish its viewport before loading.
            container.onDocumentVisible = { [weak view, documentURL] in
                view?.load(URLRequest(url: documentURL))
            }
            container.documentView = view
        }

        func dispose() {
            guard !disposed else { return }
            disposed = true; active = false
            webView?.navigationDelegate = nil; webView?.uiDelegate = nil
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handler, contentWorld: Self.world)
            webView?.configuration.userContentController.removeAllUserScripts()
            webView?.stopLoading(); webView = nil
            preloader?.documentDidClose(); preloader = nil
            warmupNavigation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard owns(webView), warmupNavigation == nil || navigation !== warmupNavigation else { return }; input.onReady()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard owns(webView), warmupNavigation == nil || navigation !== warmupNavigation, let url = webView.url else { return }
            (webView as? HTMLDocumentWebView)?.restoreZoom(for: url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard warmupNavigation == nil || navigation !== warmupNavigation else { return }
            failed(webView, error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard warmupNavigation == nil || navigation !== warmupNavigation else { return }
            failed(webView, error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard owns(webView) else { return }
            active = false
            input.onFailure(input.locale.string.hasPrefix("en")
                ? "The HTML document process exited. Retry to reopen the document."
                : "HTML 文档进程已退出，请重试以重新打开文档。")
        }

        private func failed(_ view: WKWebView, _ error: Error) {
            let error = error as NSError
            guard owns(view), !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
            active = false
            input.onFailure(error.localizedDescription)
        }

        private func owns(_ view: WKWebView) -> Bool { active && webView === view }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard owns(webView), let url = action.request.url else { decisionHandler(.cancel); return }
            guard permitDirectAddress(url) else { decisionHandler(.cancel); return }
            if action.targetFrame == nil {
                decisionHandler(.cancel)
                openExternal(url)
            } else {
                decisionHandler(HTMLDocumentScheme.matches(url, documentURL) || Self.isHTTP(url) ? .allow : .cancel)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard owns(webView), action.targetFrame == nil, let url = action.request.url else { return nil }
            openExternal(url); return nil
        }

        private func openExternal(_ url: URL) {
            guard active, !input.suppressed, Self.isHTTP(url), permitDirectAddress(url) else { return }
            let open = input.openExternal
            // Match the desktop document surface: rejected OS link opens do not
            // turn a successfully loaded document into a failed session.
            Task { [weak self] in
                guard let self, self.active, !self.input.suppressed else { return }
                try? await open(url)
            }
        }

        private func permitDirectAddress(_ url: URL) -> Bool {
            return true
        }

        private static func isHTTP(_ url: URL) -> Bool { url.scheme == "http" || url.scheme == "https" }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, let view = message.webView, owns(view), message.frameInfo.isMainFrame,
                  message.name == Self.handler, message.world == Self.world,
                  let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
            if event == "presentation", Set(body.keys) == ["event", "hidden"],
               let hidden = body["hidden"] as? Bool {
                input.onPresentation(hidden)
            } else if event == "navigation", !input.suppressed, Set(body.keys) == ["event", "intent"],
                      let name = body["intent"] as? String, let intent = HTMLNavigationIntent(rawValue: name) {
                input.onNavigation(intent)
            }
        }

        private static let observerScript = #"""
        (() => {
          const send = value => window.webkit.messageHandlers.presentation.postMessage(value);
          if (location.protocol === 'mokusei-html:') {
            const root = document.documentElement;
            root.style.setProperty('--mokusei-safe-area-top', '74px', 'important');
            root.style.setProperty('--mokusei-safe-area-left', '160px', 'important');
            const style = document.createElement('style');
            style.textContent = `
              html { color-scheme: light dark; scroll-padding-top: var(--mokusei-safe-area-top); }
              body { margin: 0 !important; }
              body > [data-mokusei-html-content], body:not(:has(> [data-mokusei-html-content])) {
                box-sizing: border-box !important;
                padding-block-start: max(var(--mokusei-safe-area-top), var(--mokusei-html-top-space, 0px)) !important;
              }`;
            (document.head || root).append(style);
            let hidden = false;
            const present = () => send({event: 'presentation', hidden});
            const scroll = target => {
              const top = target?.scrollTop ?? 0;
              const next = hidden ? top > 40 : top > 80;
              if (next !== hidden) { hidden = next; present(); }
            };
            document.addEventListener('scroll', event => {
              if (!event.isTrusted) return;
              if (event.target === document) scroll(document.scrollingElement);
              else if (event.target instanceof HTMLElement) {
                const rect = event.target.getBoundingClientRect();
                if (rect.width >= innerWidth / 2 && rect.height >= innerHeight / 2 && rect.top < innerHeight && rect.bottom > 0) scroll(event.target);
              }
            }, {capture: true, passive: true});
            scroll(document.scrollingElement); present();
          }
          setTimeout(() => window.addEventListener('keydown', event => {
            if (!event.isTrusted || event.defaultPrevented || event.isComposing) return;
            let intent;
            if (event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey && event.key === ',') intent = 'settings';
            else if (!event.metaKey && !event.ctrlKey && !event.shiftKey && (event.key === 'Escape' || (event.altKey && event.key === 'ArrowLeft'))) {
              if (event.target instanceof Element && event.target.closest('input, textarea, select, [contenteditable="true"], [role="dialog"], [inert]')) return;
              intent = 'back';
            }
            if (intent) { event.preventDefault(); send({event: 'navigation', intent}); }
          }), 0);
        })();
        """#
    }
}

/// Serves exactly one in-memory document. Neither local files nor domain IPC
/// are addressable through the custom scheme.
@MainActor
private final class HTMLDocumentScheme: NSObject, WKURLSchemeHandler {
    private var url: URL?
    private var data: Data?

    func bind(url: URL, html: JSONText) {
        precondition(self.url == nil, "An isolated HTML view can serve only one document")
        self.url = url; data = Data(html.string.utf8)
    }

    static func documentURL(threadID: JSONText) -> URL {
        // Node's createHash(...).update(string) repairs lone UTF-16 surrogates
        // to U+FFFD before UTF-8 encoding, exactly like JSONText.string.
        let hostname = SHA256.hash(data: Data(threadID.string.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "mokusei-html://\(hostname)/")!
    }

    static func matches(_ candidate: URL, _ document: URL) -> Bool {
        candidate.scheme == document.scheme && candidate.host == document.host && candidate.path == "/" &&
            candidate.user == nil && candidate.password == nil && candidate.port == nil
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url, let data, let requested = urlSchemeTask.request.url, Self.matches(requested, url) else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return
        }
        urlSchemeTask.didReceive(URLResponse(url: requested, mimeType: "text/html", expectedContentLength: data.count,
                                           textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

private struct HTMLPreloaderKey: EnvironmentKey {
    static let defaultValue: NativeApplicationHTMLPreloader? = nil
}

extension EnvironmentValues {
    var nativeHTMLPreloader: NativeApplicationHTMLPreloader? {
        get { self[HTMLPreloaderKey.self] }
        set { self[HTMLPreloaderKey.self] = newValue }
    }
}

/// Keeps at most one empty WebKit session ready. Used documents never return to
/// this slot: their scripts, storage and content are released when closed.
@MainActor
final class NativeApplicationHTMLPreloader {
    private var enabled = false
    private var documents = 0
    private var spare: PreparedHTMLDocument?
    private var preparation: Task<Void, Never>?

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled { schedule() }
        else {
            preparation?.cancel(); preparation = nil
            spare?.view.stopLoading(); spare = nil
        }
    }

    fileprivate func take() -> PreparedHTMLDocument {
        preparation?.cancel(); preparation = nil
        documents += 1
        let prepared = spare.flatMap { $0.usable ? $0 : nil } ?? PreparedHTMLDocument()
        spare = nil
        return prepared
    }

    fileprivate func documentDidClose() {
        documents -= 1
        schedule()
    }

    private func schedule() {
        guard enabled, documents == 0, spare == nil, preparation == nil else { return }
        preparation = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard let self, self.enabled, self.documents == 0 else { return }
            self.preparation = nil
            let prepared = PreparedHTMLDocument()
            self.spare = prepared
            prepared.warmup()
        }
    }
}

@MainActor
private final class PreparedHTMLDocument: NSObject, WKNavigationDelegate {
    let scheme = HTMLDocumentScheme()
    let view: HTMLDocumentWebView
    var warmupNavigation: WKNavigation?
    private(set) var usable = true

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(scheme, forURLScheme: "mokusei-html")
        view = HTMLDocumentWebView(frame: .zero, configuration: configuration)
        super.init()
    }

    func warmup() {
        view.navigationDelegate = self
        warmupNavigation = view.loadHTMLString("<!doctype html><html><head></head><body></body></html>", baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { usable = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { usable = false }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { usable = false }
}

/// Detaching the web view removes its compositor and accessibility subtree,
/// while retaining the isolated document session for an unobscured return.
@MainActor
final class HTMLDocumentContainer: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var suppressed = false { didSet { synchronizeVisibility() } }
    var documentView: WKWebView? { didSet { synchronizeVisibility() } }
    var onDocumentVisible: (() -> Void)?
    private var revealTracking: NSTrackingArea?
    private let documentViewport = HTMLDocumentViewport()
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        documentViewport.identifier = NSUserInterfaceItemIdentifier("mokusei-report-document-portal")
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        synchronizeVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); observeAncestorGeometry(); synchronizeVisibility()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview(); observeAncestorGeometry()
    }

    private func observeAncestorGeometry() {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard window != nil else { restoreClientFocus(); documentViewport.removeFromSuperview(); return }
        var ancestor = superview
        while let view = ancestor {
            view.postsBoundsChangedNotifications = true; view.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(ancestorGeometryChanged(_:)), name: name, object: view)
            }
            ancestor = view.superview
        }
        needsLayout = true
    }

    @objc private func ancestorGeometryChanged(_ notification: Notification) {
        // Ancestor scrolling changes portal coordinates, not this anchor's
        // layout. Synchronize immediately to preserve hit geometry without
        // forcing a fresh AppKit subtree layout for every notification.
        synchronizeVisibility(); updateTrackingAreas()
    }

    private func synchronizeDocumentGeometry() {
        guard let documentView, documentView.superview === documentViewport else { return }
        guard window != nil else { documentViewport.removeFromSuperview(); return }
        // Stay inside the SwiftUI-owned reading page, inheriting its scale and transition.
        documentViewport.frame = bounds
        documentViewport.bounds = CGRect(origin: .zero, size: bounds.size)
        documentView.frame = documentViewport.bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        var reveal = NSRect(x: 0, y: 0, width: min(160, bounds.width), height: min(74, bounds.height))
        if let root = window?.contentView {
            let native = CGRect(x: 0, y: root.isFlipped ? 0 : root.bounds.height - 74, width: 160, height: 74)
            reveal = convert(native, from: root).intersection(bounds)
        }
        if revealTracking?.rect == reveal { return }
        if let revealTracking { removeTrackingArea(revealTracking) }
        let tracking = NSTrackingArea(rect: reveal,
            options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking); revealTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { if !suppressed { onHover(true) } }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    func releaseDocument() {
        onDocumentVisible = nil
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        restoreClientFocus()
        documentView?.stopLoading(); documentView?.removeFromSuperview(); documentView = nil
        documentViewport.removeFromSuperview()
        onHover = { _ in }
    }

    private func synchronizeVisibility() {
        guard let documentView else { return }
        let visible = !suppressed && bounds.width.rounded() > 0 && bounds.height.rounded() > 0
        if visible {
            documentView.isHidden = false
            if documentView.superview !== documentViewport { documentViewport.addSubview(documentView) }
            if window != nil {
                let parent = self
                if documentViewport.superview !== parent {
                    let navigation = parent.subviews.first { $0.identifier?.rawValue == "mokusei-report-navigation-portal" }
                    if let navigation { parent.addSubview(documentViewport, positioned: .below, relativeTo: navigation) }
                    else { parent.addSubview(documentViewport) }
                }
            }
            synchronizeDocumentGeometry()
            if documentView.window != nil, documentView.bounds.width > 0, documentView.bounds.height > 0,
               let onDocumentVisible {
                self.onDocumentVisible = nil
                onDocumentVisible()
            }
        } else {
            restoreClientFocus()
            documentView.isHidden = true; documentView.removeFromSuperview(); documentView.frame = .zero
            documentViewport.removeFromSuperview()
        }
    }

    private func restoreClientFocus() {
        guard let documentView, let window = documentView.window,
              let responder = window.firstResponder as? NSView,
              responder === documentView || responder.isDescendant(of: documentView) else { return }
        window.makeFirstResponder(window.contentView)
    }
}

@MainActor
private final class HTMLDocumentViewport: NSView {
    override var isFlipped: Bool { true }
}

/// The source Report navigation is another independent native view, with a
/// 148×58 DIP interaction area around the 132×42 control at window (12, 16).
/// Keep the portal inside its representable so SwiftUI owns its stacking and
/// hit testing alongside the document, including during reading-page motion.
@MainActor
private struct HTMLNavigationPortal: NSViewRepresentable {
    @Environment(\.nativeWindowContentScale) private var contentScale
    let content: AnyView
    let collapsed: Bool
    let suppressed: Bool
    let zoomPreferencesURL: URL?
    let onBack: () -> Void
    let onSettings: () -> Void
    func makeNSView(context: Context) -> HTMLNavigationAnchor { HTMLNavigationAnchor() }
    func updateNSView(_ view: HTMLNavigationAnchor, context: Context) {
        view.update(content: content, collapsed: collapsed, suppressed: suppressed, contentScale: contentScale,
                    preferences: HTMLZoomPreferences.shared(at: zoomPreferencesURL), onBack: onBack, onSettings: onSettings)
    }
    static func dismantleNSView(_ view: HTMLNavigationAnchor, coordinator: ()) { view.release() }
}

@MainActor
private final class HTMLNavigationAnchor: NSView {
    private let portal = HTMLNavigationViewport()
    private var suppressed = true
    private var collapsed = false
    private var contentScale: CGFloat = 1
    private weak var buttonWindow: NSWindow?
    private var offset: CGFloat = 0
    private var offsetFrom: CGFloat = 0
    private var offsetTarget: CGFloat = 0
    private var offsetStarted: CFTimeInterval = 0
    private var animationTimer: Timer?
    private var released = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !suppressed, !collapsed else { return nil }
        guard let hit = super.hitTest(point), hit !== self else { return nil }
        return hit
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        portal.identifier = NSUserInterfaceItemIdentifier("mokusei-report-navigation-portal")
    }
    required init?(coder: NSCoder) { nil }

    func update(content: AnyView, collapsed: Bool, suppressed: Bool, contentScale: CGFloat,
                preferences: HTMLZoomPreferences, onBack: @escaping () -> Void, onSettings: @escaping () -> Void) {
        let changed = self.collapsed != collapsed
        self.collapsed = collapsed; self.suppressed = suppressed; self.contentScale = contentScale
        portal.update(content: content, unavailable: collapsed || suppressed, preferences: preferences,
                      onBack: onBack, onSettings: onSettings)
        synchronize(animate: changed)
    }
    override func layout() { super.layout(); synchronize(animate: false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification]
            for name in names {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
            }
        }
        synchronize(animate: false)
    }
    @objc private func windowChanged(_ notification: Notification) {
        // Reapply portal geometry after AppKit finishes window layout. The
        // window-control bridge retains this Report's offset during its layout.
        DispatchQueue.main.async { [weak self] in self?.synchronize(animate: false) }
    }

    private func synchronize(animate: Bool) {
        guard !released, !suppressed, bounds.width.rounded() > 0, bounds.height.rounded() > 0,
              let window, window.contentView != nil else {
            stopAnimation(); restoreNativeButtons(); detachPortal(); return
        }
        if buttonWindow !== window { restoreNativeButtons(); buttonWindow = window }
        let target = collapsed ? NativeWindowNavigationGeometry.hiddenOffset : 0
        if !animate && animationTimer == nil {
            stopAnimation(); offset = target; offsetTarget = target
        } else if target != offsetTarget {
            offsetFrom = offset; offsetTarget = target; offsetStarted = CACurrentMediaTime()
            if animationTimer == nil {
                let timer = Timer(timeInterval: NativeFrameRate.interval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                RunLoop.main.add(timer, forMode: .common); animationTimer = timer
            }
        }
        publish()
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - offsetStarted
        offset = NativeWindowNavigationPresentation.scrollOffset(from: offsetFrom, to: offsetTarget, elapsed: elapsed)
        synchronize(animate: false)
        if elapsed >= NativeWindowNavigationPresentation.scrollDuration { stopAnimation() }
    }

    private func publish() {
        guard let window = buttonWindow, let root = window.contentView else { return }
        NativeWindowControlPlacement.setReadingOffset(offset, in: window)
        let top = 8 + offset
        let parent = self
        let native = CGRect(x: 4 / contentScale, y: top / contentScale,
                            width: 148 / contentScale, height: 58 / contentScale)
        portal.frame = native
        portal.bounds = CGRect(x: 0, y: 0, width: 148, height: 58)
        if collapsed && offset <= NativeWindowNavigationGeometry.hiddenOffset {
            detachPortal(focusDocument: true); return
        }
        if portal.superview !== parent {
            parent.addSubview(portal)
            // Electron focuses the navigation WebContents on initial open and
            // when returning from the client, but never steals document focus.
            var client = superview
            while let view = client, view.identifier?.rawValue != "mokusei-native-content-viewport" { client = view.superview }
            let responder = window.firstResponder as? NSView
            if responder == nil || responder === root || responder === client ||
                (client.map { responder?.isDescendant(of: $0) == true } ?? false) {
                window.makeFirstResponder(portal)
            }
        }
    }
    private func stopAnimation() { animationTimer?.invalidate(); animationTimer = nil }
    private func restoreNativeButtons() {
        if let buttonWindow { NativeWindowControlPlacement.setReadingOffset(0, in: buttonWindow) }
        buttonWindow = nil
        offset = 0; offsetTarget = 0
    }
    private func detachPortal(focusDocument: Bool = false) {
        if portal.ownsFocus, let window = portal.window, let root = window.contentView {
            let document = focusDocument ? reportDocument(in: root) : nil
            window.makeFirstResponder(document ?? root)
        }
        portal.removeFromSuperview()
    }
    private func reportDocument(in view: NSView) -> NSView? {
        if let container = view as? HTMLDocumentContainer, !container.suppressed { return container.documentView }
        return view.subviews.lazy.compactMap { self.reportDocument(in: $0) }.first
    }
    func release() {
        released = true; stopAnimation(); restoreNativeButtons()
        NotificationCenter.default.removeObserver(self)
        detachPortal(); portal.release()
    }
}

/// The production renderer's html-navigation.html has a different file URL
/// from index.html, so Chromium persists its zoom independently. The compiled
/// native client has no Electron development renderer origin to share.
@MainActor
private final class HTMLNavigationViewport: NSView {
    private let scaleView = HTMLDocumentViewport()
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var content = AnyView(EmptyView())
    private var preferences: HTMLZoomPreferences?
    private var unavailable = true
    private var generation = UUID()
    private var zoomLevel: Double = 0
    private var renderedSize = NSSize(width: -1, height: -1)
    private var onBack: () -> Void = {}
    private var onSettings: () -> Void = {}
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !unavailable }
    var ownsFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Liquid Glass casts a shadow beyond the old 8-point CSS shadow inset.
        // Let it draw outside the portal without enlarging its hit-test bounds.
        wantsLayer = true; clipsToBounds = false
        hosting.sizingOptions = []
        // The portal already owns its window-relative bounds and padding.
        // Applying the titlebar safe area again pushes the capsule out of view.
        hosting.safeAreaRegions = []
        addSubview(scaleView); scaleView.addSubview(hosting)
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !unavailable, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    func update(content: AnyView, unavailable: Bool, preferences: HTMLZoomPreferences,
                onBack: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.content = content; self.unavailable = unavailable
        self.preferences = preferences; self.zoomLevel = preferences.navigationLevel
        self.onBack = onBack; self.onSettings = onSettings
        updateContents(force: true)
    }

    override func layout() { super.layout(); updateContents() }

    private func updateContents(force: Bool = false) {
        let factor = HTMLZoomPreferences.visibleFactor(zoomLevel)
        scaleView.frame = bounds
        scaleView.setBoundsSize(NSSize(width: bounds.width / factor, height: bounds.height / factor))
        hosting.frame = scaleView.bounds
        guard force || renderedSize != scaleView.bounds.size else { return }
        renderedSize = scaleView.bounds.size
        hosting.rootView = AnyView(content.padding(8)
            .frame(width: scaleView.bounds.width, height: scaleView.bounds.height, alignment: .topLeading)
            .id(generation).accessibilityHidden(unavailable)
            .allowsHitTesting(!unavailable).disabled(unavailable))
    }

    override func mouseDown(with event: NSEvent) { if !unavailable { window?.makeFirstResponder(self) } }
    override func keyDown(with event: NSEvent) {
        guard !unavailable else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command && event.charactersIgnoringModifiers == "," { onSettings() }
        else if modifiers.isEmpty && event.keyCode == 53 || modifiers == .option && event.keyCode == 123 { onBack() }
        else { super.keyDown(with: event) }
    }

    @objc func mokuseiReloadFocusedWebContent(_ sender: Any?) { remount() }
    @objc func mokuseiForceReloadFocusedWebContent(_ sender: Any?) { remount() }
    @objc func mokuseiResetFocusedWebContentZoom(_ sender: Any?) { setZoomLevel(0) }
    @objc func mokuseiZoomInFocusedWebContent(_ sender: Any?) { setZoomLevel(zoomLevel + 0.5) }
    @objc func mokuseiZoomOutFocusedWebContent(_ sender: Any?) { setZoomLevel(zoomLevel - 0.5) }

    private func remount() {
        guard !unavailable else { return }
        generation = UUID(); updateContents(force: true)
        window?.makeFirstResponder(self)
    }
    private func setZoomLevel(_ level: Double) {
        guard !unavailable, level.isFinite else { return }
        zoomLevel = level; preferences?.setNavigationLevel(level); updateContents()
    }
    func release() {
        content = AnyView(EmptyView()); hosting.rootView = content
        onBack = {}; onSettings = {}; preferences = nil
    }
}


/// The Report partition keys zoom by hostname, ignoring scheme and port.
/// Keep unbounded levels so reversing repeated clicks at a visible limit has
/// the same behavior as Electron. Only the rendered factor is clamped.
@MainActor
private final class HTMLZoomPreferences {
    private struct Saved: Codable {
        var hosts: [String: Double] = [:]
        var navigationLevel: Double = 0
    }
    private static var stores: [String: HTMLZoomPreferences] = [:]
    private let url: URL?
    private var saved: Saved
    var navigationLevel: Double { saved.navigationLevel }

    static func shared(at url: URL?) -> HTMLZoomPreferences {
        let key = url?.standardizedFileURL.absoluteString ?? "memory"
        if let existing = stores[key] { return existing }
        let result = HTMLZoomPreferences(url: url); stores[key] = result
        return result
    }
    private init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = decoded
            saved.hosts = saved.hosts.filter { $0.value.isFinite }
            if !saved.navigationLevel.isFinite { saved.navigationLevel = 0 }
        } else { saved = Saved() }
    }
    static func visibleFactor(_ level: Double) -> Double { min(5, max(0.25, pow(1.2, level))) }
    func level(for hostname: String) -> Double { saved.hosts[hostname.lowercased()] ?? 0 }
    func setLevel(_ level: Double, for hostname: String) {
        guard level.isFinite, !hostname.isEmpty else { return }
        saved.hosts[hostname.lowercased()] = level; persist()
    }
    func setNavigationLevel(_ level: Double) {
        guard level.isFinite else { return }
        saved.navigationLevel = level; persist()
    }
    private func persist() {
        guard let url, let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }
}

/// Focused document commands stay within the isolated WebKit session.
@MainActor
private final class HTMLDocumentWebView: WKWebView {
    private var documentZoomLevel: Double = 0
    private var zoomHostname = ""
    var zoomPreferences: HTMLZoomPreferences?

    func applyAppearance(_ theme: PluginTheme) {
        appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
    }

    func setDocumentAccessibilityLabel(_ label: String) {
        setAccessibilityLabel(label)
    }

    func restoreZoom(for url: URL) {
        zoomHostname = url.host?.lowercased() ?? ""
        documentZoomLevel = zoomPreferences?.level(for: zoomHostname) ?? 0
        pageZoom = HTMLZoomPreferences.visibleFactor(documentZoomLevel)
    }


    @objc func mokuseiReloadFocusedWebContent(_ sender: Any?) { reload() }
    @objc func mokuseiForceReloadFocusedWebContent(_ sender: Any?) { reloadFromOrigin() }
    @objc func mokuseiResetFocusedWebContentZoom(_ sender: Any?) { setDocumentZoomLevel(0) }
    @objc func mokuseiZoomInFocusedWebContent(_ sender: Any?) { setDocumentZoomLevel(documentZoomLevel + 0.5) }
    @objc func mokuseiZoomOutFocusedWebContent(_ sender: Any?) { setDocumentZoomLevel(documentZoomLevel - 0.5) }

    private func setDocumentZoomLevel(_ level: Double) {
        guard level.isFinite else { return }
        documentZoomLevel = level
        zoomPreferences?.setLevel(level, for: zoomHostname)
        pageZoom = HTMLZoomPreferences.visibleFactor(level)
    }
}
