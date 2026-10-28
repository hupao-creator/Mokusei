import AppKit
import Network
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import WebKit
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiApplications
@testable import MokuseiUI

@MainActor @Observable private final class ReportNavigationFixture {
    var open = false
    var ready = false
    var suppressed = false
    var revision = "1"
    var scale: CGFloat = 1
    var backs = 0
    var externalURLs: [URL] = []
    let html = """
        <html><body style='background:white;min-height:2400px'>
        <h1>Report</h1>
        <input id='ordinary' value='alpha beta gamma'>
        <div id='editableTrue' contenteditable='true'>alpha beta gamma</div>
        <div id='editableEmpty' contenteditable=''>alpha beta gamma</div>
        <div id='editablePlain' contenteditable='plaintext-only'>alpha beta gamma</div>
        <div id='shadowHost'></div>
        <div id='closedShadowHost'></div>
        <dialog id='modal'><p>Native modal</p><button>Close</button></dialog>
        <form id='post' method='post' target='_blank'>
          <input name='x' value='fixture-post-body'><button>Submit</button>
        </form>
        <script>
        document.getElementById('shadowHost').attachShadow({mode:'open'}).innerHTML =
          '<input id="shadowInput" value="alpha beta gamma">';
        const closedRoot = document.getElementById('closedShadowHost').attachShadow({mode:'closed'});
        closedRoot.innerHTML = '<input value="alpha beta gamma">';
        const closedInput = closedRoot.querySelector('input');
        window.focusClosedInput = () => { closedInput.focus(); closedInput.setSelectionRange(16, 16); };
        window.readClosedInput = () => closedInput.value;
        document.querySelector('#post button').addEventListener('click', event => window.postClickTrusted = event.isTrusted);
        document.getElementById('post').addEventListener('submit', () => window.postSubmitted = true);
        window.postInputEvents = [];
        for (const type of ['mousedown', 'mouseup', 'click']) document.addEventListener(type, event => {
          window.postInputEvents.push({type, trusted: event.isTrusted, tag: event.target.tagName,
            id: event.target.id, x: event.clientX, y: event.clientY});
        }, true);
        </script>
        </body></html>
        """
    let motion = NativeReadingPageMotion()
}

private struct ReportNavigationReplay: View {
    let fixture: ReportNavigationFixture
    private var source: ApplicationHTMLSource {
        get throws {
            try ApplicationHTMLSource(query: ApplicationOperation<JSONText, ApplicationHTMLDocument>(
                id: "report.html", ownerPluginID: "report", kind: .query,
                input: .init(decode: { _ in "report" }, encode: { _ in .null }),
                output: .init(decode: { _ in ApplicationHTMLDocument(html: "", contentRevision: "1") }, encode: { _ in .null })),
                input: "report", contentRevision: JSONText(fixture.revision))
        }
    }
    var body: some View {
        GeometryReader { geometry in
            NativeReadingPageStack(open: fixture.open, identity: "report", motion: fixture.motion,
                enabled: !fixture.suppressed, focusBlur: true, stationaryParent: true, emphasizedOpening: true,
                onClose: { fixture.open = false }) {
                Color.gray
            } front: {
                NativeApplicationHTMLSurface(source: try! source,
                    thread: .init(threadID: "report", typeID: "report.document"), theme: .light,
                    suppressed: fixture.suppressed, locale: "en", readDocument: { source in
                        ApplicationHTMLDocument(html: JSONText(fixture.html),
                            contentRevision: source.contentRevision)
                    }, openExternal: { fixture.externalURLs.append($0) }, onBack: { fixture.backs += 1; fixture.motion.close() }, onSettings: {},
                    onNativeNavigationChange: { fixture.ready = $0 }, onFailure: { Issue.record(Comment(rawValue: $0.message)) })
            }
            .frame(width: geometry.size.width / fixture.scale, height: geometry.size.height / fixture.scale)
            .environment(\.nativeWindowContentScale, fixture.scale)
            .scaleEffect(fixture.scale, anchor: .topLeading)
        }
        .overlay(alignment: .topLeading) {
            NativeWindowNavigationView(action: fixture.open ? .init(label: "Back", onBack: { fixture.motion.close() }) : nil,
                hidden: fixture.ready || fixture.suppressed)
        }
        .modifier(NativeWorkspaceWindowSurface())
    }
}

@MainActor @Suite(.serializedNative, .serialized)
struct NativeReportNavigationTests {
    private func portal(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "mokusei-report-navigation-portal" { return view }
        return view.subviews.lazy.compactMap { portal(in: $0) }.first
    }

    private func assertBack(_ navigation: NSView, in root: NSView) throws {
        // AppKit hitTest takes the point in the receiver's superview coordinates.
        let point = navigation.convert(NSPoint(x: 115, y: 29), to: root.superview)
        let hit = try #require(root.hitTest(point))
        #expect(hit === navigation || hit.isDescendant(of: navigation))
        let outside = navigation.convert(NSPoint(x: 300, y: 180), to: root.superview)
        let outsideHit = root.hitTest(outside)
        #expect(outsideHit !== navigation && outsideHit?.isDescendant(of: navigation) != true)
    }

    @Test(.requiresDisplay, .enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1",
        "Requires the isolated AppKit event loop for real WebKit mouse/key input: python3 tools/verification/reading-presentation/run.py --report-navigation"))
    func reportNavigationMovesWithPageSurvivesReplacementSuppressionAndZoomAndClicksBack() async throws {
        let app = NSApplication.shared
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enableAX) { _ = app.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
        let fixture = ReportNavigationFixture()
        let window = SwiftUIReplay.window(ReportNavigationReplay(fixture: fixture))
        window.styleMask.formUnion([.fullSizeContentView, .closable, .miniaturizable])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        defer { window.close() }
        let root = try #require(window.contentView)
        let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            try #require(window.standardWindowButton($0))
        }
        let actions = buttons.map(\.action)
        let sizes = buttons.map { $0.frame.size }
        func top(_ view: NSView) -> CGFloat {
            let rect = view.convert(view.bounds, to: root)
            return root.isFlipped ? rect.minY : root.bounds.height - rect.maxY
        }
        func assertButtons(hidden: Bool, navigation: NSView? = nil) {
            for (index, button) in buttons.enumerated() {
                #expect(button.isHidden == hidden)
                #expect(button.action == actions[index] && button.frame.size == sizes[index])
                let rect = button.convert(button.bounds, to: root)
                #expect(abs(rect.minX - CGFloat(24 + index * 20)) < 0.5)
                if let navigation { #expect(abs(top(button) - top(navigation) - 23) < 1) }
                else if !hidden { #expect(abs(top(button) - 31) < 0.5) }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        fixture.open = true
        try await SwiftUIReplay.wait(timeout: .seconds(15)) { fixture.ready && portal(in: root) != nil }
        try await SwiftUIReplay.wait { !fixture.motion.active }
        let navigation = try #require(portal(in: root))
        // Navigation belongs to its SwiftUI representable, never the scene's
        // private root NSHostingView whose children SwiftUI may reorder.
        #expect(navigation.superview !== root)
        try assertBack(navigation, in: root)
        fixture.revision = "2"
        try await SwiftUIReplay.wait { portal(in: root) !== navigation && fixture.ready }
        let replaced = try #require(portal(in: root))
        try await Task.sleep(for: .milliseconds(100))
        try assertBack(replaced, in: root)
        fixture.suppressed = true
        try await SwiftUIReplay.wait { portal(in: root) == nil }
        assertButtons(hidden: false)
        fixture.suppressed = false
        try await SwiftUIReplay.wait { portal(in: root) === replaced }
        func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        let document = try #require(webView(in: root))
        for scale: CGFloat in [5, 1.44, 0.8, 0.25, 1] {
            fixture.scale = scale
            try await Task.sleep(for: .milliseconds(100))
            let rect = replaced.convert(replaced.bounds, to: root)
            #expect(abs(rect.width - 148) < 1 && abs(rect.height - 58) < 1)
            try assertBack(replaced, in: root)
            assertButtons(hidden: false, navigation: replaced)
            let headingTop = try #require(try await document.evaluateJavaScript("document.querySelector('h1').getBoundingClientRect().top") as? Double)
            #expect(headingTop * Double(scale) * document.pageZoom >= 73,
                "The document must reserve the navigation's physical safe area at every workspace scale")
        }
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code))
                window.sendEvent(event)
            }
        }
        _ = try await document.evaluateJavaScript("""
            document.body.dispatchEvent(new KeyboardEvent('keydown', {
              key: 'Escape', bubbles: true, cancelable: true
            }));
            """)
        try await Task.sleep(for: .milliseconds(80))
        try #require(fixture.backs == 0 && fixture.open,
            "Document scripts cannot synthesize trusted host navigation shortcuts")
        window.makeFirstResponder(document)
        for id in ["ordinary", "editableTrue", "editableEmpty", "editablePlain", "shadowInput"] {
            let target = id == "shadowInput"
                ? "document.getElementById('shadowHost').shadowRoot.getElementById('shadowInput')"
                : "document.getElementById('\(id)')"
            _ = try await document.evaluateJavaScript("\(target).focus()")
            try key(123, "\u{F702}", modifiers: .option)
            try key(53, "\u{1b}")
            try await Task.sleep(for: .milliseconds(80))
            try #require(fixture.backs == 0 && fixture.open,
                "Report navigation must leave the native editing keys with \(id)")
        }
        _ = try await document.evaluateJavaScript("window.focusClosedInput()")
        #expect(try await document.evaluateJavaScript("document.getElementById('closedShadowHost').shadowRoot === null") as? Bool == true)
        try key(123, "\u{F702}", modifiers: .option)
        try key(7, "X", modifiers: .shift)
        try await Task.sleep(for: .milliseconds(80))
        try #require(fixture.backs == 0 && fixture.open)
        #expect(try await document.evaluateJavaScript("window.readClosedInput()") as? String == "alpha beta Xgamma",
            "Option-Left must retain native word movement even when the editor is hidden by a closed shadow root")
        _ = try await document.evaluateJavaScript("document.getElementById('modal').showModal()")
        try key(53, "\u{1b}")
        try await Task.sleep(for: .milliseconds(80))
        #expect(try await document.evaluateJavaScript("document.getElementById('modal').open") as? Bool == false)
        try #require(fixture.backs == 0 && fixture.open)
        let http = try ReportHTTPFixture()
        defer { http.close() }
        try await SwiftUIReplay.wait { http.port != nil }
        let postURL = try http.url("/post")
        let navigationDelegate = try #require(document.navigationDelegate)
        let uiDelegate = try #require(document.uiDelegate)
        let requests = ReportNavigationRequestWitness(navigation: navigationDelegate, ui: uiDelegate)
        document.navigationDelegate = requests
        document.uiDelegate = requests
        defer {
            document.navigationDelegate = navigationDelegate
            document.uiDelegate = uiDelegate
        }
        _ = try await document.evaluateJavaScript("""
            document.getElementById('post').action = '\(postURL.absoluteString)';
            document.querySelector('#post button').scrollIntoView({block: 'center'});
            """)
        let buttonPoint = try #require(try await document.evaluateJavaScript("""
            (() => { const rect = document.querySelector('#post button').getBoundingClientRect();
              return [rect.x + rect.width / 2, rect.y + rect.height / 2]; })()
            """) as? [Double])
        try #require(buttonPoint.count == 2)
        let postPoint = document.convert(NSPoint(x: buttonPoint[0],
            y: document.isFlipped ? buttonPoint[1] : document.bounds.height - buttonPoint[1]), to: nil)
        NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await SwiftUIReplay.wait { NSApp.isActive && window.isKeyWindow }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: postPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            // Deliver to this mounted WebKit view after acquiring native input;
            // NSWindow can consume a synthesized mouse event before DOM input.
            if type == .leftMouseDown {
                document.mouseDown(with: event)
                // WebKit defers delivery of the native mouse-down. Releasing
                // immediately can reach the DOM first and produces no click.
                let deadline = ContinuousClock.now + .seconds(3)
                var received = false
                while ContinuousClock.now < deadline {
                    received = try await document.evaluateJavaScript("window.postInputEvents.some(event => event.type === 'mousedown')") as? Bool == true
                    if received { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(received, "WebKit must receive mouse-down before its matching release")
            } else { document.mouseUp(with: event) }
        }
        try await Task.sleep(for: .milliseconds(80))
        let nativeSubmit = try await document.evaluateJavaScript("window.postClickTrusted === true && window.postSubmitted === true") as? Bool
        if nativeSubmit != true {
            let diagnostics = try await document.evaluateJavaScript("""
                (() => { const button = document.querySelector('#post button'), rect = button.getBoundingClientRect();
                  return {events: window.postInputEvents, clickTrusted: window.postClickTrusted ?? null,
                    submitted: window.postSubmitted ?? null, rect: {x:rect.x,y:rect.y,w:rect.width,h:rect.height},
                    hit: document.elementFromPoint(rect.x+rect.width/2,rect.y+rect.height/2)?.outerHTML,
                    innerWidth, innerHeight, scrollY, modalOpen: document.getElementById('modal').open}; })()
                """)
            print("Report native POST input diagnostics: \(String(describing: diagnostics)); point=\(postPoint); view frame=\(document.frame) bounds=\(document.bounds) flipped=\(document.isFlipped) rootRect=\(document.convert(document.bounds, to: root)); policy=\(requests.events)")
        }
        try #require(nativeSubmit == true,
            "The POST regression must use a real user gesture rather than WebKit's blocked automatic-popup path")
        do {
            try await SwiftUIReplay.wait {
                SwiftUIReplay.text(in: root).contains("This form cannot submit in a new window. Its data has not been sent.")
            }
        } catch {
            let form = try await document.evaluateJavaScript("""
                (() => { const form = document.getElementById('post'); return {
                  method: form.method, target: form.target, action: form.action,
                  clickTrusted: window.postClickTrusted, submitted: window.postSubmitted,
                  userActivation: navigator.userActivation.isActive, url: location.href
                }; })()
                """)
            print("Report POST diagnostics: form=\(String(describing: form)); policy=\(requests.events); external=\(fixture.externalURLs); http=\(http.requests); AX=\(SwiftUIReplay.text(in: root).sorted())")
            throw error
        }
        document.navigationDelegate = navigationDelegate
        document.uiDelegate = uiDelegate
        #expect(fixture.externalURLs.isEmpty, "A POST must never be passed to the URL-only external opener")
        #expect(http.requests.isEmpty, "The rejected POST must not issue an HTTP request")
        #expect(document.url?.scheme == "mokusei-html")
        _ = try await document.evaluateJavaScript("document.activeElement?.blur(); window.scrollTo(0, 0)")
        try await SwiftUIReplay.wait { portal(in: root) === replaced }
        try await Task.sleep(for: .milliseconds(250))
        window.makeFirstResponder(replaced)
        _ = try await document.evaluateJavaScript("window.scrollTo(0, 300)")
        var intermediateSamples = 0
        try await SwiftUIReplay.wait {
            if let navigation = portal(in: root) {
                assertButtons(hidden: buttons[0].isHidden, navigation: navigation)
                if top(navigation) < 8 && top(navigation) > -58 { intermediateSamples += 1 }
                return false
            }
            return true
        }
        #expect(intermediateSamples > 0, "Sample the production collapse animation, not just its endpoints")
        assertButtons(hidden: true)
        #expect(window.firstResponder === document || (window.firstResponder as? NSView)?.isDescendant(of: document) == true)
        // AppKit can reset frames during resize and activation. Its deferred
        // placement must retain the collapsed state at every content zoom.
        for scale: CGFloat in [1.44, 0.8, 1] {
            fixture.scale = scale
            window.setContentSize(CGSize(width: scale == 1 ? 1180 : 1000, height: 780))
            for button in buttons { button.setFrameOrigin(.zero) }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.post(name: name, object: window)
            }
            try await Task.sleep(for: .milliseconds(100))
            assertButtons(hidden: true)
        }
        // Settings/suppression temporarily yields control, then the still-
        // scrolled Report reacquires its hidden offset.
        fixture.suppressed = true
        try await SwiftUIReplay.wait { !buttons[0].isHidden }
        assertButtons(hidden: false)
        fixture.suppressed = false
        try await SwiftUIReplay.wait { buttons.allSatisfy(\.isHidden) }
        _ = try await document.evaluateJavaScript("window.scrollTo(0, 0)")
        try await SwiftUIReplay.wait { portal(in: root) === replaced }
        try await Task.sleep(for: .milliseconds(250))
        try assertBack(replaced, in: root)
        assertButtons(hidden: false, navigation: replaced)
        // Reverse an in-flight collapse; the same live offset drives both.
        _ = try await document.evaluateJavaScript("window.scrollTo(0, 300)")
        try await SwiftUIReplay.wait { top(replaced) < 0 }
        _ = try await document.evaluateJavaScript("window.scrollTo(0, 0)")
        try await SwiftUIReplay.wait {
            if let navigation = portal(in: root) { assertButtons(hidden: buttons[0].isHidden, navigation: navigation) }
            return portal(in: root) != nil && abs(top(replaced) - 8) < 0.5
        }
        assertButtons(hidden: false, navigation: replaced)
        _ = try await document.evaluateJavaScript("window.scrollTo(0, 300)")
        try await SwiftUIReplay.wait { buttons.allSatisfy(\.isHidden) }
        let remote = try http.url()
        _ = try await document.evaluateJavaScript("""
            const next = document.createElement('a'); next.href = '\(remote.absoluteString)';
            document.body.append(next); next.click();
            """)
        try await SwiftUIReplay.wait(timeout: .seconds(10)) { document.url == remote && !document.isLoading && portal(in: root) === replaced }
        try await Task.sleep(for: .milliseconds(250))
        assertButtons(hidden: false, navigation: replaced)
        #expect(try await document.evaluateJavaScript("document.querySelector('h1').textContent") as? String == "Short destination")
        let point = replaced.convert(NSPoint(x: 115, y: 29), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try await SwiftUIReplay.wait { fixture.backs == 1 && fixture.motion.active }
        // active is set before the asynchronously scheduled first animation frame.
        // Observe the presented interval instead of assuming a fixed 100ms sample.
        var sawMovingNavigation = false
        try await SwiftUIReplay.wait {
            if replaced.isDescendant(of: root) {
                let moving = replaced.convert(replaced.bounds, to: root)
                sawMovingNavigation = sawMovingNavigation || (moving.minX > 4 && moving.minX < root.bounds.width)
            }
            return !fixture.open
        }
        #expect(sawMovingNavigation,
            "The report and back navigation must leave together, rather than leaving a root overlay behind")
        #expect(portal(in: root) == nil)
        assertButtons(hidden: false)
    }
    @Test(.requiresDisplay, .enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1",
        "Requires the isolated AppKit event loop for native file panels: python3 tools/verification/reading-presentation/run.py --report-controls"))
    func reportNativeDialogsAndDownloadsPreserveTheDocument() async throws {
        let app = NSApplication.shared
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enableAX) { _ = app.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
        let fixture = ReportNavigationFixture()
        let window = SwiftUIReplay.window(ReportNavigationReplay(fixture: fixture))
        defer { window.close() }
        let root = try #require(window.contentView)
        fixture.open = true
        try await SwiftUIReplay.wait(timeout: .seconds(15)) { fixture.ready }
        func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        let document = try #require(webView(in: root))
        let http = try ReportHTTPFixture()
        defer { http.close() }
        try await SwiftUIReplay.wait { http.port != nil }
        // Exercise real WebKit UI callbacks and native sheets, including a
        // positive branch that used to be silently converted to cancellation.
        for script in ["window.dialogResult = String(confirm('Report confirm'))",
                       "window.dialogResult = prompt('Report prompt', 'PROMPT_DEFAULT')",
                       "alert('Report alert'); window.dialogResult = 'alert done'"] {
            let evaluation = Task { @MainActor in _ = try await document.evaluateJavaScript(script) }
            try await SwiftUIReplay.wait { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet)
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            sheet.orderOut(nil)
            _ = try await evaluation.value
            let expected = script.contains("confirm") ? "true" : script.contains("prompt") ? "PROMPT_DEFAULT" : "alert done"
            #expect(try await document.evaluateJavaScript("window.dialogResult") as? String == expected)
        }
        _ = try await document.evaluateJavaScript("""
            const file = document.createElement('input'); file.type = 'file';
            file.id = 'report-file'; document.body.append(file); file.click();
            """)
        try await SwiftUIReplay.wait { window.attachedSheet is NSOpenPanel }
        (window.attachedSheet as? NSOpenPanel)?.cancel(nil)
        try await SwiftUIReplay.wait { window.attachedSheet == nil }
        #expect(try await document.evaluateJavaScript("document.getElementById('report-file').files.length") as? Int == 0)

        _ = try await document.evaluateJavaScript("""
            const download = document.createElement('a');
            download.href = URL.createObjectURL(new Blob(['QA_DOWNLOAD']));
            download.download = 'qa.txt'; document.body.append(download); download.click();
            """)
        try await SwiftUIReplay.wait {
            SwiftUIReplay.text(in: root).contains("Downloads are not supported in reports. The document remains open.")
        }
        #expect(fixture.ready)
        let downloadURL = try http.url("/download")
        document.load(URLRequest(url: downloadURL))
        try await SwiftUIReplay.wait { http.requests.contains { $0.contains("/download") } }
        try await SwiftUIReplay.wait { !document.isLoading }
        try await SwiftUIReplay.wait {
            SwiftUIReplay.text(in: root).contains("Downloads are not supported in reports. The document remains open.")
        }
        #expect(fixture.ready)
        #expect(document.url?.scheme == "mokusei-html")
        #expect(try await document.evaluateJavaScript("document.querySelector('h1').textContent") as? String == "Report")
    }

    @Test(.requiresDisplay)
    func reportDoesNotRetainAnErrorOwnedByTheRecoverableSurface() async throws {
        let app = NSApplication.shared
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enableAX) { _ = app.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
        let plugin = try #require(NativeReportApplication.make().threads.first)
        let reference = ApplicationThreadRef(threadID: "report", typeID: "report.document")
        var notified = false
        // The capability owns Retry and can recover without a new revision.
        // Deliver its failure notification to the real Report detail, then
        // expose recovered content from the same capability identity.
        let capability = ApplicationIsolatedHTML { _, onFailure in
            Text("Recovered report").task {
                onFailure(.init(thread: reference, message: "Retired visit error"))
                notified = true
            }
        }
        let context = ApplicationRendererContext(theme: .light, locale: "en", lifetime: PluginLifetime(),
            domain: ApplicationDomainClient(pluginID: "report") { _, _, _, _, _ in .null },
            capabilities: try .init(scope: .init(pluginID: "report", thread: reference),
                requires: plugin.requires, registrations: [.init(ApplicationCapabilities.isolatedHTML, value: capability)]),
            openThread: { _, _ in }, openExecution: { _ in })
        let entry = ApplicationThreadCatalogEntry<JSONValue>(ref: reference, revision: 1, createdAt: 0, updatedAt: 0,
            title: "Report", archived: false, tags: .init(tags: [], semanticTags: [], directoryTags: [], tagEmojis: [:]), presentations: [],
            view: .object(["previewText": .text(""), "contentRevision": .text("1"), "relatedExecutions": .array([])]))
        let window = SwiftUIReplay.window(try plugin.detail(props: .init(entry: entry, context: context)))
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { notified && SwiftUIReplay.text(in: root).contains("Recovered report") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!SwiftUIReplay.text(in: root).contains("Retired visit error"))
    }

    @Test func reportReturnsToSourceExecutionAndOrdinaryThreadStillReturnsToOverview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory)),
            preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [], sidecards: [], applications: [NativeReportApplication.make()]))
        let presentation = NativeWorkspacePresentation(workspace: workspace)
        defer { presentation.applicationHost.release() }
        let agent = try HarnessThread(id: "source", harnessID: "codex", revision: 0, sessionState: .object([:]),
            observation: .init(), cwd: "/workspace", settings: .object([:]), createdAt: 1, updatedAt: 1, title: "Source", tags: [])
        try workspace.catalog.install(.object(["revision": .integer(1), "settingsRevision": .integer(0),
            "defaultCwd": .text("/workspace"), "settings": .object([:]), "threads": .array([agent.json]),
            "executions": .array([]), "applicationThreads": .array([])]))
        let source = ApplicationThreadRef(threadID: "source", typeID: "agent")
        let report = ApplicationThreadRef(threadID: "report", typeID: "report.document")
        let history = HarnessReadingTarget(executionID: "historical", requestID: "request", mode: .history)
        presentation.open(source, target: history)
        presentation.open(report)
        #expect(presentation.selected == report)
        presentation.closeApplication()
        #expect(presentation.selected == source)
        #expect(presentation.readingTarget == history)
        presentation.finishBack()
        #expect(presentation.selected == nil && presentation.readingTarget == nil)
        // Application-to-application navigation retains the original source.
        presentation.open(source, target: history)
        presentation.open(report)
        presentation.open(.init(threadID: "second-report", typeID: "report.document"))
        presentation.closeApplication()
        #expect(presentation.selected == source && presentation.readingTarget == history)
    }

}

/// Observes public WebKit requests and forwards the exact objects to the
/// production delegates, so failures distinguish policy from UI presentation.
@MainActor
private final class ReportNavigationRequestWitness: NSObject, WKNavigationDelegate, WKUIDelegate {
    let navigation: any WKNavigationDelegate
    let ui: any WKUIDelegate
    var events: [String] = []

    init(navigation: any WKNavigationDelegate, ui: any WKUIDelegate) {
        self.navigation = navigation; self.ui = ui
    }

    private func record(_ action: WKNavigationAction, source: String) {
        events.append("\(source) method=\(action.request.httpMethod ?? "nil") target=\(action.targetFrame.map { $0.isMainFrame ? "main" : "child" } ?? "new-window") url=\(action.request.url?.absoluteString ?? "nil")")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        record(action, source: "policy")
        if navigation.webView?(webView, decidePolicyFor: action, decisionHandler: decisionHandler) == nil {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        record(action, source: "new-window")
        return ui.webView?(webView, createWebViewWith: configuration, for: action, windowFeatures: windowFeatures) ?? nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        self.navigation.webView?(webView, didCommit: navigation)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation.webView?(webView, didFinish: navigation)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation.webView?(webView, didFail: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigation.webViewWebContentProcessDidTerminate?(webView)
    }
}

/// Real loopback navigation verifies that a remote document receives fresh
/// presentation state rather than inheriting the previous Report's scroll.
@MainActor
private final class ReportHTTPFixture {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var closed = false
    private(set) var port: UInt16?
    private(set) var requests: [String] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.port = self?.listener.port?.rawValue }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, !self.closed else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, buffered: Data())
            }
        }
        listener.start(queue: .main)
    }

    func url(_ path: String = "/short") throws -> URL {
        try #require(port.flatMap { URL(string: "http://127.0.0.1:\($0)\(path)") })
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed, error == nil, let data else { connection.cancel(); return }
                let request = buffered + data
                guard request.count <= 8192 else { connection.cancel(); return }
                guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if complete { connection.cancel() } else { self.receive(connection, buffered: request) }
                    return
                }
                self.requests.append(String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? "")
                let body = Data("<html><body><h1>Short destination</h1></body></html>".utf8)
                let mime = self.requests.last?.contains("/download") == true ? "application/octet-stream" : "text/html"
                let header = Data("HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func close() {
        closed = true
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}
