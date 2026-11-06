import AppKit
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI
import WebKit

/// Full cover markup is fetched for mounted cards, never shipped in the catalog.
struct NativeReportCover: View {
    let props: ApplicationThreadProps<NativeReportView>
    @State private var document: ApplicationHTMLDocument?
    @State private var failure: String?
    @Environment(\.colorScheme) private var colorScheme
    private var source: ApplicationHTMLSource {
        .init(pluginID: "report", queryID: "report.cover", input: props.entry.ref.json,
              contentRevision: props.entry.view.coverRevision)
    }
    var body: some View {
        ZStack {
            NativePalette.overview.surface.swiftUI
            if let document, document.contentRevision == props.entry.view.coverRevision {
                ReportCoverHTML(html: document.html.string, dark: colorScheme == .dark) { message in
                    failure = message; self.document = nil
                }
            } else if let failure {
                Text(applicationText(props.context.locale, "封面暂不可用", "Cover unavailable"))
                    .font(NativeTypography.inter(size: 12)).foregroundStyle(.secondary).help(failure)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .task(id: source) {
            document = nil; failure = nil
            do {
                let result = try await props.context.domain.query(NativeReportContracts.cover,
                    input: props.entry.ref.threadID, lifetime: props.context.lifetime)
                try Task.checkCancellation()
                guard result.contentRevision == props.entry.view.coverRevision else {
                    throw PluginContractError("Report cover revision changed")
                }
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
    let onFailure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PassiveCoverWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "mokusei-cover")
        let view = PassiveCoverWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: PassiveCoverWebView, context: Context) {
        context.coordinator.onFailure = onFailure
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.load(URLRequest(url: URL(string: "mokusei-cover://document/index.html")!))
    }
    static func dismantleNSView(_ view: PassiveCoverWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        var html: String?
        var onFailure: ((String) -> Void)?
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
