import AppKit
import MokuseiCore
import MokuseiHarnessCodex
import MokuseiPluginAPI
import SwiftUI
@testable import MokuseiPluginUI
@testable import MokuseiUI

private struct ChiefInputReplayFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor func replayChiefInput() async throws {
    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let hostDirectory = try JSONDecoder().decode(RuntimeHostDirectory.self, from: Data(
        #"{"reference":{"hostID":"fixture-host","path":"/fixture/Old directory"},"entries":[]}"#.utf8))
    let services = NativeComposerServices(stageFiles: { _, _ in [] }, hostDirectory: { _, _ in hostDirectory },
        discardAttachments: { _ in })
    for history in [false, true] {
        let surface = history ? "Chief history" : "Overview Chief Dock"
        let draft = NativeComposerDraft(services: services)
        let scene = NativeMokuSceneState()
        scene.setComposerContext(draft, opensInput: true, autofocus: false)
        let archivedMessage = "Previous request @Saved project"
        let past = try history ? ChiefHistoryFixture(message: archivedMessage) : nil
        let events = await past?.client.events()
        let readingControls = NativeReadingInteractions()
        let readingVisit = UUID()
        let panel = ComposerReplayPanel(contentRect: NSRect(x: 100, y: 100, width: 720, height: 400),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        var sent: [JSONValue] = []
        var catalogLoads = 0
        let send: (NativeComposerSubmission) async throws -> Void = {
            sent.append($0.input(knownDirectoryReferencesAsText: true))
        }
        panel.contentView = NSHostingView(rootView: Group {
            if let past {
                NativeMokuThreadView(harnessHost: past.host, thread: past.thread, draft: draft,
                    onBack: {}, onSend: send, onCancel: {})
            } else {
                NativeMokuScene(state: scene) { Color.clear } thread: { EmptyView() } dock: {
                    NativeMokuDock(state: scene, draft: draft, cwd: "/fixture", loadMentionDirectories: {
                        catalogLoads += 1
                        return [.init(name: "Fixture", path: "/fixture/Fixture")]
                    }, onSend: send, onCancel: {})
                } settings: { EmptyView() }
            }
        }.environment(\.scenePhase, .active).environment(\.locale, Locale(identifier: "en"))
            .environment(\.nativeReadingInteractions, readingControls)
            .environment(\.nativeReadingInteractionVisit, readingVisit))
        let historyFeed = Task {
            guard let past, let events else { return }
            for await event in events {
                if case let .threadContent(id, _) = event {
                    past.host.receive(.threadContent(subscriptionId: id, state: .ready(past.content)))
                }
            }
        }
        panel.orderBack(nil)
        defer { historyFeed.cancel(); panel.close() }

        let content = panel.contentView!
        func focusEditor() async throws -> NSTextView {
            let deadline = ContinuousClock.now + .seconds(4)
            while ContinuousClock.now < deadline {
                if let editor = find(content, NSTextView.self, matching: { $0.isEditable }), panel.makeFirstResponder(editor) {
                    return editor
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ChiefInputReplayFailure(description: "\(surface) did not mount its native editor")
        }
        let editor = try await focusEditor()
        editor.keyDown(with: key("@", code: 19, modifiers: .shift, unmodified: "2", panel: panel))
        try await Task.sleep(for: .milliseconds(500))
        try require(editor.string == "@" && draft.text == "@" && catalogLoads == 0 && scene.dockMentionHitRect == nil
            && !hasCompletion(content), "\(surface) did not treat typed @ as ordinary text")
        editor.keyDown(with: key("\r", code: 36, panel: panel))
        try require(sent == [textInput("@")], "\(surface) did not send a bare @ on Return")

        if !history { scene.setInputOpen(true) }
        let reopened = try await focusEditor()
        reopened.insertText("@", replacementRange: reopened.selectedRange())

        // Use a private pasteboard so the replay leaves the clipboard alone.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try require(pasteboard.setString("draft@example.com", forType: .string)
            && reopened.readSelection(from: pasteboard, type: .string), "\(surface) could not paste text")
        reopened.setSelectedRange(NSRange(location: 1, length: 5))
        reopened.insertText("team", replacementRange: reopened.selectedRange())
        try require(draft.text == "@team@example.com" && draft.directories.isEmpty, "\(surface) changed pasted or edited @ text")
        reopened.keyDown(with: key("\r", code: 36, panel: panel))
        try require(sent == [textInput("@"), textInput("@team@example.com")], "\(surface) did not send literal @ text on Return")
        try require(draft.text.isEmpty, "\(surface) did not consume its submitted draft")

        if !history { scene.setInputOpen(true) }
        let plainEditor = try await focusEditor()
        plainEditor.insertText("ordinary request", replacementRange: plainEditor.selectedRange())
        plainEditor.keyDown(with: key("\r", code: 36, panel: panel))
        try require(sent == [textInput("@"), textInput("@team@example.com"), textInput("ordinary request")],
            "\(surface) did not send ordinary text")
        if history {
            let controlDeadline = ContinuousClock.now + .seconds(4)
            while true {
                let controls = readingControls.snapshot(visit: readingVisit)
                if let filter = controls.first(where: { $0["role"] == .text("visibility.userMessages") && $0["enabled"] == .bool(true) }),
                   let id = filter["id"]?.stringValue, let handle = filter["handle"]?.stringValue {
                    try readingControls.perform(id: id, handle: handle, operation: "activate", value: .null, visit: readingVisit)
                    break
                }
                try require(ContinuousClock.now < controlDeadline, "Chief history did not mount Show user messages")
                try await Task.sleep(for: .milliseconds(10))
            }
            let deadline = ContinuousClock.now + .seconds(4)
            while find(content, NSTextView.self, matching: { !$0.isEditable && $0.string.contains(archivedMessage) }) == nil {
                try require(ContinuousClock.now < deadline, "Chief history did not render the recorded @ message")
                try await Task.sleep(for: .milliseconds(10))
            }
            print("Passed reading a previously sent Chief message with a stored directory mention.")
        }
        print("Passed \(surface): typed @ without completion, pasted and edited @ text, and sent both literal and ordinary text.")
    }

    let storage = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let persistence = NativeComposerDraftPersistence(storageDirectory: storage, scope: JSONText(UUID().uuidString))
    let previous = NativeComposerDraft(services: services, persistence: persistence)
    previous.text = "Old @ draft"
    let legacy = NativeComposerDirectory(name: "Old directory", path: "/fixture/Old directory")
    try require(previous.insertDirectory(legacy), "Could not seed a persisted completion reference")
    let reopened = NativeComposerDraft(services: services, persistence: persistence)
    var recovered: JSONValue?
    await reopened.submit({ recovered = $0.input(knownDirectoryReferencesAsText: true) }, optimisticallyClear: true)
    try require(recovered == textInput("Old @ draft\n/fixture/Old directory"), "Persisted mention lost text or emitted a reference")
    try require(reopened.insertDirectory(legacy), "Could not seed the saved path before opening the host picker")
    let directory = try await reopened.hostDirectory()
    try require(reopened.chooseHostDirectory(directory.reference), "Host directory selection failed")
    let picked = NativeComposerDirectory(name: legacy.name, path: legacy.path, hostID: "fixture-host")
    try require(reopened.directories == [picked], "The host picker did not replace the saved catalog reference")
    await reopened.submit({ recovered = $0.input(knownDirectoryReferencesAsText: true) }, optimisticallyClear: true)
    try require(recovered == .object(["parts": .array([.object([
        "kind": .string("mention"), "name": .string(picked.name), "path": .string(picked.path), "pathType": .string("directory"),
    ])])]), "Explicit host directory did not preserve its structured reference")
    try require(!NSApp.isActive && foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier,
        "Replay activated itself or the foreground app changed")
    print("Passed persisted Chief draft and explicit host directory serialization.")
}

@MainActor private struct ChiefHistoryFixture {
    let client: RuntimeClient
    let host: NativeHarnessHost
    let thread: HarnessThread
    let content: JSONValue

    init(message: String) throws {
        let storage = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("history-profile")
        client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: storage))
        let current = try HarnessThread(id: "chief", harnessID: "codex", revision: 0,
            sessionState: .null, observation: .init(), cwd: "/fixture", settings: .object([:]),
            createdAt: 1, updatedAt: 2, title: "Chief", tags: [], moku: true, transcript: .array([]))
        thread = current
        host = NativeHarnessHost(client: client, registry: try HarnessPluginRegistry([AnyHarnessPlugin(CodexHarnessPlugin())]),
            currentThread: { $0 == current.id ? current : nil },
            callbacks: .init(openExternal: { _ in }, openFollowUp: { _, _ in }, onError: { _ in }))
        content = .object(["schema": .text("mokusei.harness.codex.thread.v1"), "updatedAt": .integer(2),
            "backgroundTerminals": .array([]), "turns": .array([.object([
                "executionId": .text("previous-execution"), "createdAt": .integer(1), "updatedAt": .integer(2),
                "finishedAt": .integer(2), "status": .text("completed"), "answer": .text(""), "reasoning": .text(""),
                "plan": .array([]), "activities": .array([]), "interactions": .array([]), "notices": .array([]),
                "messages": .array([.object(["id": .text("previous-message"), "content": .text(message),
                    "role": .text("user"), "kind": .text("prompt"), "createdAt": .integer(1), "attachments": .array([])])]),
                "timeline": .array([.object(["id": .text("previous-item"), "kind": .text("user-message"),
                    "createdAt": .integer(1), "messageId": .text("previous-message")])]),
            ])])])
    }
}

private func textInput(_ text: String) -> JSONValue {
    .object(["parts": .array([.object(["kind": .string("text"), "text": .text(text)])])])
}

private func require(_ condition: Bool, _ failure: String) throws {
    guard condition else { throw ChiefInputReplayFailure(description: failure) }
}

@MainActor private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                            unmodified: String? = nil, panel: NSPanel) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: unmodified ?? characters, isARepeat: false, keyCode: code)!
}

@MainActor private func find<T: NSView>(_ view: NSView, _ type: T.Type, matching: (T) -> Bool) -> T? {
    if let match = view as? T, matching(match) { return match }
    for child in view.subviews {
        if let match = find(child, type, matching: matching) { return match }
    }
    return nil
}

@MainActor private func hasCompletion(_ element: Any) -> Bool {
    accessibilityElement(element) { $0.accessibilityIdentifier() == "moku-directory-completion" } != nil
}

@MainActor private func accessibilityElement(_ element: Any, matching: (any NSAccessibilityProtocol) -> Bool) -> (any NSAccessibilityProtocol)? {
    guard let node = element as? any NSAccessibilityProtocol else { return nil }
    if matching(node) { return node }
    for child in node.accessibilityChildren() ?? [] {
        if let match = accessibilityElement(child, matching: matching) { return match }
    }
    return nil
}
