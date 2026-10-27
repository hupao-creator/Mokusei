import AppKit
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import WebKit
@testable import MokuseiSidecardBrowser

/// Exercises the real WKUIDelegate and native sheet ownership without loading
/// external pages. NSOpenPanel needs the isolated runner's NSApplication event
/// loop; ordinary SwiftPM can exit during the panel without completing the suite.
@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized, .enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1", "Requires the isolated AppKit event loop for native file panels: python3 tools/verification/reading-presentation/run.py --browser-dialogs"))
struct NativeBrowserDialogTests {
    enum Dialog: CaseIterable { case alert, confirm, prompt, file }
    enum Retirement: CaseIterable { case release, suppression, navigation }

    @MainActor final class Fixture: NSObject, WKUIDelegate {
        let session: BrowserWebSession
        let window: NSWindow
        private(set) var frame: WKFrameInfo?
        private var fileParameters: WKOpenPanelParameters?
        var completions = 0
        var confirmed: Bool?
        var text: String?
        var files: [URL]?

        override init() {
            _ = NSApplication.shared
            session = BrowserWebSession(store: .nonPersistent())
            window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
            super.init()
            window.isReleasedWhenClosed = false
            window.contentView = session.webView
            window.orderBack(nil)
            session.setSuppressed(false)
        }
        func prepare() async throws {
            // These wrappers carry WebKit-owned C++ state. Obtain initialized
            // instances from a local document instead of calling NSObject.init.
            session.webView.uiDelegate = self
            defer { session.webView.uiDelegate = session }
            session.webView.loadHTMLString("<input id='fixture-file' type='file'>", baseURL: URL(string: "https://fixture.invalid/"))
            try await NativeBrowserDialogTests.wait {
                (try? await self.session.webView.evaluateJavaScript("!!document.getElementById('fixture-file')")) as? Bool == true
            }
            _ = try await session.webView.evaluateJavaScript("document.getElementById('fixture-file').click()")
            try await NativeBrowserDialogTests.wait { self.frame != nil && self.fileParameters != nil }
        }
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
            self.frame = frame; fileParameters = parameters
            completionHandler(nil)
        }
        func open(_ dialog: Dialog) throws {
            let frame = try #require(frame)
            switch dialog {
            case .alert:
                session.webView(session.webView, runJavaScriptAlertPanelWithMessage: "Fixture alert", initiatedByFrame: frame) {
                    self.completions += 1
                }
            case .confirm:
                session.webView(session.webView, runJavaScriptConfirmPanelWithMessage: "Fixture confirm", initiatedByFrame: frame) {
                    self.completions += 1; self.confirmed = $0
                }
            case .prompt:
                session.webView(session.webView, runJavaScriptTextInputPanelWithPrompt: "Fixture prompt", defaultText: "draft", initiatedByFrame: frame) {
                    self.completions += 1; self.text = $0
                }
            case .file:
                session.webView(session.webView, runOpenPanelWith: try #require(fileParameters), initiatedByFrame: frame) {
                    self.completions += 1; self.files = $0
                }
            }
        }
        func close() {
            session.release()
            window.contentView = nil
            window.close()
        }
    }

    @Test(arguments: Dialog.allCases, Retirement.allCases)
    func retiringPageCancelsItsSheetAndCompletesExactlyOnce(dialog: Dialog, retirement: Retirement) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try await fixture.prepare()
        try fixture.open(dialog)
        try await Self.wait { fixture.window.attachedSheet != nil }
        let sheet = try #require(fixture.window.attachedSheet)
        #expect(fixture.completions == 0)

        switch retirement {
        case .release: fixture.session.release()
        case .suppression: fixture.session.setSuppressed(true)
        case .navigation: fixture.session.navigate(try #require(URL(string: "about:blank")))
        }
        #expect(fixture.completions == 1)
        #expect(fixture.confirmed != true && fixture.text == nil && fixture.files == nil)
        try await Self.wait { fixture.window.attachedSheet == nil && !sheet.isVisible }
        // AppKit delivers its completion after dismissal; it must not complete
        // WebKit a second time or revive a retired upload result.
        try await Task.sleep(for: .milliseconds(100))
        fixture.session.release()
        #expect(fixture.completions == 1)
    }

    @Test(arguments: Dialog.allCases)
    func hiddenPageCannotPresentNewSheet(dialog: Dialog) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try await fixture.prepare()
        fixture.session.setSuppressed(true)
        try fixture.open(dialog)
        #expect(fixture.window.attachedSheet == nil)
        #expect(fixture.completions == 1)
        #expect(fixture.confirmed != true && fixture.text == nil && fixture.files == nil)
    }

    @Test func acceptedPromptAllowsReentrantNextDialog() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try await fixture.prepare()
        let frame = try #require(fixture.frame)
        fixture.session.webView(fixture.session.webView, runJavaScriptTextInputPanelWithPrompt: "Fixture prompt", defaultText: "draft", initiatedByFrame: frame) { text in
            fixture.completions += 1; fixture.text = text
            fixture.session.webView(fixture.session.webView, runJavaScriptConfirmPanelWithMessage: "Next dialog", initiatedByFrame: frame) {
                fixture.completions += 1; fixture.confirmed = $0
            }
        }
        try await Self.wait { fixture.window.attachedSheet != nil }
        let sheet = try #require(fixture.window.attachedSheet)
        fixture.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        sheet.orderOut(nil)
        try await Self.wait { fixture.completions == 1 }
        #expect(fixture.text == "draft")

        try await Self.wait { fixture.window.attachedSheet != nil && fixture.window.attachedSheet !== sheet }
        #expect(fixture.completions == 1)
        fixture.session.release()
        #expect(fixture.completions == 2 && fixture.confirmed == false)
        #expect(fixture.text == "draft")
    }

    @Test(arguments: [false, true])
    func navigationCancellationRejectsReentrantPageDialog(navigateAgain: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try await fixture.prepare()
        let frame = try #require(fixture.frame)
        let target = try #require(URL(string: "about:blank"))
        var confirmations: [Bool] = []
        var nestedCompletions = 0
        fixture.session.webView(fixture.session.webView, runJavaScriptConfirmPanelWithMessage: "Leaving page", initiatedByFrame: frame) { accepted in
            confirmations.append(accepted)
            if navigateAgain { fixture.session.navigate(target) }
            fixture.session.webView(fixture.session.webView, runJavaScriptAlertPanelWithMessage: "Retired page", initiatedByFrame: frame) {
                nestedCompletions += 1
            }
        }
        try await Self.wait { fixture.window.attachedSheet != nil }
        fixture.session.navigate(target)
        #expect(confirmations == [false])
        #expect(nestedCompletions == 1)
        try await Self.wait { fixture.window.attachedSheet == nil }
    }

    private static func wait(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw DialogTimeout()
    }
    private struct DialogTimeout: Error {}
}
