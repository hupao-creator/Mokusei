import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiHarnessCodex
import MokuseiHarnessClaude
import MokuseiHarnessPi
import MokuseiHarnessOpenCode
@testable import MokuseiUI

@MainActor @Observable private final class ExecutionLinkFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let workspace: NativeWorkspaceModel
    let presentation: NativeWorkspacePresentation
    let plugin: AnyHarnessPlugin
    let harness: String
    let controls = NativeReadingInteractions()
    let visit = UUID()
    var thread: HarnessThread!
    var loaded = false
    var external: [URL] = []
    var noteText = "[View result](mokusei://execution?threadId=ordinary&executionId=target)"
    @ObservationIgnored var resources: [HarnessContentResource] = []
    @ObservationIgnored var revision = 0
    @ObservationIgnored lazy var back = ThreadDetailBackAction(label: "Back to overview", onBack: { [weak self] in self?.presentation.finishBack() })

    init(_ harness: String) throws {
        self.harness = harness
        switch harness {
        case "codex": plugin = AnyHarnessPlugin(CodexHarnessPlugin())
        case "claude": plugin = AnyHarnessPlugin(ClaudeHarnessPlugin())
        case "pi": plugin = AnyHarnessPlugin(PiHarnessPlugin())
        default: plugin = AnyHarnessPlugin(OpenCodeHarnessPlugin())
        }
        workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory)),
            preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [plugin], sidecards: [], applications: []))
        try workspace.preferences.setOnboardingCompleted(true)
        presentation = NativeWorkspacePresentation(workspace: workspace)
        try update()
    }

    func update(status: PublicExecution.Status = .completed, text: String? = nil, successor: Bool = false,
                archived: Bool = false, empty: Bool = false) throws {
        revision += 1
        let executions = try [("prior", PublicExecution.Status.completed), ("target", status)]
            .enumerated().map { index, entry in
                try PublicExecution(executionID: JSONText(entry.0), status: entry.1, startedAt: Double(index * 10 + 1),
                    finishedAt: [.running, .waitingForUser].contains(entry.1) ? nil : Double(index * 10 + 5))
            } + (successor ? [try PublicExecution(executionID: "successor", status: .running, startedAt: 21)] : [])
        let answer = text ?? "TARGET RESULT\n\n" + String(repeating: "A long result paragraph with enough detail to scroll.\n\n", count: 65)
        let raw = state(executions, answer: answer, empty: empty)
        thread = try HarnessThread(id: "ordinary", harnessID: JSONText(harness), revision: revision, sessionState: raw,
            observation: .init(latestExecution: executions.last), cwd: JSONText(directory.path), settings: .object([:]),
            createdAt: 1, updatedAt: Double(revision + 30), title: "Execution link replay", tags: [], archived: archived)
        try workspace.catalog.install(.object(["revision": .integer(revision), "settingsRevision": .integer(0),
            "defaultCwd": .text(directory.path), "settings": .object([:]), "threads": .array([thread.json]),
            "executions": .array([]), "applicationThreads": .array([])]))
        if loaded { resources.forEach { $0.publish(.ready(raw)) } }
    }

    func load() {
        loaded = true
        resources.forEach { $0.publish(.ready(thread.sessionState)) }
    }
    func resource(_ scope: HarnessContentScope) -> HarnessContentResource {
        let resource = HarnessContentResource(state: loaded ? .ready(thread.sessionState) : .loading, retry: {}, release: {})
        resources.append(resource)
        return resource
    }
    func close() async {
        await presentation.release()
        await workspace.client.close()
        try? FileManager.default.removeItem(at: directory)
    }
    var scroll: JSONValue? {
        controls.snapshot(visit: visit).first { $0["role"] == .text("timeline") && $0["id"]?.stringValue?.contains(".history.") == true }
    }
    var conversation: JSONValue? {
        controls.snapshot(visit: visit).first { $0["role"] == .text("conversation") }?["value"]
    }
    func perform(_ control: JSONValue, _ operation: String, _ value: JSONValue = .null) throws {
        try controls.perform(id: #require(control["id"]?.stringValue), handle: #require(control["handle"]?.stringValue),
                             operation: operation, value: value, visit: visit)
    }

    // Native-shaped fixtures enter the real Harness decoders and renderers.
    private func state(_ executions: [PublicExecution], answer: String, empty: Bool) -> JSONValue {
        let turns: [JSONValue] = executions.map { execution in
            let id = execution.executionID.string
            let body = id == "target" ? answer : "OTHER EXECUTION \(id)"
            let running = [.running, .waitingForUser].contains(execution.status)
            let messageStatus = running ? "streaming" : "complete"
            if harness == "pi" || harness == "opencode" { return execution.json }
            var turn: [JSONText: JSONValue] = ["executionId": .text(id), "createdAt": .number(execution.startedAt),
                "updatedAt": .number(execution.startedAt + 4), "status": .text(running ? "running" : execution.status.rawValue),
                "reasoning": .text(""), "plan": .array([]), "activities": .array([]), "interactions": .array([]), "notices": .array([])]
            if let finished = execution.finishedAt { turn["finishedAt"] = .number(finished) }
            var item: [JSONText: JSONValue] = ["id": .text(id + "-answer"), "kind": .text("assistant"), "content": .text(body),
                "status": .text(messageStatus), "createdAt": .number(execution.startedAt + 1)]
            if harness == "codex" { item["itemId"] = .text(id + "-native") }
            let items: [JSONValue] = empty && id == "target" ? [] : [.object(item)]
            var reviewItem: [JSONText: JSONValue] = ["id": .text(id + "-review"), "kind": .text("review"),
                "createdAt": .number(execution.startedAt + 2)]
            if harness == "codex" { turn["review"] = .text("LATE REVIEW") }
            else { reviewItem["content"] = .text("LATE REVIEW") }
            let review: [JSONValue] = execution.status == .completed && !empty ? [.object(reviewItem)] : []
            turn["timeline"] = .array(items + review)
            if harness == "codex" {
                turn["answer"] = .text(empty && id == "target" ? "" : body)
                turn["messages"] = .array([])
            } else {
                turn["text"] = .text(empty && id == "target" ? "" : body)
                turn["prompts"] = .array([.text(id + " prompt")]); turn["promptAttachments"] = .array([.array([])])
            }
            return .object(turn)
        }
        switch harness {
        case "codex": return .object(["schema": .text("mokusei.harness.codex.thread.v1"), "updatedAt": .number(40),
                                       "turns": .array(turns), "backgroundTerminals": .array([])])
        case "claude": return .object(["version": .integer(1), "turns": .array(turns), "nativeNotifications": .array([])])
        default:
            let messages: [JSONValue] = executions.compactMap { execution in
                let id = execution.executionID.string
                if empty && id == "target" { return nil }
                let text = id == "target" ? answer : "OTHER EXECUTION \(id)"
                var message: [JSONText: JSONValue] = ["id": .text(id + "-answer"), "executionId": .text(id), "role": .text("assistant"),
                    "text": .text(text), "status": .text([.running, .waitingForUser].contains(execution.status) ? "streaming" : "complete")]
                if harness == "opencode" {
                    message["parts"] = .array([
                        .object(["type": .text("text"), "ordinal": .integer(0), "text": .text(text)]),
                        .object(["type": .text("text"), "ordinal": .integer(1), "text": .text("Final reply second part")])])
                }
                return .object(message)
            }
            var raw: [JSONText: JSONValue] = ["version": .integer(1), "messages": .array(messages), "executions": .array(turns),
                                              "latestExecutionId": .string(executions.last!.executionID)]
            if harness == "opencode" { raw["interactions"] = .array([]) }
            return .object(raw)
        }
    }
}

private struct ExecutionLinkSurface: View {
    let fixture: ExecutionLinkFixture
    var body: some View {
        VStack(spacing: 0) {
            NativeMokuNoteContent(note: .init(id: "note", text: fixture.noteText, revision: 1, updatedAt: 1),
                width: 620, height: 110, availableHeight: 110,
                openExternal: { fixture.external.append($0) }, openExecution: fixture.presentation.openNoteExecution)
                .frame(height: 110)
            if fixture.presentation.selected != nil {
                let actions = HarnessThreadActions(interrupt: {}, respond: { _ in }, invokeHarnessExtension: { _, _ in .null },
                    forkThread: { _ in "unused" }, openExternal: { _ in }, openFollowUp: { _ in })
                let context = HarnessRenderContext(content: .manifest, presentation: .main(excludedExecutionIDs: []),
                    contentResource: fixture.resource, onIndexChange: { _ in })
                if let view = try? fixture.plugin.threadView(input: .init(thread: fixture.thread, readingTarget: fixture.presentation.readingTarget), actions: actions, context: context) {
                    ThreadDetailFrame(navigation: fixture.back, onNavigationChange: { fixture.presentation.navigation = $0 }) {
                        view
                    }.id(fixture.presentation.navigationRouteID)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            NativeWindowNavigationView(action: fixture.presentation.navigation, managesNativeButtons: false)
        }
        .environment(\.nativeReadingInteractions, fixture.controls)
        .environment(\.nativeReadingInteractionVisit, fixture.visit)
        .environment(\.nativeReadingInteractionRefresh, fixture.controls.refresh)
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeMokuExecutionLinkTests {
    private func element(id: String, in root: NSView) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func find(_ object: AnyObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(object)).inserted, seen.count < 10000, let object = object as? NSObject else { return nil }
            let identifier = NSSelectorFromString("accessibilityIdentifier")
            if object.responds(to: identifier), object.perform(identifier)?.takeUnretainedValue() as? String == id { return object }
            let children = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: children), let values = object.perform(children)?.takeUnretainedValue() as? [AnyObject] {
                for value in values { if let found = find(value) { return found } }
            }
            // Some SwiftUI bridge nodes publish children only through legacy AX.
            let legacy = NSSelectorFromString("accessibilityAttributeValue:")
            if object.responds(to: legacy), let values = object.perform(legacy, with: "AXChildren")?.takeUnretainedValue() as? [AnyObject] {
                for value in values { if let found = find(value) { return found } }
            }
            if let view = object as? NSView {
                for child in view.subviews { if let found = find(child) { return found } }
            }
            return nil
        }
        _ = root.window?.accessibilityChildren()
        return find(root.window ?? root)
    }
    private func back(in root: NSView) async throws {
        try await SwiftUIReplay.wait { element(id: "window-navigation.back", in: root) != nil }
        let button = try #require(element(id: "window-navigation.back", in: root))
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
    }
    private func textViews(_ root: NSView) -> [NSTextView] {
        (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap(textViews)
    }
    private func click(_ label: String, in root: NSView) throws {
        let view = try #require(textViews(root).first { $0.string.contains(label) })
        let index = (view.string as NSString).range(of: label).location
        let link = try #require(view.textStorage?.attribute(.link, at: index, effectiveRange: nil))
        #expect(view.delegate?.textView?(view, clickedOnLink: link, at: index) == true)
    }
    private func ready(_ fixture: ExecutionLinkFixture) async throws {
        do { try await SwiftUIReplay.wait {
            fixture.scroll?["value"]?["locatedRequestId"] == fixture.presentation.readingTarget.map { .string($0.requestID) }
                && fixture.scroll?["pending"] == .bool(false)
        } } catch {
            print("READING DEBUG", fixture.harness, fixture.scroll?["value"]?["locatedRequestId"]?.stringValue ?? "not located", fixture.scroll?["value"]?["top"]?.numberValue ?? -1)
            throw error
        }
    }

    @Test(arguments: ["codex", "claude", "pi", "opencode"], ["prior", "target", "missing"])
    func noteResultBackClosesTheRouteAndReopeningStillLoads(harness: String, execution: String) async throws {
        let fixture = try ExecutionLinkFixture(harness)
        fixture.noteText = "[View result](mokusei://execution?threadId=ordinary&executionId=\(execution))"
        fixture.load()
        let window = SwiftUIReplay.window(ExecutionLinkSurface(fixture: fixture), width: 700, height: 640, offscreen: true)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { textViews(root).contains { $0.string.contains("View result") } }
        for attempt in 0..<2 {
            try click("View result", in: root)
            try await SwiftUIReplay.wait { fixture.conversation?["destination"] == .text(execution == "missing" ? "unavailable" : "history") }
            if execution != "missing" { try await ready(fixture) }
            try await SwiftUIReplay.wait { fixture.presentation.navigation != nil }
            #expect(fixture.presentation.navigation?.label == "Back to overview")
            if attempt == 0 { try await back(in: root) }
            else {
                // Escape and the document's close action use the same callback.
                // The document control is only exposed once the opening motion
                // settles; operating it mid-travel is deliberately unavailable.
                try await SwiftUIReplay.wait {
                    fixture.controls.snapshot(visit: fixture.visit).contains { $0["role"] == .text("history.close") }
                }
                let close = try #require(fixture.controls.snapshot(visit: fixture.visit).first { $0["role"] == .text("history.close") })
                try fixture.perform(close, "activate")
            }
            try await SwiftUIReplay.wait { fixture.presentation.selected == nil && fixture.presentation.navigation == nil }
            #expect(fixture.presentation.readingTarget == nil)
            #expect(fixture.workspace.preferences.selectedThreadID == nil)
        }
        window.close(); await fixture.close()
    }

    @Test(arguments: ["codex", "claude", "pi", "opencode"])
    func ordinaryHistoryBackRestoresCurrentBeforeClosingTheRoute(harness: String) async throws {
        let fixture = try ExecutionLinkFixture(harness)
        fixture.load()
        fixture.presentation.open(.init(threadID: "ordinary", typeID: "agent"))
        let window = SwiftUIReplay.window(ExecutionLinkSurface(fixture: fixture), width: 700, height: 640, offscreen: true)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { fixture.conversation?["destination"] == .text("current") }
        let current = try #require(fixture.controls.snapshot(visit: fixture.visit).first { $0["role"] == .text("history.sidebar") }?["value"]?["currentRow"])
        let prior = try #require(fixture.controls.snapshot(visit: fixture.visit).first { $0["role"] == .text("history.open") })
        try fixture.perform(prior, "activate")
        try await SwiftUIReplay.wait {
            fixture.conversation?["destination"] == .text("history") && fixture.conversation?["transitioning"] == .bool(false)
                && fixture.presentation.navigation?.label != "Back to overview"
        }
        try await back(in: root)
        try await SwiftUIReplay.wait {
            fixture.conversation?["destination"] == .text("current") && fixture.presentation.navigation?.label == "Back to overview"
        }
        #expect(fixture.presentation.selected?.threadID == "ordinary")
        #expect(fixture.conversation?["selectedRow"] == current)
        try await SwiftUIReplay.wait { fixture.controls.snapshot(visit: fixture.visit).contains { $0["role"] == .text("turn") && $0["value"]?["executionId"] == .text("target") && $0["value"]?["state"] == .text("ready") } }
        try await back(in: root)
        try await SwiftUIReplay.wait { fixture.presentation.selected == nil }
        window.close(); await fixture.close()
    }

    @Test(arguments: ["codex", "claude", "pi", "opencode"])
    func noteClickLoadsExactResultAndNeverFollowsASuccessor(harness: String) async throws {
        let fixture = try ExecutionLinkFixture(harness)
        try fixture.update(archived: true)
        let body = fixture.thread.sessionState
        fixture.thread = try fixture.thread.replacingSessionState(.null)
        let window = SwiftUIReplay.window(ExecutionLinkSurface(fixture: fixture), width: 700, height: 640, offscreen: true)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { textViews(root).contains { $0.string.contains("View result") } }
        try click("View result", in: root)
        #expect(fixture.presentation.selected?.threadID == "ordinary")
        #expect(fixture.presentation.readingTarget?.executionID == "target")
        try await SwiftUIReplay.wait {
            fixture.controls.snapshot(visit: fixture.visit).contains { $0["role"] == .text("conversation") && $0["value"]?["destination"] == .text("unavailable") }
        }
        fixture.thread = try fixture.thread.replacingSessionState(body)
        try await SwiftUIReplay.wait { !fixture.resources.isEmpty }
        #expect(fixture.scroll?["value"]?["locatedRequestId"] == .null || fixture.scroll == nil)
        fixture.load()
        try await ready(fixture)
        try await SwiftUIReplay.wait { (fixture.scroll?["value"]?["top"]?.numberValue ?? 0) > 80 }
        let value = try #require(fixture.scroll?["value"])
        #expect((value["height"]?.numberValue ?? 0) - (value["top"]?.numberValue ?? 0) - (value["viewport"]?.numberValue ?? 0) > 400)
        #expect(value["following"] == .bool(false))
        let request = fixture.presentation.readingTarget?.requestID
        try fixture.update(successor: true)
        try await Task.sleep(for: .milliseconds(160))
        #expect(fixture.presentation.readingTarget?.executionID == "target")
        #expect(fixture.scroll?["value"]?["following"] == .bool(false))
        try click("View result", in: root)
        #expect(fixture.presentation.readingTarget?.requestID != request)
        try await ready(fixture)
        #expect(fixture.external.isEmpty)
        window.close(); await fixture.close()
    }

    @Test(arguments: ["codex", "claude", "pi", "opencode"])
    func runningLinkFollowsUntilUserScrollsAndJumpLatestRestoresIt(harness: String) async throws {
        let fixture = try ExecutionLinkFixture(harness)
        try fixture.update(status: .running)
        fixture.load()
        let window = SwiftUIReplay.window(ExecutionLinkSurface(fixture: fixture), width: 700, height: 640, offscreen: true)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { textViews(root).contains { $0.string.contains("View result") } }
        try click("View result", in: root)
        try await ready(fixture)
        #expect(fixture.scroll?["value"]?["following"] == .bool(true))
        let oldHeight = fixture.scroll?["value"]?["height"]?.numberValue ?? 0
        // Paged streaming publishes only closed top-level Markdown blocks, so a
        // reply that never ends a block (one long paragraph) presents nothing
        // until it completes. Stream blank-line-separated blocks so the reply
        // grows at page flushes, and assert that the mounted text view contains
        // the flushed content before checking follow position.
        try fixture.update(status: .running, text: String(repeating: "STREAMING CONTENT\n\n", count: 200))
        try await SwiftUIReplay.wait { textViews(root).contains { $0.string.contains("STREAMING CONTENT") } }
        try await SwiftUIReplay.wait { (fixture.scroll?["value"]?["height"]?.numberValue ?? 0) > oldHeight }
        try await SwiftUIReplay.wait {
            guard let value = fixture.scroll?["value"], let h = value["height"]?.numberValue,
                  let y = value["top"]?.numberValue, let v = value["viewport"]?.numberValue else { return false }
            return h - y - v < 5
        }
        try fixture.perform(#require(fixture.scroll), "scrollTo", .number(0))
        try await SwiftUIReplay.wait { fixture.scroll?["value"]?["following"] == .bool(false) && fixture.scroll?["pending"] == .bool(false) }
        try fixture.update(status: .running, text: String(repeating: "NEW STREAMING CONTENT\n\n", count: 220))
        try await Task.sleep(for: .milliseconds(200))
        #expect((fixture.scroll?["value"]?["top"]?.numberValue ?? 100) < 5)
        let jump = try #require(fixture.controls.snapshot(visit: fixture.visit).first { $0["role"] == .text("jumpLatest") })
        try fixture.perform(jump, "activate")
        try await SwiftUIReplay.wait { fixture.scroll?["value"]?["following"] == .bool(true) }
        try fixture.update(status: .completed, successor: true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.presentation.readingTarget?.executionID == "target")
        window.close(); await fixture.close()
    }

    @Test(arguments: ["codex", "claude", "pi", "opencode"], [PublicExecution.Status.failed, .interrupted])
    func failureAndEmptyExecutionRemainReadableAndMissingTargetsAreExplicit(harness: String, status: PublicExecution.Status) async throws {
        let fixture = try ExecutionLinkFixture(harness)
        try fixture.update(status: status, empty: true)
        fixture.load()
        let window = SwiftUIReplay.window(ExecutionLinkSurface(fixture: fixture), width: 700, height: 640, offscreen: true)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { textViews(root).contains { $0.string.contains("View result") } }
        try click("View result", in: root)
        #expect(fixture.presentation.selected?.threadID == "ordinary")
        try await ready(fixture)
        #expect(fixture.controls.snapshot(visit: fixture.visit).contains { $0["role"] == .text("turn") && $0["value"]?["executionId"] == .text("target") && $0["value"]?["state"] == .text("ready") })
        fixture.presentation.openNoteExecution(.init(thread: .init(threadID: "ordinary", typeID: "agent"), executionID: "missing"))
        try await SwiftUIReplay.wait {
            fixture.controls.snapshot(visit: fixture.visit).contains { $0["role"] == .text("conversation") && $0["value"]?["destination"] == .text("unavailable") }
        }
        let request = fixture.presentation.readingTarget
        fixture.presentation.openNoteExecution(.init(thread: .init(threadID: "deleted", typeID: "agent"), executionID: "target"))
        #expect(fixture.presentation.readingTarget == request)
        #expect(fixture.workspace.localizedOperationError != nil)
        window.close(); await fixture.close()
    }
    @Test func noteLinksStayInternalAndRejectMalformedOrNonOrdinaryTargets() async throws {
        let fixture = try ExecutionLinkFixture("codex")
        fixture.noteText = "[Valid](mokusei://execution?threadId=ordinary&executionId=target) " +
            "[Duplicate](mokusei://execution?threadId=ordinary&executionId=target&threadId=other) " +
            "[Credentials](mokusei://user@execution?threadId=ordinary&executionId=target) " +
            "[Website](https://example.com/result)"
        let window = SwiftUIReplay.window(ExecutionLinkSurface(fixture: fixture), width: 700, height: 640, offscreen: true)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { textViews(root).contains { $0.string.contains("Duplicate") } }
        for label in ["Duplicate", "Credentials"] {
            let text = try #require(textViews(root).first { $0.string.contains(label) })
            let index = (text.string as NSString).range(of: label).location
            #expect(text.textStorage?.attribute(.link, at: index, effectiveRange: nil) == nil)
        }
        try click("Website", in: root)
        #expect(fixture.external.map(\.absoluteString) == ["https://example.com/result"])
        let generic = SwiftUIReplay.window(NativeMarkdownView(text: "[Internal](mokusei://execution?threadId=ordinary&executionId=target)",
            openExternal: { fixture.external.append($0) }), offscreen: true)
        defer { generic.close() }
        let genericRoot = try #require(generic.contentView)
        try await SwiftUIReplay.wait { textViews(genericRoot).contains { $0.string.contains("Internal") } }
        try click("Internal", in: genericRoot)
        #expect(fixture.external.count == 1)
        for history in [false, true] {
            let thread = try HarnessThread(id: "private-target", harnessID: "codex", revision: 0, sessionState: .null,
                observation: .init(), cwd: "", settings: .object([:]), createdAt: 1, updatedAt: 1, title: "Moku", tags: [],
                archived: history ? true : nil, moku: history ? nil : true, mokuHistory: history,
                transcript: history ? nil : .array([]))
            try fixture.workspace.catalog.install(.object(["revision": .integer(history ? 3 : 2), "settingsRevision": .integer(0),
                "defaultCwd": .text(""), "settings": .object([:]), "threads": .array([thread.json]),
                "executions": .array([]), "applicationThreads": .array([])]))
            fixture.presentation.openNoteExecution(.init(thread: .init(threadID: "private-target", typeID: "agent"), executionID: "target"))
            #expect(fixture.presentation.selected == nil && !fixture.presentation.scene.mokuOpen)
            #expect(fixture.workspace.localizedOperationError != nil)
        }
        generic.close(); window.close(); await fixture.close()
    }

}

// These production Host/lifetime checks need no NSApplication or WindowServer.
@MainActor @Suite(.serializedNative)
struct NativeMokuExecutionLinkRoutingTests {
    @Test(arguments: ["codex", "claude", "pi", "opencode"], ["prior", "target", "missing"])
    func noteRoutesStayExactAndDoNotLeakIntoOrdinaryVisits(harness: String, execution: String) async throws {
        let fixture = try ExecutionLinkFixture(harness)
        let thread = ApplicationThreadRef(threadID: "ordinary", typeID: "agent")
        let reference = ApplicationExecutionRef(thread: thread, executionID: JSONText(execution))
        fixture.presentation.openNoteExecution(reference)
        let target = try #require(fixture.presentation.readingTarget)
        #expect(fixture.presentation.selected == thread)
        #expect(target.executionID == reference.executionID && target.position == .result && target.mode == .history)
        try fixture.update(successor: true)
        #expect(fixture.presentation.readingTarget == target)
        fixture.presentation.finishBack()
        #expect(fixture.presentation.selected == nil && fixture.presentation.readingTarget == nil)
        #expect(fixture.workspace.preferences.selectedThreadID == nil)
        fixture.presentation.openNoteExecution(reference)
        #expect(fixture.presentation.readingTarget?.requestID != target.requestID)
        fixture.presentation.finishBack()
        fixture.presentation.open(thread)
        #expect(fixture.presentation.selected == thread && fixture.presentation.readingTarget == nil)
        fixture.presentation.openExecution(.init(thread: thread, executionID: "prior"))
        #expect(fixture.presentation.readingTarget?.mode == .history && fixture.presentation.readingTarget?.position == .start)
        fixture.presentation.openExecution(.init(thread: thread, executionID: "successor"))
        #expect(fixture.presentation.readingTarget?.mode == .current && fixture.presentation.readingTarget?.position == .start)
        fixture.presentation.finishBack()
        await fixture.close()
    }

    @Test(arguments: [HarnessContentScope.thread, .row("target"), .execution("target")])
    func concurrentConsumersKeepIndependentProductionResources(scope: HarnessContentScope) async throws {
        let fixture = try ExecutionLinkFixture("codex")
        let surface = try fixture.workspace.harnessHost.makeThreadSurface(input: .init(thread: fixture.thread))
        let current = surface.contentResource(scope)
        let result = surface.contentResource(scope)
        current.publish(.ready(fixture.thread.sessionState))
        result.publish(.ready(fixture.thread.sessionState))
        result.beginRelease()
        #expect(!current.isReleased)
        guard case .ready = current.state else {
            Issue.record("Closing the result page revoked the retained current document")
            await surface.release(); await fixture.close(); return
        }
        let replacement = surface.contentResource(scope)
        #expect(replacement !== current && replacement !== result)
        await surface.release()
        #expect(current.isReleased && replacement.isReleased)
        await fixture.close()
    }
}
