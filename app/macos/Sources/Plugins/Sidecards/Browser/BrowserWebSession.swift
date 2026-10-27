import AppKit
import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import WebKit

/// Owns one WKWebView and all callbacks. No page message bridge has runtime,
/// attachment, filesystem, or Thread authority.
@MainActor @Observable
final class BrowserWebSession: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: BrowserWKWebView
    var url = ""
    var title = ""
    var pendingURL: URL?
    var loading = false
    var ready = false
    var canGoBack = false
    var canGoForward = false
    var error: String?
    var terminated = false
    var annotating = false
    var selection: BrowserSelection?
    var comment = ""
    var captureError = ""
    var capturing = false
    var suppressed = true
    @ObservationIgnored var backToOverview: (() -> Void)?
    @ObservationIgnored var onAnnotation: ((BrowserPendingAnnotation) -> Void)?
    @ObservationIgnored weak var viewport: BrowserViewportNativeView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var annotationTask: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var annotationGeneration = 0
    @ObservationIgnored private var activeNavigation: WKNavigation?
    @ObservationIgnored private let navigationGenerations = NSMapTable<WKNavigation, NSNumber>.weakToStrongObjects()
    @ObservationIgnored private var historyStartPending = false
    @ObservationIgnored private var documentResponseOK = false
    @ObservationIgnored private var receivedDocumentResponse = false
    @ObservationIgnored private var historyResponses: [WKBackForwardListItem: Int] = [:]
    @ObservationIgnored private var documentStatus = 0
    @ObservationIgnored private var completedDocumentURL: URL?
    @ObservationIgnored private var sameDocumentCandidate = false
    @ObservationIgnored private var released = false
    @ObservationIgnored private var keyboardMonitor: Any?
    @ObservationIgnored private var snapshotBusy = false
    @ObservationIgnored private var snapshots: [(WKSnapshotConfiguration, CheckedContinuation<NativePlatformImage, Error>)] = []
    @ObservationIgnored private var activeSnapshot: (UUID, CheckedContinuation<NativePlatformImage, Error>)?
    @ObservationIgnored private var pageDialog: BrowserPageDialog?
    @ObservationIgnored private var cancellingPageDialog = false

    init(store: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(WKUserScript(source: BrowserPageScripts.permissionDenial, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        configuration.userContentController.addUserScript(WKUserScript(source: BrowserPageScripts.scrollbar, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .world(name: "MokuseiBrowser")))
        webView = BrowserWKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .clear
        webView.onBackToOverview = { [weak self] in self?.backToOverview?() }
        webView.onCancelAnnotation = { [weak self] in self?.cancelAnnotation() }
        webView.onReloadDocument = { [weak self] force in self?.reloadFocusedDocument(fromOrigin: force) }
        webView.onDocumentZoomChanged = { [weak self] in
            self?.refreshSelectionAfterResize()
        }
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } }
        ]
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, !self.released, !self.suppressed, event.window === self.webView.window,
                      let responder = event.window?.firstResponder as? NSView,
                      responder === self.webView || responder.isDescendant(of: self.webView),
                      (responder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let escape = event.keyCode == 53 && flags.intersection([.command, .control, .shift]).isEmpty
                let back = event.keyCode == 123 && flags == .option
                if escape && self.annotating { self.cancelAnnotation(); return true }
                if escape || back { self.webView.window?.makeFirstResponder(nil); self.backToOverview?(); return true }
                return false
            }
            return consumed ? nil : event
        }
    }

    func navigate(_ target: URL) {
        guard !released else { return }
        begin(target, allowSameDocument: true)
        remember(webView.load(URLRequest(url: target)))
    }
    private func begin(_ target: URL?, allowSameDocument: Bool = false) {
        generation += 1
        cancelPageDialog()
        historyStartPending = false
        cancelAnnotation()
        pendingURL = target; loading = true; ready = false; error = nil
        sameDocumentCandidate = allowSameDocument && documentResponseOK && sameDocument(target, completedDocumentURL)
        if !sameDocumentCandidate { documentResponseOK = false }
        receivedDocumentResponse = false
    }
    private func remember(_ navigation: WKNavigation?) {
        activeNavigation = navigation
        if let navigation { navigationGenerations.setObject(NSNumber(value: generation), forKey: navigation) }
    }
    func back() { guard canGoBack else { return }; begin(webView.backForwardList.backItem?.url, allowSameDocument: true); remember(webView.goBack()) }
    func forward() { guard canGoForward else { return }; begin(webView.backForwardList.forwardItem?.url, allowSameDocument: true); remember(webView.goForward()) }
    func reload() {
        if let pendingURL, error != nil { navigate(pendingURL); return }
        begin(webView.url); remember(webView.reload())
    }
    /// Application menu roles target the focused document, as Electron does;
    /// the browser toolbar's failed-target retry remains a separate action.
    private func reloadFocusedDocument(fromOrigin: Bool) {
        guard !released else { return }
        begin(webView.url)
        remember(fromOrigin ? webView.reloadFromOrigin() : webView.reload())
    }
    func retry() { if let pendingURL { navigate(pendingURL) } else { reload() } }
    func setSuppressed(_ hidden: Bool) {
        suppressed = hidden
        if hidden { cancelPageDialog() }
        viewport?.setSuppressed(hidden)
    }
    private func syncState() {
        guard !released else { return }
        if let current = webView.url, BrowserURL.absolute(current.absoluteString) != nil {
            if !url.isEmpty, current.absoluteString != url {
                if annotating { cancelAnnotation() }
                if documentResponseOK, !webView.isLoading, let item = webView.backForwardList.currentItem {
                    historyResponses[item] = documentStatus
                    let retained = Set(webView.backForwardList.backList + [item] + webView.backForwardList.forwardList)
                    historyResponses = historyResponses.filter { retained.contains($0.key) }
                }
            }
            url = current.absoluteString
        }
        title = webView.title ?? ""; canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        if !webView.isLoading, sameDocumentCandidate, webView.url == pendingURL {
            pendingURL = nil; loading = false; ready = documentResponseOK && error == nil; sameDocumentCandidate = false
        }
    }
    private func sameDocument(_ first: URL?, _ second: URL?) -> Bool {
        guard let first, let second, var a = URLComponents(url: first, resolvingAgainstBaseURL: false),
              var b = URLComponents(url: second, resolvingAgainstBaseURL: false) else { return false }
        a.fragment = nil; b.fragment = nil
        return a == b
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard !released, let target = navigationAction.request.url else { decisionHandler(.cancel); return }
        let main = navigationAction.targetFrame?.isMainFrame ?? true
        if navigationAction.shouldPerformDownload {
            if main { report("网页下载已取消") }
            decisionHandler(.cancel); return
        }
        if navigationAction.targetFrame == nil {
            // A popup POST's body is not reliably exposed by WebKit. The source
            // browser rejects these; never reconstruct it as a GET request.
            let permitted = (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET" && BrowserURL.absolute(target.absoluteString) != nil
            // Let UIDelegate receive GET popups and schedule the replacement
            // after WebKit finishes its popup decision, avoiding reentrant loads.
            decisionHandler(permitted ? .allow : .cancel)
            return
        }
        let allowed = BrowserURL.absolute(target.absoluteString) != nil || (!main && ["about:blank", "about:srcdoc"].contains(target.absoluteString))
        guard allowed else {
            if main { report("已阻止打开该地址") }
            decisionHandler(.cancel); return
        }
        if main {
            historyStartPending = navigationAction.navigationType == .backForward
            pendingURL = target; error = nil
            if documentResponseOK && sameDocument(target, completedDocumentURL) { sameDocumentCandidate = true }
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        guard navigationResponse.canShowMIMEType, !disposition.hasPrefix("attachment") else {
            if navigationResponse.isForMainFrame { report("网页下载已取消") }
            decisionHandler(.cancel); return
        }
        if navigationResponse.isForMainFrame {
            let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0
            receivedDocumentResponse = true; documentStatus = status
            documentResponseOK = (200..<300).contains(status)
            if !documentResponseOK { error = "网页响应失败（HTTP \(status)）" }
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !released else { return }
        if let navigation, let owner = navigationGenerations.object(forKey: navigation)?.intValue, owner != generation, !historyStartPending { return }
        activeNavigation = navigation
        begin(pendingURL ?? webView.url)
        if let navigation { navigationGenerations.setObject(NSNumber(value: generation), forKey: navigation) }
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        pendingURL = webView.url
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        self.webView.synchronizeDocumentZoom()
        syncState()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !released, navigation === activeNavigation else { return }
        if let item = webView.backForwardList.currentItem {
            let identity = item
            if !receivedDocumentResponse, let status = historyResponses[identity] {
                documentStatus = status; documentResponseOK = (200..<300).contains(status)
                error = documentResponseOK ? nil : "网页响应失败（HTTP \(status)）"
            }
            historyResponses[identity] = documentStatus
            let retained = Set((webView.backForwardList.backList + [item] + webView.backForwardList.forwardList))
            historyResponses = historyResponses.filter { retained.contains($0.key) }
        }
        syncState(); loading = false; ready = documentResponseOK && error == nil; pendingURL = nil
        self.webView.synchronizeDocumentZoom()
        completedDocumentURL = ready ? webView.url : nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { fail(navigation, failure) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) { fail(navigation, failure) }
    private func fail(_ navigation: WKNavigation?, _ failure: Error) {
        guard !released, navigation === activeNavigation else { return }
        let native = failure as NSError
        if native.code == NSURLErrorCancelled || (error != nil && native.domain == "WebKitErrorDomain" && native.code == 102) { return }
        loading = false; ready = false; documentResponseOK = false; error = failure.localizedDescription
        cancelAnnotation(); viewport?.setSuppressed(true)
    }
    private func report(_ message: String) {
        loading = false; ready = false; documentResponseOK = false; error = message
        cancelAnnotation(); viewport?.setSuppressed(true)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        terminated = true; report("网页进程已退出，请重试")
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET",
           let target = navigationAction.request.url, BrowserURL.absolute(target.absoluteString) != nil {
            let owner = generation
            Task { @MainActor [weak self] in
                guard let self, !self.released, self.generation == owner else { return }
                self.navigate(target)
            }
        }
        return nil
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard !released, !suppressed, pageDialog == nil, let window = webView.window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.beginSheetModal(for: window, completionHandler: ownPageDialog(panel) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        })
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard !released, !suppressed, pageDialog == nil, let window = webView.window else { completionHandler(); return }
        let alert = NSAlert(); alert.messageText = String(message.prefix(4000)); alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window, completionHandler: ownPageDialog(alert.window) { _ in completionHandler() })
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard !released, !suppressed, pageDialog == nil, let window = webView.window else { completionHandler(false); return }
        let alert = NSAlert(); alert.messageText = String(message.prefix(4000)); alert.addButton(withTitle: "好"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window, completionHandler: ownPageDialog(alert.window) { completionHandler($0 == .alertFirstButtonReturn) })
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        guard !released, !suppressed, pageDialog == nil, let window = webView.window else { completionHandler(nil); return }
        let alert = NSAlert(); alert.messageText = String(prompt.prefix(4000)); alert.addButton(withTitle: "好"); alert.addButton(withTitle: "取消")
        let input = NSTextField(string: defaultText ?? ""); input.frame = CGRect(x: 0, y: 0, width: 300, height: 24); alert.accessoryView = input
        alert.beginSheetModal(for: window, completionHandler: ownPageDialog(alert.window) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) })
    }
    private func ownPageDialog(_ sheet: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) -> (NSApplication.ModalResponse) -> Void {
        let dialog = BrowserPageDialog(sheet: sheet, completion: completion)
        pageDialog = dialog
        return { [weak self, dialog] response in
            sheet.orderOut(nil)
            if self?.pageDialog === dialog, self?.cancellingPageDialog != true { self?.pageDialog = nil }
            dialog.finish(response)
        }
    }
    private func cancelPageDialog() {
        guard !cancellingPageDialog, let dialog = pageDialog else { return }
        // Keep the slot occupied while WebKit receives cancellation, so the
        // departing page cannot replace its dialog, even if its callback starts
        // another navigation or pumps AppKit's sheet completion reentrantly.
        cancellingPageDialog = true
        defer { cancellingPageDialog = false }
        dialog.cancel()
        if pageDialog === dialog { pageDialog = nil }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self; download.cancel()
        if navigationAction.targetFrame?.isMainFrame ?? true { report("网页下载已取消") }
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self; download.cancel()
        if navigationResponse.isForMainFrame { report("网页下载已取消") }
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) { completionHandler(nil); download.cancel() }

    func beginAnnotation() {
        guard !released, ready, !loading, !annotating, BrowserURL.absolute(url) != nil else { return }
        annotating = true; comment = ""; captureError = ""; annotationGeneration += 1
        webView.annotationActive = true
        if !suppressed { webView.focusDocument() }
        let token = annotationGeneration
        annotationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await self.evaluateJSON("return await (\(BrowserPageScripts.selection));")
                guard self.currentAnnotation(token), raw != .null else { if self.currentAnnotation(token) { self.cancelAnnotation() }; return }
                self.selection = try BrowserSelection(raw)
                self.viewport?.refreshEditor()
                // Escape/pagehide cancellation also dismisses the native editor.
                _ = try await self.evaluateJSON("return await (globalThis.__mokuseiAnnotationClosed ?? null);")
                if self.currentAnnotation(token) { self.cancelAnnotation() }
            } catch {
                if self.currentAnnotation(token) { self.captureError = error.localizedDescription; self.cancelAnnotation(keepError: true) }
            }
        }
    }
    private func currentAnnotation(_ token: Int) -> Bool { !released && annotating && ready && !loading && token == annotationGeneration }
    func cancelAnnotation(keepError: Bool = false) {
        let wasAnnotating = annotating
        annotationGeneration += 1; annotationTask?.cancel(); annotationTask = nil; captureTask?.cancel(); captureTask = nil
        annotating = false; selection = nil; capturing = false; webView.annotationActive = false
        if !keepError { captureError = "" }
        viewport?.refreshEditor()
        if wasAnnotating, !released {
            webView.evaluateJavaScript("globalThis.__mokuseiAnnotationCancel?.();", in: nil, in: .world(name: "MokuseiBrowser")) { _ in }
        }
    }
    func captureAnnotation() {
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty, comment.utf16.count <= 10_000, !capturing, selection != nil else { return }
        let token = annotationGeneration
        capturing = true; captureError = ""
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await self.evaluateJSON("return globalThis.__mokuseiAnnotationRead?.() ?? null;")
                guard self.currentAnnotation(token) else { return }
                let selection = try BrowserSelection(raw)
                let titleValue = try await self.evaluateJSON("return document.title.slice(0, 2048);")
                let title: JSONText
                if case let .string(text) = titleValue { title = text } else { title = "" }
                _ = try await self.evaluateJSON("await globalThis.__mokuseiAnnotationCapture?.(true); return null;")
                guard self.currentAnnotation(token) else { return }
                let size = self.webView.bounds.size
                guard size.width > 0, size.height > 0 else { throw PluginContractError("网页区域不可见") }
                let config = WKSnapshotConfiguration()
                config.rect = CGRect(origin: .zero, size: size)
                config.afterScreenUpdates = true
                let image = try await self.snapshot(config)
                guard self.currentAnnotation(token) else { return }
                let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                guard let pixels else { throw PluginContractError("截图失败") }
                let png = try await NativeRasterPreparation.shared.png(pixels)
                try Task.checkCancellation()
                guard self.currentAnnotation(token) else { return }
                guard png.count <= 20 * 1024 * 1024 else { throw PluginContractError("截图超过 20 MB") }
                self.onAnnotation?(BrowserPendingAnnotation(id: UUID(), comment: comment, url: self.url,
                    title: title, selection: selection, png: png))
                self.cancelAnnotation()
            } catch {
                guard self.currentAnnotation(token) else { return }
                _ = try? await self.evaluateJSON("await globalThis.__mokuseiAnnotationCapture?.(false); return null;")
                self.captureError = error.localizedDescription; self.capturing = false
            }
        }
    }
    func evaluateJSON(_ body: String) async throws -> JSONValue {
        // Serialize inside the isolated world so Swift receives lossless UTF-16
        // JSON instead of lossy Foundation dictionaries for page text.
        let wrapped = "return JSON.stringify(await (async () => { \(body) })()) ?? 'null';"
        let raw = try await webView.callAsyncJavaScript(wrapped, arguments: [:], in: nil, contentWorld: .world(name: "MokuseiBrowser"))
        guard let raw = raw as? String else { return .null }
        return try JSONValue(data: Data(raw.utf8))
    }
    func refreshSelectionAfterResize() {
        guard selection != nil, annotating, !capturing else { return }
        let token = annotationGeneration
        Task { [weak self] in
            guard let self, let raw = try? await self.evaluateJSON("return globalThis.__mokuseiAnnotationRead?.() ?? null;"), self.currentAnnotation(token) else { return }
            guard let selection = try? BrowserSelection(raw) else { self.cancelAnnotation(); return }
            self.selection = selection
            self.viewport?.refreshEditor()
        }
    }
    private func snapshot(_ configuration: WKSnapshotConfiguration) async throws -> NativePlatformImage {
        guard !released else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            snapshots.append((configuration, continuation))
            runNextSnapshot()
        }
    }
    private func runNextSnapshot() {
        guard !snapshotBusy, !snapshots.isEmpty else { return }
        let (configuration, continuation) = snapshots.removeFirst()
        let id = UUID()
        activeSnapshot = (id, continuation)
        snapshotBusy = true
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            guard let self, let active = self.activeSnapshot, active.0 == id else { return }
            self.activeSnapshot = nil
            let continuation = active.1
            if let error { continuation.resume(throwing: error) }
            else if !self.released, let image { continuation.resume(returning: image) }
            else { continuation.resume(throwing: CancellationError()) }
            self.snapshotBusy = false
            self.runNextSnapshot()
        }
    }
    func release() {
        guard !released else { return }
        cancelAnnotation(); released = true; generation += 1
        cancelPageDialog()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        observations.removeAll()
        navigationGenerations.removeAllObjects(); historyResponses.removeAll()
        let abandoned = snapshots; snapshots.removeAll()
        for (_, continuation) in abandoned { continuation.resume(throwing: CancellationError()) }
        activeSnapshot?.1.resume(throwing: CancellationError()); activeSnapshot = nil; snapshotBusy = false
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.onBackToOverview = nil; webView.onCancelAnnotation = nil
        webView.onReloadDocument = nil; webView.onDocumentZoomChanged = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.removeFromSuperview(); viewport?.setSuppressed(true); viewport = nil
        backToOverview = nil; onAnnotation = nil
    }
}

/// Sheets belong to the page session, not the host window. Retiring a page must
/// resolve WebKit's callback even if AppKit delivers its sheet completion later.
@MainActor
private final class BrowserPageDialog {
    private let sheet: NSWindow
    private var completion: ((NSApplication.ModalResponse) -> Void)?

    init(sheet: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        self.sheet = sheet; self.completion = completion
    }
    func finish(_ response: NSApplication.ModalResponse) {
        let action = completion
        completion = nil
        action?(response)
    }
    func cancel() {
        guard completion != nil else { return }
        // Complete with cancellation before ending the sheet: a queued OK
        // response must never deliver selected files to a retired page.
        finish(.cancel)
        if let panel = sheet as? NSSavePanel { panel.cancel(nil) }
        else { sheet.sheetParent?.endSheet(sheet, returnCode: .cancel) }
        sheet.orderOut(nil)
    }
}

@MainActor
final class BrowserWKWebView: WKWebView {
    var onBackToOverview: (() -> Void)?
    var onCancelAnnotation: (() -> Void)?
    var onReloadDocument: ((Bool) -> Void)?
    var onDocumentZoomChanged: (() -> Void)?
    var annotationActive = false
    private(set) var documentZoomLevel: Double = 0
    var rawDocumentZoomFactor: CGFloat { CGFloat(pow(1.2, documentZoomLevel)) }
    private let zoomMemory: BrowserDocumentZoomMemory

    override init(frame frameRect: CGRect, configuration: WKWebViewConfiguration) {
        zoomMemory = BrowserRunSessions.documentZoomMemory(for: configuration.websiteDataStore)
        super.init(frame: frameRect, configuration: configuration)
    }
    required init?(coder: NSCoder) { nil }

    func synchronizeDocumentZoom() {
        guard let hostname = url?.host?.lowercased() else { return }
        applyDocumentZoom(zoomMemory.levels[hostname] ?? 0)
    }

    // These AppKit selectors are intentionally shared by name, without giving
    // the application host any dependency on a concrete browser plugin type.
    @objc func mokuseiReloadFocusedWebContent(_ sender: Any?) { onReloadDocument?(false) }
    @objc func mokuseiForceReloadFocusedWebContent(_ sender: Any?) { onReloadDocument?(true) }
    @objc func mokuseiResetFocusedWebContentZoom(_ sender: Any?) { setDocumentZoomLevel(0) }
    @objc func mokuseiZoomInFocusedWebContent(_ sender: Any?) { setDocumentZoomLevel(documentZoomLevel + 0.5) }
    @objc func mokuseiZoomOutFocusedWebContent(_ sender: Any?) { setDocumentZoomLevel(documentZoomLevel - 0.5) }

    private func setDocumentZoomLevel(_ level: Double) {
        guard level.isFinite else { return }
        // Keep the unbounded accumulated level, including clicks beyond the
        // visible limit, so reversal follows the same menu-role arithmetic.
        if let hostname = url?.host?.lowercased() { zoomMemory.levels[hostname] = level }
        applyDocumentZoom(level)
    }
    private func applyDocumentZoom(_ level: Double) {
        guard documentZoomLevel != level || pageZoom != min(5, max(0.25, pow(1.2, level))) else { return }
        documentZoomLevel = level
        pageZoom = min(5, max(0.25, pow(1.2, level)))
        onDocumentZoomChanged?()
    }

    func focusDocument() {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let escape = event.keyCode == 53 && flags.intersection([.command, .control, .shift]).isEmpty
        let back = event.keyCode == 123 && flags == .option
        if escape && annotationActive { onCancelAnnotation?(); return }
        if escape || back { window?.makeFirstResponder(nil); onBackToOverview?(); return }
        super.keyDown(with: event)
    }
}
