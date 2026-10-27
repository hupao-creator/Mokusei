import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiPluginUI
@testable import MokuseiHarnessCodex
@testable import MokuseiHarnessClaude
@testable import MokuseiHarnessPi
@testable import MokuseiHarnessOpenCode

@MainActor @Suite(.serializedNative, .serialized, .enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_INITIAL_RESPONSE_FIXTURES"] != nil, "Requires Go adapter fixtures: python3 tools/verification/reading-presentation/run.py --initial-response"))
struct ThreadCardInitialResponseTests {
    private let sentinel = "USER_PROMPT_MUST_NOT_APPEAR_IN_BODY"
    private func fixtures() throws -> [JSONValue] {
        let path = try #require(ProcessInfo.processInfo.environment["MOKUSEI_INITIAL_RESPONSE_FIXTURES"])
        return try #require(JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path))).arrayValue)
    }
    private func input(_ fixture: JSONValue, pending: Bool = false) throws -> HarnessThreadInput {
        let observation = try ThreadPublicObservation(json: #require(fixture["observation"]))
        let thread = try HarnessThread(id: "first-response", harnessID: JSONText(fixture["harness"]!.stringValue!), revision: 1,
            sessionState: fixture["state"]!, observation: observation, cwd: "/fixture", settings: .object([:]),
            createdAt: 1, updatedAt: 2_000_000_000_000, title: "A long task title that uses two lines in the ordinary card", tags: [])
        var json = try #require(thread.json.objectValue); json["pendingInput"] = .bool(pending)
        return .init(thread: try HarnessThread(json: .object(json)))
    }
    private func identity(_ input: HarnessThreadInput) throws -> (ThreadCardIdentityView, ThreadCardPresentation, JSONText) {
        switch input.thread.harnessID.string {
        case "codex":
            let p = try CodexHarnessPlugin().projectOverview(input: input, availableColumns: 3)
            return (p.view.identity, p.view.presentation, p.envelope.excerpt)
        case "claude":
            let p = try ClaudeHarnessPlugin().projectOverview(input: input, availableColumns: 3)
            return (p.view.identity, p.view.presentation, p.envelope.excerpt)
        case "pi":
            let p = try PiHarnessPlugin().projectOverview(input: input, availableColumns: 3)
            return (.init(title: input.thread.title.string, excerpt: p.view.excerpt.string, message: p.view.message,
                          initialResponse: p.view.initialResponse, initialResponseContent: p.view.initialResponseContent), p.view.presentation, p.envelope.excerpt)
        default:
            let p = try OpenCodeHarnessPlugin().projectOverview(input: input, availableColumns: 3)
            return (.init(title: input.thread.title.string, excerpt: p.view.excerpt, message: p.view.message,
                          initialResponse: p.view.initialResponse, initialResponseContent: p.view.initialResponseContent), p.view.presentation, p.envelope.excerpt)
        }
    }
    @Test func actualGoProjectionsPreserveContentAndStructure() throws {
        for f in try fixtures() {
            let input = try input(f, pending: true)
            let (body, presentation, search) = try identity(input)
            let initial = f["initial"] == .bool(true) && f["agent"] != .bool(true)
            #expect(body.initialResponseContent == (f["initial"] == .bool(true) && f["agent"] == .bool(true)))
            #expect((body.initialResponse != nil) == initial, "\(f["harness"]!) / \(f["name"]!)")
            if initial {
                #expect(body.excerpt.isEmpty && body.message == nil)
                #expect(!body.initialResponse!.title.contains(sentinel))
            }
            if f["agent"] == .bool(true) { #expect(body.excerpt.contains("AGENT_CONTENT_TAKES_OVER")) }
            if f["name"] == .text("running") || f["name"] == .text("long-prompt") {
                #expect(search.string.contains(sentinel))
            }
            var raw = try #require(input.thread.sessionState.objectValue)
            raw["initialResponseScope"] = .bool(false)
            var json = try #require(input.thread.json.objectValue); json["sessionState"] = .object(raw)
            let (priorBody, prior, priorSearch) = try identity(.init(thread: HarnessThread(json: .object(json))))
            #expect(presentation.key == prior.key && presentation.size == prior.size)
            #expect(search == priorSearch)
            if !initial { #expect(body.excerpt == priorBody.excerpt && body.message == priorBody.message) }
        }
    }
    @Test func publicFactsTakePrecedenceOverPendingInput() throws {
        #expect(threadCardInitialResponse(pendingInput: false, observation: .init(), hasVisibleInteraction: false).phase == .waiting)
        #expect(threadCardInitialResponse(pendingInput: true, observation: .init(), hasVisibleInteraction: false).phase == .submitting)
        for status in [PublicExecution.Status.running, .failed, .interrupted, .completed] {
            let execution = try PublicExecution(executionID: "first", status: status, startedAt: 1, finishedAt: status == .running ? nil : 2)
            for background in [false, true] {
                let value = threadCardInitialResponse(pendingInput: true, observation: .init(latestExecution: execution,
                    backgroundWork: background ? .init() : nil), hasVisibleInteraction: false)
                #expect(value.phase != .submitting)
                if background && status != .running { #expect(value.detail == "后台仍在运行") }
            }
        }
        for kind in [PublicInteraction.Kind.question, .permission] {
            let interaction = PublicInteraction(id: "request", kind: kind, title: "Real request",
                actions: [.init(id: "allow", intent: .allow, label: "Allow")], questions: [])
            let observation = ThreadPublicObservation(latestExecution: try .init(executionID: "first", status: .waitingForUser,
                startedAt: 1, interactions: [interaction]), backgroundWork: .init())
            for visible in [false, true] {
                let value = threadCardInitialResponse(pendingInput: true, observation: observation, hasVisibleInteraction: visible)
                #expect(value.title == threadCardStatus(observation).label)
                #expect(value.detail == (visible ? "请处理卡片中的请求" : "打开对话查看请求"))
            }
        }
    }
    @Test func malformedAndMissingFlagsRemainConservative() throws {
        for f in try fixtures().filter({ $0["name"] == .text("running") }) {
            let original = try input(f)
            var nullJSON = try #require(original.thread.json.objectValue)
            nullJSON["sessionState"] = .null
            #expect(try identity(.init(thread: HarnessThread(json: .object(nullJSON)))).0.initialResponse != nil)
            var raw = try #require(original.thread.sessionState.objectValue)
            raw.removeValue(forKey: "initialResponseScope")
            var json = try #require(original.thread.json.objectValue); json["sessionState"] = .object(raw)
            #expect(try identity(.init(thread: HarnessThread(json: .object(json)))).0.initialResponse == nil)
            raw["initialResponseScope"] = .text("true"); json["sessionState"] = .object(raw)
            #expect(throws: (any Error).self) { try identity(.init(thread: HarnessThread(json: .object(json)))) }
            json = try #require(original.thread.json.objectValue); json["moku"] = .bool(true); json["transcript"] = .array([])
            #expect(try identity(.init(thread: HarnessThread(json: .object(json)))).0.initialResponse == nil)
        }
    }
    @Test(.requiresDisplay) func mountedProductionCardsShowStatesAndFirstContent() async throws {
        let rows = try fixtures()
        let modules = [AnyHarnessPlugin(CodexHarnessPlugin()), AnyHarnessPlugin(ClaudeHarnessPlugin()),
                       AnyHarnessPlugin(PiHarnessPlugin()), AnyHarnessPlugin(OpenCodeHarnessPlugin())]
        let directory = ProcessInfo.processInfo.environment["MOKUSEI_INITIAL_RESPONSE_ARTIFACTS"]
        if let directory { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        for module in modules {
            for name in ["empty", "idle", "attention", "running", "failed", "interrupted", "completed", "reasoning", "answer", "tool-plan"] {
                let fixtureName = name == "idle" ? "empty" : name == "attention" ? "running" : name
                let f = try #require(rows.first { $0["harness"] == .string(module.descriptor.id) && $0["name"] == .text(fixtureName) })
                var input = try input(f, pending: name == "empty")
                if name == "attention" {
                    let request = PublicInteraction(id: "approval", kind: .permission, title: "Real permission",
                        actions: [.init(id: "allow", intent: .allow, label: "Allow")], questions: [])
                    let waiting = ThreadPublicObservation(latestExecution: try .init(executionID: "first", status: .waitingForUser,
                        startedAt: 1, interactions: [request]))
                    var json = try #require(input.thread.json.objectValue); json["observation"] = waiting.json
                    input = .init(thread: try HarnessThread(json: .object(json)))
                }
                let expected = try identity(input).0
                let snapshot = try module.projectOverview(input: input, availableColumns: 3)
                let cardWidth = 360 * CGFloat(snapshot.envelope.footprint.columns) + 16 * CGFloat(snapshot.envelope.footprint.columns - 1)
                let cardHeight = 200 * CGFloat(snapshot.envelope.footprint.rows) + 16 * CGFloat(snapshot.envelope.footprint.rows - 1)
                for dark in [false, true] {
                    let window = FirstResponseNative.window(snapshot.card(actions: Self.actions, openThread: {})
                        .frame(width: cardWidth, height: cardHeight)
                        .background(NativePalette.overview.surface.swiftUI)
                        .environment(\.locale, Locale(identifier: dark ? "zh-Hans" : "en"))
                        .environment(\.colorScheme, dark ? .dark : .light), width: cardWidth, height: cardHeight, dark: dark)
                    let root = try #require(window.contentView)
                    try await FirstResponseNative.wait {
                        let texts = FirstResponseNative.text(root).joined(separator: " ")
                        if let initial = expected.initialResponse {
                            return texts.contains(NativePluginLocalization.localize(initial.detail, locale: Locale(identifier: dark ? "zh-Hans" : "en")))
                        }
                        return texts.contains("AGENT_CONTENT_TAKES_OVER")
                    }
                    #expect(!FirstResponseNative.text(root).joined(separator: " ").contains(sentinel))
                    if let directory {
                        try FirstResponseNative.capture(root, to: URL(fileURLWithPath: directory).appendingPathComponent("\(module.descriptor.id.string)-\(name)-\(dark ? "dark" : "light").png"))
                    }
                    window.close()
                }
            }
        }
        // Update a mounted production identity; a hidden card must consume the
        // edge without replaying loading when it becomes visible again.
        let f = try #require(rows.first { $0["harness"] == .text("codex") && $0["name"] == .text("running") })
        let (initial, presentation, _) = try identity(input(f))
        let fixture = FirstResponseMounted(identity: initial)
        let visibility = ThreadCardAnimationVisibility()
        let window = FirstResponseNative.window(FirstResponseMountedCard(fixture: fixture, presentation: presentation)
            .environment(\.threadCardAnimationVisibility, visibility).environment(\.locale, Locale(identifier: "en")))
        defer { window.close() }
        let root = try #require(window.contentView)
        try await FirstResponseNative.wait { FirstResponseNative.text(root).joined().contains("Responses will appear here") }
        visibility.isVisible = false
        fixture.identity = .init(title: initial.title, excerpt: "AGENT_CONTENT_TAKES_OVER", message: .init(id: "real", text: "AGENT_CONTENT_TAKES_OVER"), initialResponseContent: true)
        try await FirstResponseNative.wait { FirstResponseNative.text(root).joined().contains("AGENT_CONTENT_TAKES_OVER") }
        visibility.isVisible = true
        #expect(!FirstResponseNative.text(root).joined().contains("Responses will appear here"))
        let visibleFixture = FirstResponseMounted(identity: initial)
        let visibleWindow = FirstResponseNative.window(FirstResponseMountedCard(fixture: visibleFixture, presentation: presentation)
            .background(NativePalette.overview.surface.swiftUI).environment(\.locale, Locale(identifier: "en")))
        defer { visibleWindow.close() }
        let visibleRoot = try #require(visibleWindow.contentView)
        try await FirstResponseNative.wait { FirstResponseNative.text(visibleRoot).joined().contains("Responses will appear here") }
        visibleFixture.identity = fixture.identity
        try await FirstResponseNative.wait { !FirstResponseNative.text(visibleRoot).joined().contains("Responses will appear here") }
        // Timed captures inspect the production entrance, without installing a
        // second animation implementation or asserting WindowServer frame pacing.
        for (delay, name) in [(60, "entrance-60ms"), (120, "entrance-180ms")] {
            try await Task.sleep(for: .milliseconds(delay))
            if let directory { try FirstResponseNative.capture(visibleRoot, to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")) }
        }
        #expect(FirstResponseNative.text(visibleRoot).joined().contains("AGENT_CONTENT_TAKES_OVER"))
    }
    private static var actions: HarnessThreadActions {
        .init(interrupt: {}, respond: { _ in }, invokeHarnessExtension: { _, _ in .null }, forkThread: { _ in "fork" },
              openExternal: { _ in }, openFollowUp: { _ in })
    }
}

@MainActor @Observable private final class FirstResponseMounted {
    var identity: ThreadCardIdentityView
    init(identity: ThreadCardIdentityView) { self.identity = identity }
}
private struct FirstResponseMountedCard: View {
    let fixture: FirstResponseMounted
    let presentation: ThreadCardPresentation
    var body: some View { HarnessThreadCard(identity: fixture.identity, presentation: presentation) }
}
@MainActor private enum FirstResponseNative {
    static func window<V: View>(_ view: V, width: CGFloat = 360, height: CGFloat = 200, dark: Bool = false) -> NSWindow {
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.unhide(nil); app.activate(ignoringOtherApps: true)
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enableAX) { _ = app.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width + 20, height: height + 20), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: width, height: height).padding(10).accessibilityElement(children: .contain))
        host.frame = .init(x: 0, y: 0, width: width + 20, height: height + 20)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }
    static func capture(_ root: NSView, to url: URL) throws {
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
    static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            for window in NSApplication.shared.windows { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let observed = NSApplication.shared.windows.compactMap(\.contentView).flatMap { text($0) }.joined(separator: " | ")
        Issue.record(Comment(rawValue: "Production card did not expose expected body: " + observed))
        throw CancellationError()
    }
    static func text(_ root: NSView) -> [String] {
        var result = [String](), seen = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted, seen.count < 10_000, let element = object as? NSObject else { return }
            for key in ["accessibilityLabel", "accessibilityValue"] {
                let selector = NSSelectorFromString(key)
                if element.responds(to: selector), let text = element.perform(selector)?.takeUnretainedValue() as? String { result.append(text) }
            }
            let selector = NSSelectorFromString("accessibilityChildren")
            if element.responds(to: selector), let children = element.perform(selector)?.takeUnretainedValue() as? [AnyObject] { children.forEach(visit) }
            if let view = element as? NSView { view.subviews.forEach(visit) }
        }
        _ = root.window?.accessibilityChildren(); visit(root.window ?? root); return result
    }
}
