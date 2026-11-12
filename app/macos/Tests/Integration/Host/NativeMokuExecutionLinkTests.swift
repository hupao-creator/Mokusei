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
                archived: Bool = false, empty: Bool = false, messageStatus: String? = nil,
                pendingText: String? = nil, mixedParts: Bool = false) throws {
        revision += 1
        let executions = try [("prior", PublicExecution.Status.completed), ("target", status)]
            .enumerated().map { index, entry in
                try PublicExecution(executionID: JSONText(entry.0), status: entry.1, startedAt: Double(index * 10 + 1),
                    finishedAt: [.running, .waitingForUser].contains(entry.1) ? nil : Double(index * 10 + 5),
                    interactions: entry.1 == .waitingForUser ? [.init(id: "approval", kind: .permission,
                        title: "Waiting fixture approval", actions: [.init(id: "allow", intent: .allow, label: "Allow")], questions: [])] : [])
            } + (successor ? [try PublicExecution(executionID: "successor", status: .running, startedAt: 21)] : [])
        let answer = text ?? "TARGET RESULT\n\n" + String(repeating: "A long result paragraph with enough detail to scroll.\n\n", count: 65)
        let raw = state(executions, answer: answer, empty: empty, messageStatus: messageStatus, pendingText: pendingText, mixedParts: mixedParts)
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
    private func state(_ executions: [PublicExecution], answer: String, empty: Bool,
                       messageStatus: String?, pendingText: String?, mixedParts: Bool) -> JSONValue {
        let turns: [JSONValue] = executions.map { execution in
            let id = execution.executionID.string
            let body = id == "target" ? answer : "OTHER EXECUTION \(id)"
            let running = [.running, .waitingForUser].contains(execution.status)
            let status = id == "target" ? messageStatus ?? (running ? "streaming" : "complete") : "complete"
            if harness == "pi" || harness == "opencode" { return execution.json }
            var turn: [JSONText: JSONValue] = ["executionId": .text(id), "createdAt": .number(execution.startedAt),
                "updatedAt": .number(execution.startedAt + 4), "status": .text(running ? "running" : execution.status.rawValue),
                "reasoning": .text(""), "plan": .array([]), "activities": .array([]), "interactions": .array([]), "notices": .array([])]
            if let finished = execution.finishedAt { turn["finishedAt"] = .number(finished) }
            var item: [JSONText: JSONValue] = ["id": .text(id + "-answer"), "kind": .text("assistant"), "content": .text(body),
                "status": .text(status), "createdAt": .number(execution.startedAt + 1)]
            if harness == "codex" { item["itemId"] = .text(id + "-native") }
            var items: [JSONValue] = empty && id == "target" ? [] : [.object(item)]
            if id == "target", let pendingText {
                var pending = item
                pending["id"] = .text(id + "-pending")
                if harness == "codex" { pending["itemId"] = .text(id + "-pending-native") }
                pending["content"] = .text(pendingText)
                pending["status"] = .text(running ? "streaming" : "complete")
                items.append(.object(pending))
            }
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
            let messages: [JSONValue] = executions.flatMap { execution -> [JSONValue] in
                let id = execution.executionID.string
                if empty && id == "target" { return [] }
                let text = id == "target" ? answer : "OTHER EXECUTION \(id)"
                var message: [JSONText: JSONValue] = ["id": .text(id + "-answer"), "executionId": .text(id), "role": .text("assistant"),
                    "text": .text(text), "status": .text(id == "target" ? messageStatus ?? ([.running, .waitingForUser].contains(execution.status) ? "streaming" : "complete") : "complete")]
                if harness == "opencode" {
                    message["parts"] = .array([
                        .object(["type": .text("text"), "ordinal": .integer(0), "text": .text(text)]),
                        .object(["type": .text("text"), "ordinal": .integer(1), "text": .text("Final reply second part")])])
                    if id == "target", mixedParts {
                        message["parts"] = .array([
                            .object(["type": .text("text"), "ordinal": .integer(0), "text": .text(text)]),
                            .object(["type": .text("reasoning"), "ordinal": .integer(1), "text": .text("REASONING RECORD")]),
                            .object(["type": .text("tool"), "toolCallId": .text("fixture-tool")])])
                        let tool: JSONValue = .object(["id": .text(id + "-answer:tool:fixture-tool"),
                            "executionId": .text(id), "role": .text("tool"), "text": .text("TOOL RECORD"),
                            "status": .text("complete"), "toolCallId": .text("fixture-tool"), "toolName": .text("Fixture tool")])
                        return [.object(message), tool]
                    }
                }
                if id == "target", let pendingText {
                    var pending = message
                    pending["id"] = .text(id + "-pending")
                    pending["text"] = .text(pendingText)
                    pending["status"] = .text([.running, .waitingForUser].contains(execution.status) ? "streaming" : "complete")
                    if harness == "opencode" {
                        pending["parts"] = .array([.object(["type": .text("text"), "ordinal": .integer(0), "text": .text(pendingText)])])
                    }
                    return [.object(message), .object(pending)]
                }
                return [.object(message)]
            }
            var raw: [JSONText: JSONValue] = ["version": .integer(1), "messages": .array(messages), "executions": .array(turns),
                                              "latestExecutionId": .string(executions.last!.executionID)]
            if harness == "opencode" { raw["interactions"] = .array([]) }
            return .object(raw)
        }
    }
}

@MainActor private final class ExecutionLinkEditingTextView: NSTextView {
    var cancellations = 0
    override func cancelOperation(_ sender: Any?) { cancellations += 1 }
}

private struct ExecutionLinkSurface: View {
    let fixture: ExecutionLinkFixture
    var body: some View {
        VStack(spacing: 0) {
            NativeMokuNoteContent(note: .init(id: "note", text: fixture.noteText, revision: 1, updatedAt: 1),
                width: 620, height: 110, availableHeight: 110,
                openExternal: { fixture.external.append($0) }, openExecution: fixture.presentation.openNoteExecution, workspace: fixture.workspace)
                .frame(height: 110)
            if fixture.presentation.selected != nil {
                let actions = HarnessThreadActions(interrupt: {}, respond: { _ in }, invokeHarnessExtension: { _, _ in .null },
                    forkThread: { _ in "unused" }, openExternal: { _ in }, openFollowUp: { _ in })
                let context = HarnessRenderContext(content: .manifest, presentation: .main(excludedExecutionIDs: []),
                    contentResource: fixture.resource, onIndexChange: { _ in })
                if let view = try? fixture.plugin.threadView(input: .init(thread: fixture.thread, readingTarget: fixture.presentation.readingTarget), actions: actions, context: context) {
                    ThreadDetailFrame(navigation: fixture.back, onNavigationChange: { fixture.presentation.navigation = $0 }) {
                        view
                    }
                    .nativeReadingPanelClose(label: "Close thread", onClose: fixture.presentation.finishBack)
                    .id(fixture.presentation.navigationRouteID)
                }
            }
        }
        .environment(\.nativeReadingInteractions, fixture.controls)
        .environment(\.nativeReadingInteractionVisit, fixture.visit)
        .environment(\.nativeReadingInteractionRefresh, fixture.controls.refresh)
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeMokuExecutionLinkTests {
    private func element(id: String, nativeOnly: Bool = false, label: String? = nil, in root: NSView) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func find(_ object: AnyObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(object)).inserted, seen.count < 10000, let object = object as? NSObject else { return nil }
            let identifier = NSSelectorFromString("accessibilityIdentifier")
            if object.responds(to: identifier), object.perform(identifier)?.takeUnretainedValue() as? String == id {
                let selector = NSSelectorFromString("accessibilityLabel")
                if label == nil || (object.responds(to: selector)
                    && (object.perform(selector)?.takeUnretainedValue() as? String)?.contains(label!) == true) { return object }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: children), let values = object.perform(children)?.takeUnretainedValue() as? [AnyObject] {
                for value in values { if let found = find(value) { return found } }
            }
            // Some SwiftUI bridge nodes publish children only through legacy AX.
            let legacy = NSSelectorFromString("accessibilityAttributeValue:")
            if object.responds(to: legacy), let values = object.perform(legacy, with: "AXChildren")?.takeUnretainedValue() as? [AnyObject] {
                for value in values { if let found = find(value) { return found } }
            }
            if !nativeOnly, let view = object as? NSView {
                for child in view.subviews { if let found = find(child) { return found } }
            }
            return nil
        }
        _ = root.window?.accessibilityChildren()
        return find(root.window ?? root)
    }
    private func closePanel(in root: NSView) async throws {
        try await SwiftUIReplay.wait { element(id: "reading-panel-close", in: root) != nil }
        let button = try #require(element(id: "reading-panel-close", in: root))
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
    }
    private func escape(in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            NSApp.sendEvent(event)
        }
    }
    private func textViews(_ root: NSView) -> [NSTextView] {
        (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap(textViews)
    }
    private func replyCopies(_ phrase: String, in root: NSView) throws -> [Int] {
        let views = textViews(root).filter { $0.string.contains(phrase) }
        // Current and history documents can retain the same reply at once.
        // Require a complete copy in each owning viewport, never an aggregate.
        let pages = try Dictionary(grouping: views) { ObjectIdentifier(try #require($0.enclosingScrollView)) }
        return pages.values.map { $0.reduce(0) { $0 + $1.string.components(separatedBy: phrase).count - 1 } }
    }
    private func click(_ label: String, in root: NSView) throws {
        if let capsule = element(id: "moku-note-execution-link", nativeOnly: true, label: label, in: root) {
            _ = capsule.perform(NSSelectorFromString("accessibilityPerformPress"))
            return
        }
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

    @Test(arguments: ["codex", "claude", "pi", "opencode"])
    func noteCapsulesWrapCopyAndRefreshTheirHarnessWithoutChangingTheNote(harness: String) async throws {
        try #require(NSApp?.isRunning == true, "The capsule input case requires its declared AppKit replay owner")
        let fixture = try ExecutionLinkFixture(harness)
        let title = "检查长标题连续换行，保留执行引用的关键信息 e\u{301} 与 👩🏽‍💻"
        let note = NativeMokuNote(id: "same-note", text: "参考 [Website](https://example.com)；已完成 [\(title)](mokusei://execution?threadId=ordinary&executionId=target)。\n\n[Plain](https://example.com/plain)", revision: 1, updatedAt: 1)
        let window = SwiftUIReplay.window(NativeMokuNoteContent(note: note, width: 280, height: 350,
            availableHeight: 350, openExternal: { fixture.external.append($0) },
            openExecution: fixture.presentation.openNoteExecution, workspace: fixture.workspace), width: 280, height: 350, offscreen: true)
        defer { window.close() }
        let root = try #require(window.contentView)
        func attachments() -> [MarkdownExecutionAttachment] {
            textViews(root).flatMap { view in
                var found: [MarkdownExecutionAttachment] = []
                if let storage = view.textStorage {
                    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                        if let attachment = value as? MarkdownExecutionAttachment { found.append(attachment) }
                    }
                }
                return found
            }
        }
        try await SwiftUIReplay.wait { element(id: "moku-note-execution-link", nativeOnly: true, label: title, in: root) != nil }
        let capsule = try #require(attachments().first)
        #expect(attachments().count == 1)
        #expect(capsule.harness?.descriptor.id == JSONText(harness))
        #expect(capsule.size.width <= 244)
        #expect(capsule.size.height > 30)
        let text = try #require(textViews(root).first { $0.string.contains("Website") } as? MarkdownTextView)
        let website = (text.string as NSString).range(of: "Website")
        #expect(text.textStorage?.attribute(.link, at: website.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
        #expect((text.linkTextAttributes?[.underlineStyle] as? Int) == NSUnderlineStyle.single.rawValue)
        let plain = try #require(textViews(root).first { $0.string == "Plain" })
        let paragraph = try #require(plain.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.maximumLineHeight == 13 * 1.8)
        window.makeFirstResponder(text)
        text.selectAll(nil); text.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "参考 Website；已完成 \(title)。\nPlain")
        let hosts = text.subviews.compactMap { $0 as? MarkdownExecutionHost }
        #expect(hosts.count == 1)
        let host = try #require(hosts.first)
        #expect(host.frame.minX >= -1 && host.frame.maxX <= text.bounds.width + 1)
        #expect(host.frame.minY >= -1 && host.frame.maxY <= text.bounds.height + 1)
        #expect(host.hitTest(NSPoint(x: host.bounds.midX, y: host.bounds.midY)) == nil)

        func publish(_ threads: [JSONValue], revision: Int) throws {
            try fixture.workspace.catalog.install(.object(["revision": .integer(revision), "settingsRevision": .integer(0),
                "defaultCwd": .text(""), "settings": .object([:]), "threads": .array(threads),
                "executions": .array([]), "applicationThreads": .array([])]))
        }
        try publish([], revision: 2)
        try await SwiftUIReplay.wait { attachments().count == 1 && attachments().first?.harness == nil }
        #expect(element(id: "moku-note-execution-link", nativeOnly: true, label: title, in: root) != nil)
        text.executionLocale = Locale(identifier: "zh-CN")
        try await SwiftUIReplay.wait { element(id: "moku-note-execution-link", nativeOnly: true, label: "执行记录 ·", in: root) != nil }
        text.executionLocale = Locale(identifier: "en-US")
        try await SwiftUIReplay.wait { element(id: "moku-note-execution-link", nativeOnly: true, label: "Execution ·", in: root) != nil }
        var unknown = try #require(fixture.thread.json.objectValue)
        unknown["harnessId"] = .text("not-registered")
        try publish([.object(unknown)], revision: 3)
        try await SwiftUIReplay.wait { attachments().first?.harness == nil }
        try publish([fixture.thread.json], revision: 4)
        try await SwiftUIReplay.wait { attachments().first?.harness?.descriptor.id == JSONText(harness) }
        #expect(text.subviews.contains { $0 === host })
        try click("Website", in: root)
        #expect(fixture.external == [URL(string: "https://example.com")!])
        try click(title, in: root)
        #expect(fixture.presentation.readingTarget?.executionID == "target")
        fixture.presentation.finishBack()
        let storage = try #require(text.textStorage)
        var linkRange: NSRange?
        storage.enumerateAttribute(.nativeMarkdownExecution, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { linkRange = range }
        }
        let range = try #require(linkRange)
        text.setSelectedRange(range)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        text.keyDown(with: enter)
        #expect(fixture.presentation.readingTarget?.executionID == "target")
        // The mandatory AppKit owner supplies NSTextView's tracking loop.
        fixture.presentation.finishBack()
        let layout = try #require(text.layoutManager), container = try #require(text.textContainer)
        let box = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let point = text.convert(NSPoint(x: box.midX + text.textContainerOrigin.x, y: box.midY + text.textContainerOrigin.y), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        text.mouseDown(with: down)
        #expect(fixture.presentation.readingTarget?.executionID == "target")
        print("MOKU_NOTE_EXECUTION_CAPSULES_CONFIRMED")
        window.close(); await fixture.close()
    }

    @Test(arguments: ["codex", "claude", "pi", "opencode"], ["prior", "target", "missing"])
    func noteResultPanelCloseExitsAndReopeningStillLoads(harness: String, execution: String) async throws {
        let fixture = try ExecutionLinkFixture(harness)
        try fixture.update(successor: execution != "target", archived: true)
        fixture.noteText = "[View result](mokusei://execution?threadId=ordinary&executionId=\(execution))"
        fixture.load()
        let window = SwiftUIReplay.window(ExecutionLinkSurface(fixture: fixture), width: 700, height: 640, offscreen: true)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { element(id: "moku-note-execution-link", nativeOnly: true, label: "View result", in: root) != nil }
        for attempt in 0..<2 {
            try click("View result", in: root)
            try await SwiftUIReplay.wait { fixture.conversation?["destination"] == .text(execution == "missing" ? "unavailable" : "history") }
            if execution != "missing" { try await ready(fixture) }
            try await SwiftUIReplay.wait { fixture.presentation.navigation != nil }
            #expect(fixture.presentation.navigation?.label == "Back to overview")
            if attempt == 0 { try await closePanel(in: root) }
            else {
                // Wait for the document to be active before sending actual
                // Escape events through AppKit's responder chain.
                try await SwiftUIReplay.wait {
                    fixture.controls.snapshot(visit: fixture.visit).contains { $0["role"] == .text("history.close") }
                }
                if execution == "target" {
                    // Place the sibling at the TOC edge, outside the document
                    // viewport regardless of the hosting view's flipped Y axis.
                    let sibling = ExecutionLinkEditingTextView(frame: .init(x: 0, y: 0, width: 32, height: 30))
                    sibling.isEditable = false
                    sibling.isSelectable = true
                    sibling.string = "Sibling control"
                    root.addSubview(sibling)
                    #expect(window.makeFirstResponder(sibling))
                    #expect(window.firstResponder === sibling)
                    try escape(in: window)
                    #expect(sibling.cancellations == 1)
                    #expect(fixture.presentation.selected != nil)
                    sibling.removeFromSuperview()
                    let editor = ExecutionLinkEditingTextView(frame: .init(x: 0, y: 0, width: 240, height: 60))
                    editor.isEditable = true
                    editor.string = "An inline draft owns its cancellation"
                    root.addSubview(editor)
                    #expect(window.makeFirstResponder(editor))
                    try escape(in: window)
                    #expect(editor.cancellations == 1)
                    #expect(fixture.presentation.selected != nil)
                    editor.removeFromSuperview()
                    #expect(window.makeFirstResponder(root))
                }
                try escape(in: window)
            }
            do {
                try await SwiftUIReplay.wait { fixture.presentation.selected == nil && fixture.presentation.navigation == nil }
            } catch {
                print("EXECUTION ENTRY BACK", harness, execution, "attempt", attempt,
                      "selected", fixture.presentation.selected?.threadID.string as Any,
                      "navigation", fixture.presentation.navigation?.label as Any,
                      "destination", fixture.conversation?["destination"]?.stringValue as Any,
                      "responder", window.firstResponder as Any,
                      "focus", (window.accessibilityFocusedUIElement as? any NSAccessibilityProtocol)?.accessibilityLabel() as Any,
                      "focusFrame", (window.accessibilityFocusedUIElement as? any NSAccessibilityProtocol)?.accessibilityFrame() as Any)
                throw error
            }
            #expect(fixture.presentation.readingTarget == nil)
            #expect(fixture.workspace.preferences.selectedThreadID == nil)
        }
        window.close(); await fixture.close()
    }

    @Test(arguments: ["codex", "claude", "pi", "opencode"], [false, true])
    func startPositionEntryCloseExitsForOldCurrentAndMissingExecutions(harness: String, archived: Bool) async throws {
        let fixture = try ExecutionLinkFixture(harness)
        // Establish the successor before opening: target is already historical,
        // rather than becoming old only after a direct visit has begun.
        try fixture.update(successor: true, archived: archived)
        fixture.load()
        let window = SwiftUIReplay.window(ExecutionLinkSurface(fixture: fixture), width: 700, height: 640, offscreen: true)
        defer { window.close() }
        let root = try #require(window.contentView)
        let thread = ApplicationThreadRef(threadID: "ordinary", typeID: "agent")
        for execution in ["target", "successor", "missing"] {
            for entry in 0..<2 {
                if entry == 0 {
                    // Report relations and other application execution callbacks.
                    fixture.presentation.applicationHost.navigation.openExecution(.init(thread: thread, executionID: JSONText(execution)))
                } else {
                    // Exact host reading requests also arrive through openThread.
                    let target = try HarnessReadingTarget(json: .object([
                        "executionId": .text(execution), "requestId": .text(UUID().uuidString), "mode": .text("history")
                    ]))
                    fixture.presentation.applicationHost.navigation.openThread(thread, target)
                }
                #expect(fixture.presentation.selected == thread)
                #expect(fixture.presentation.readingTarget?.position == .start)
                let destination = execution == "missing" ? "unavailable" : execution == "successor" ? "current" : "history"
                try await SwiftUIReplay.wait {
                    fixture.conversation?["destination"] == .text(destination)
                        && fixture.conversation?["transitioning"] == .bool(false)
                        && fixture.presentation.navigation != nil
                }
                #expect(fixture.presentation.navigation?.label == "Back to overview")
                if entry == 1 && execution != "successor" {
                    let close = try #require(fixture.controls.snapshot(visit: fixture.visit).first { $0["role"] == .text("history.close") })
                    try fixture.perform(close, "activate")
                } else { try await closePanel(in: root) }
                try await SwiftUIReplay.wait { fixture.presentation.selected == nil && fixture.presentation.navigation == nil }
                #expect(fixture.presentation.readingTarget == nil && fixture.workspace.preferences.selectedThreadID == nil)
            }
        }
        window.close(); await fixture.close()
    }

    @Test(arguments: ["codex", "claude", "pi", "opencode"], [false, true])
    func selectingHistoryAfterDirectEntryRestoresInternalReturn(harness: String, result: Bool) async throws {
        let fixture = try ExecutionLinkFixture(harness)
        fixture.load()
        let reference = ApplicationExecutionRef(thread: .init(threadID: "ordinary", typeID: "agent"), executionID: "prior")
        if result { fixture.presentation.openNoteExecution(reference) }
        else { fixture.presentation.openExecution(reference) }
        let window = SwiftUIReplay.window(ExecutionLinkSurface(fixture: fixture), width: 700, height: 640, offscreen: true)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait {
            fixture.conversation?["destination"] == .text("history")
                && fixture.conversation?["transitioning"] == .bool(false)
                && fixture.presentation.navigation?.label == "Back to overview"
        }
        // Even reselecting the entry row is an explicit internal navigation.
        let selected = try #require(fixture.conversation?["selectedRow"])
        let row = try #require(fixture.controls.snapshot(visit: fixture.visit).first {
            $0["role"] == .text("history.open") && $0["value"] == selected
        })
        try fixture.perform(row, "activate")
        try await SwiftUIReplay.wait { fixture.presentation.navigation != nil && fixture.presentation.navigation?.label != "Back to overview" }
        let previousCurrent = try #require(fixture.controls.snapshot(visit: fixture.visit).first { $0["role"] == .text("history.sidebar") }?["value"]?["currentRow"])
        try fixture.update(successor: true)
        try await SwiftUIReplay.wait {
            fixture.controls.snapshot(visit: fixture.visit).contains { $0["role"] == .text("history.sidebar") && $0["value"]?["currentRow"] != previousCurrent }
                && fixture.conversation?["transitioning"] == .bool(false)
        }
        let historyClose = try #require(fixture.controls.snapshot(visit: fixture.visit).first { $0["role"] == .text("history.close") })
        try fixture.perform(historyClose, "activate")
        try await SwiftUIReplay.wait {
            fixture.conversation?["destination"] == .text("current")
                && fixture.conversation?["transitioning"] == .bool(false)
                && fixture.presentation.navigation?.label == "Back to overview"
        }
        #expect(fixture.presentation.selected == reference.thread)
        let current = try #require(fixture.controls.snapshot(visit: fixture.visit).first { $0["role"] == .text("history.sidebar") }?["value"]?["currentRow"])
        #expect(fixture.conversation?["selectedRow"] == current)
        try await closePanel(in: root)
        try await SwiftUIReplay.wait { fixture.presentation.selected == nil }
        window.close(); await fixture.close()
    }

    @Test(arguments: ["codex", "claude", "pi", "opencode"])
    func ordinaryHistoryReturnRestoresCurrentBeforePanelClose(harness: String) async throws {
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
        let historyClose = try #require(fixture.controls.snapshot(visit: fixture.visit).first { $0["role"] == .text("history.close") })
        try fixture.perform(historyClose, "activate")
        try await SwiftUIReplay.wait {
            fixture.conversation?["destination"] == .text("current") && fixture.presentation.navigation?.label == "Back to overview"
        }
        #expect(fixture.presentation.selected?.threadID == "ordinary")
        #expect(fixture.conversation?["selectedRow"] == current)
        try await SwiftUIReplay.wait { fixture.controls.snapshot(visit: fixture.visit).contains { $0["role"] == .text("turn") && $0["value"]?["executionId"] == .text("target") && $0["value"]?["state"] == .text("ready") } }
        try await closePanel(in: root)
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
        try await SwiftUIReplay.wait { element(id: "moku-note-execution-link", nativeOnly: true, label: "View result", in: root) != nil }
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

    @Test(arguments: ["codex", "claude", "pi", "opencode"], [false, true])
    func jumpLatestTracksExecutionLifecycle(harness: String, result: Bool) async throws {
        let fixture = try ExecutionLinkFixture(harness)
        @MainActor func scroll() -> JSONValue? {
            if result { return fixture.scroll }
            return fixture.controls.snapshot(visit: fixture.visit).first {
                $0["role"] == .text("timeline") && $0["id"]?.stringValue?.contains(".current.") == true
            }
        }
        let text = String(repeating: "A settled reply long enough to scroll.\n\n", count: 180)
        try fixture.update(text: text)
        fixture.load()
        if result {
            fixture.presentation.openNoteExecution(.init(thread: .init(threadID: "ordinary", typeID: "agent"), executionID: "target"))
        } else {
            fixture.presentation.open(.init(threadID: "ordinary", typeID: "agent"))
        }
        let window = SwiftUIReplay.window(ExecutionLinkSurface(fixture: fixture), width: 700, height: 640, offscreen: true)
        defer { window.close() }
        if result { try await ready(fixture) }
        try await SwiftUIReplay.wait { fixture.conversation?["transitioning"] == .bool(false) }
        for status in [PublicExecution.Status.completed, .running, .waitingForUser, .completed] {
            try fixture.update(status: status, text: text, messageStatus: "complete")
            if status == .completed {
                // Completion must revoke the mounted action without another scroll.
                try await SwiftUIReplay.wait {
                    !fixture.controls.snapshot(visit: fixture.visit).contains { $0["role"] == .text("jumpLatest") }
                }
            }
            try await SwiftUIReplay.wait { (scroll()?["value"]?["height"]?.numberValue ?? 0) > 1000 }
            try fixture.perform(#require(scroll()), "scrollTo", .number(0))
            try await SwiftUIReplay.wait {
                scroll()?["value"]?["showLatest"] == .bool(true)
                    && scroll()?["pending"] == .bool(false)
            }
            try await SwiftUIReplay.wait {
                fixture.controls.snapshot(visit: fixture.visit).contains { $0["role"] == .text("jumpLatest") }
                    == (status != .completed)
            }
        }
        if result {
            try fixture.update(text: text, successor: true)
            try await SwiftUIReplay.wait { fixture.conversation?["rowCount"] == .integer(3) }
            #expect(!fixture.controls.snapshot(visit: fixture.visit).contains { $0["role"] == .text("jumpLatest") })
        }
        window.close(); await fixture.close()
    }

    @Test(arguments: ["codex", "claude", "pi", "opencode"])
    func runningLinkFollowsUntilUserScrollsAndJumpLatestRestoresIt(harness: String) async throws {
        let fixture = try ExecutionLinkFixture(harness)
        try fixture.update(status: .running, mixedParts: true)
        fixture.load()
        let window = SwiftUIReplay.window(ExecutionLinkSurface(fixture: fixture), width: 700, height: 640, offscreen: true)
        defer { window.close() }
        let root = try #require(window.contentView)
        var receipts: [JSONValue] = []
        @MainActor func record(_ phase: String, inputBytes: Int? = nil) {
            receipts.append(.object([
                "phase": .text(phase), "at": .number(ProcessInfo.processInfo.systemUptime),
                "revision": .integer(fixture.revision),
                "inputUTF8Bytes": inputBytes.map { JSONValue.integer($0) } ?? .null,
                "scroll": fixture.scroll ?? .null
            ]))
        }
        defer {
            record("exit")
            do {
                let data = try JSONValue.object(["harness": .text(harness), "stages": .array(receipts)]).encodedData()
                FileHandle.standardOutput.write(Data("MOKU_EXECUTION_LINK_RECEIPTS ".utf8) + data + Data("\n".utf8))
            } catch {
                Issue.record(Comment(rawValue: "Could not encode execution-link receipts: \(error)"))
            }
        }
        try await SwiftUIReplay.wait { element(id: "moku-note-execution-link", nativeOnly: true, label: "View result", in: root) != nil }
        try click("View result", in: root)
        try await ready(fixture)
        #expect(fixture.scroll?["value"]?["following"] == .bool(true))
        if harness == "opencode" {
            // Withholding text in a mixed native message must preserve both
            // execution rows rather than dropping the whole message.
            #expect(fixture.controls.snapshot(visit: fixture.visit).contains {
                $0["role"] == .text("turn") && $0["value"]?["executionId"] == .text("target") && $0["value"]?["rowCount"] == .integer(2)
            })
        }
        let oldHeight = fixture.scroll?["value"]?["height"]?.numberValue ?? 0
        record("original")
        // Even enough closed blocks to fill several pages must stay withheld
        // until this message settles, independently of the execution status.
        let firstInput = String(repeating: "STREAMING CONTENT\n\n", count: 200)
        try fixture.update(status: .running, text: firstInput, mixedParts: true)
        record("first-source", inputBytes: firstInput.utf8.count)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!textViews(root).contains { $0.string.contains("STREAMING CONTENT") })
        #expect((fixture.scroll?["value"]?["height"]?.numberValue ?? 0) == oldHeight)
        #expect(fixture.thread.observation.latestExecution?.status == .running)
        try fixture.update(status: .waitingForUser, text: firstInput, mixedParts: true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!textViews(root).contains { $0.string.contains("STREAMING CONTENT") })
        #expect(fixture.thread.observation.latestExecution?.status == .waitingForUser)
        try fixture.update(status: .running, text: firstInput, messageStatus: "complete")
        try await SwiftUIReplay.wait { textViews(root).contains { $0.string.contains("STREAMING CONTENT") } }
        #expect(try replyCopies("STREAMING CONTENT", in: root).allSatisfy { $0 == 200 })
        try await SwiftUIReplay.wait { (fixture.scroll?["value"]?["height"]?.numberValue ?? 0) > oldHeight }
        record("first-message-complete", inputBytes: firstInput.utf8.count)
        try await SwiftUIReplay.wait {
            guard let value = fixture.scroll?["value"], let h = value["height"]?.numberValue,
                  let y = value["top"]?.numberValue, let v = value["viewport"]?.numberValue else { return false }
            return h - y - v < 5
        }
        record("following-bottom")
        try fixture.perform(#require(fixture.scroll), "scrollTo", .number(0))
        try await SwiftUIReplay.wait { fixture.scroll?["value"]?["following"] == .bool(false) && fixture.scroll?["pending"] == .bool(false) }
        record("user-scroll")
        let secondInput = String(repeating: "NEW STREAMING CONTENT\n\n", count: 220)
        try fixture.update(status: .running, text: firstInput, messageStatus: "complete", pendingText: secondInput)
        record("second-source", inputBytes: secondInput.utf8.count)
        try await Task.sleep(for: .milliseconds(200))
        record("second-stream", inputBytes: secondInput.utf8.count)
        #expect(!textViews(root).contains { $0.string.contains("NEW STREAMING CONTENT") })
        #expect(textViews(root).contains { $0.string.contains("STREAMING CONTENT") })
        #expect(fixture.thread.observation.latestExecution?.status == .running)
        #expect((fixture.scroll?["value"]?["top"]?.numberValue ?? 100) < 5)
        let jump = try #require(fixture.controls.snapshot(visit: fixture.visit).first { $0["role"] == .text("jumpLatest") })
        try fixture.perform(jump, "activate")
        try await SwiftUIReplay.wait { fixture.scroll?["value"]?["following"] == .bool(true) }
        record("jump-latest")
        try fixture.update(status: .completed, text: firstInput, successor: true, pendingText: secondInput)
        try await SwiftUIReplay.wait { textViews(root).contains { $0.string.contains("NEW STREAMING CONTENT") } }
        #expect(try replyCopies("NEW STREAMING CONTENT", in: root).allSatisfy { $0 == 220 })
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
        try await SwiftUIReplay.wait { element(id: "moku-note-execution-link", nativeOnly: true, label: "View result", in: root) != nil }
        try click("View result", in: root)
        #expect(fixture.presentation.selected?.threadID == "ordinary")
        try await ready(fixture)
        #expect(fixture.controls.snapshot(visit: fixture.visit).contains { $0["role"] == .text("turn") && $0["value"]?["executionId"] == .text("target") && $0["value"]?["state"] == .text("ready") })
        // Pi can retain a streaming marker after execution settlement. Other
        // Harnesses settle their message status along with failure/cancellation.
        try fixture.update(status: status, text: "RETAINED TERMINAL REPLY", messageStatus: harness == "pi" ? "streaming" : status == .failed ? "failed" : "cancelled")
        try await SwiftUIReplay.wait { textViews(root).contains { $0.string.contains("RETAINED TERMINAL REPLY") } }
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
