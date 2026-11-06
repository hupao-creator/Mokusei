import AppKit
import SwiftUI
import Testing
import WebKit
import MokuseiTestSupport
@testable import MokuseiApplications

@MainActor private final class CoverGeometryWitness: NSObject, WKScriptMessageHandler {
    var geometry: [String: Any] = [:]
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        geometry = message.body as? [String: Any] ?? [:]
    }
}

@MainActor @Suite(.serializedNative, .serialized)
struct NativeReportCoverTests {
    @Test(.requiresDisplay)
    func authoredTopSpaceSurvivesCoverReplacementWithoutDoubleInsets() async throws {
        func document(_ version: String, top: String, padding: Int) -> String {
            """
            <!doctype html><html><head><meta charset="utf-8"><style>
            :root { \(top) }
            * { box-sizing: border-box }
            html, body { margin: 0; width: 100%; height: 100% }
            main { width: 360px; min-height: 308px; padding: \(padding)px 24px 24px }
            .label { height: 16px }
            </style></head><body><main data-mokusei-html-content>
            <div class="label">\(version)</div></main>
            <script>document.body.dataset.authorScript = 'ran'</script></body></html>
            """
        }
        var failures: [String] = []
        func cover(_ html: String, dark: Bool = false) -> ReportCoverHTML {
            ReportCoverHTML(html: html, dark: dark, onFailure: { failures.append($0) })
        }
        let initial = document("initial", top: "", padding: 24)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: cover(initial))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 308),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        try await SwiftUIReplay.wait { webView(in: host) != nil }
        let web = try #require(webView(in: host))
        // WebKit disables evaluateJavaScript for this document. A trusted test
        // script observes layout without enabling any page-authored JavaScript.
        let witness = CoverGeometryWitness()
        let world = WKContentWorld.world(name: "mokusei-cover-test")
        let controller = web.configuration.userContentController
        controller.add(witness, contentWorld: world, name: "coverGeometry")
        // Document-end scripts in different worlds can run in either order.
        // Observe on the next WebKit task, after the host style is installed.
        controller.addUserScript(WKUserScript(source: """
            setTimeout(() => {
              const label = document.querySelector('.label');
              window.webkit.messageHandlers.coverGeometry.postMessage({
                version: label.textContent,
                values: [label.getBoundingClientRect().y,
                  document.querySelector('main').getBoundingClientRect().width,
                  document.documentElement.clientHeight, document.documentElement.scrollHeight],
                authorScript: document.body.dataset.authorScript ?? 'blocked'
              });
            }, 0);
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        defer { controller.removeScriptMessageHandler(forName: "coverGeometry", contentWorld: world) }
        web.reload()
        func assertLayout(_ version: String, top: Int) async throws {
            try await SwiftUIReplay.wait(timeout: .seconds(15)) {
                witness.geometry["version"] as? String == version && !web.isLoading
            }
            let values = try #require(witness.geometry["values"] as? [Int])
            #expect(values == [top, 360, 308, 308])
            #expect(witness.geometry["authorScript"] as? String == "blocked")
            #expect(web.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
            #expect(web.configuration.websiteDataStore.isPersistent == false)
            #expect(web.hitTest(.zero) == nil)
            #expect(failures.isEmpty)
        }
        try await assertLayout("initial", top: 24)
        // The real update removed physical top padding in favor of the Report
        // host variable. Reuse the mounted renderer to catch stale document state.
        let updated = document("updated", top: "--mokusei-html-top-space: 24px", padding: 0)
        host.rootView = cover(updated)
        try await assertLayout("updated", top: 24)
        #expect(webView(in: host) === web)
        host.rootView = cover(updated, dark: true)
        try await SwiftUIReplay.wait { web.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        try await assertLayout("updated", top: 24)
        host.rootView = cover(document("both", top: "--mokusei-html-top-space: 24px", padding: 24))
        try await assertLayout("both", top: 24)
        host.rootView = cover(document("edge-to-edge", top: "", padding: 0))
        try await assertLayout("edge-to-edge", top: 0)
    }
}
