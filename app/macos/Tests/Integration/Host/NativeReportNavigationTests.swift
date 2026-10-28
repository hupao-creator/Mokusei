import AppKit
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
                        ApplicationHTMLDocument(html: "<html><body style='background:white;min-height:2400px'><h1>Report</h1></body></html>",
                            contentRevision: source.contentRevision)
                    }, openExternal: { _ in }, onBack: { fixture.backs += 1; fixture.motion.close() }, onSettings: {},
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

    @Test(.requiresDisplay) func reportNavigationMovesWithPageSurvivesReplacementSuppressionAndZoomAndClicksBack() async throws {
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
        for scale: CGFloat in [1.44, 0.8, 1] {
            fixture.scale = scale
            try await Task.sleep(for: .milliseconds(100))
            let rect = replaced.convert(replaced.bounds, to: root)
            #expect(abs(rect.width - 148) < 1 && abs(rect.height - 58) < 1)
            try assertBack(replaced, in: root)
            assertButtons(hidden: false, navigation: replaced)
        }
        func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        let document = try #require(webView(in: root))
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
