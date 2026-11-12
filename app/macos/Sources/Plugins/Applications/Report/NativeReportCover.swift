import AppKit
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI
import WebKit

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
    @State private var localCache = NativeReportCoverCache()
    @Environment(\.nativeReportCoverCache) private var sharedCache
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let key = NativeReportCoverCache.Key(source: .init(pluginID: "report", queryID: "report.cover",
            input: props.entry.ref.json, contentRevision: props.entry.view.coverRevision), dark: colorScheme == .dark)
        ReportCoverSession(props: props, key: key, cache: sharedCache ?? localCache).id(key)
    }
}

private struct ReportCoverSession: View {
    let props: ApplicationThreadProps<NativeReportView>
    let key: NativeReportCoverCache.Key
    let cache: NativeReportCoverCache
    @State private var document: ApplicationHTMLDocument?
    @State private var image: NSImage?
    @State private var ready = false
    @State private var failure: String?

    init(props: ApplicationThreadProps<NativeReportView>, key: NativeReportCoverCache.Key, cache: NativeReportCoverCache) {
        self.props = props; self.key = key; self.cache = cache
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
                ReportCoverHTML(html: document.html.string, dark: key.dark, onReady: { image in
                    // Keep the rendered underlay after admission too: WebKit can
                    // commit its native layer one frame after its snapshot callback.
                    if let image { self.image = image }
                    ready = true
                    cache.store(.init(document: document, image: self.image), for: key)
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
    }
}

private struct ReportCoverHTML: NSViewRepresentable {
    let html: String
    let dark: Bool
    let onReady: (NSImage?) -> Void
    let onFailure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PassiveCoverWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
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
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.load(URLRequest(url: URL(string: "mokusei-cover://document/index.html")!))
    }
    static func dismantleNSView(_ view: PassiveCoverWebView, coordinator: Coordinator) {
        coordinator.onReady = nil; coordinator.onFailure = nil
        view.stopLoading(); view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        var html: String?
        var onReady: ((NSImage?) -> Void)?
        var onFailure: ((String) -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.takeSnapshot(with: nil) { [weak self, weak webView] image, _ in
                guard let self, let webView, let onReady else { return }
                onReady(image)
                webView.alphaValue = 1
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
