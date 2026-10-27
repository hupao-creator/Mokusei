import AppKit
import Observation
import MokuseiCore
import MokuseiPluginUI
import SwiftUI
@testable import MokuseiUI
@testable import MokuseiVoice

private struct GuardedAudio: LocalizedError {
    var errorDescription: String? { "回归保护：未启动任何音频设备" }
}
@MainActor @Observable private final class InputFixture {
    let ownership = NativeVoiceMediaOwnership()
    var history = false
    var attempts = 0
    var prepares = 0
    var finished = false
    var voice: NativeVoiceMediaClient!
    let scene = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    init() { resetVoice(); scene.setInputOpen(true) }
    func resetVoice() {
        voice = NativeVoiceMediaClient(role: .moku, ownership: ownership, beforeStart: { [weak self] in
            self?.attempts += 1
            throw GuardedAudio() // Runs before prepare, privacy consent or media allocation.
        }, command: { [weak self] request in
            if request["action"] == .text("prepare") { self?.prepares += 1 }
            throw GuardedAudio()
        })
        voice.setOwner("presentation-test", available: true)
    }
    func startVoice() { Task { await voice.start() } }
}

/// Computer Use operates the real production surfaces in a separate process.
/// The media start boundary throws before touching privacy consent or hardware.
@MainActor func inputPresentationReplay() async throws {
    let fixture = InputFixture()
    let host = NSHostingView(rootView: ObservedInputFixture(fixture: fixture))
    let window = NSWindow(contentRect: CGRect(x: 120, y: 100, width: 820, height: 650),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Moku production input regression"
    window.isReleasedWhenClosed = false; window.contentView = host
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    print("READY production input regression; audio start is guarded")
    for _ in 0..<2400 {
        if fixture.finished { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    guard fixture.attempts > 0, fixture.prepares == 0 else {
        throw GuardedAudio()
    }
    print("PASS guarded production voice entry, no prepare/privacy/media allocation; attempts=\(fixture.attempts)")
}

private struct ObservedInputFixture: View {
    let fixture: InputFixture
    private var directories: [NativeComposerDirectory] {
        [.init(name: "Alpha", path: "/tmp/alpha"), .init(name: "Beta", path: "/tmp/beta"), .init(name: "Gamma", path: "/tmp/gamma")]
    }
    private var pinned: Bool {
        fixture.voice.state.phase != .closed && fixture.voice.state.phase != .failed || !fixture.voice.state.error.codeUnits.isEmpty
    }
    private var voiceActive: Bool {
        [.preparing, .connecting, .listening, .stopping].contains(fixture.voice.state.phase)
    }
    private var canStartVoice: Bool {
        fixture.voice.state.available && (fixture.voice.state.phase == .closed || fixture.voice.state.phase == .failed)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Outside") { fixture.scene.setMokuOpen(false); fixture.history = false; fixture.scene.setInputOpen(true) }
                Button("History") { fixture.history = true; fixture.scene.setMokuOpen(true) }
                Button("Closed") { fixture.scene.setMokuOpen(false); fixture.history = false; fixture.scene.setInputOpen(false) }
                Button("Reset guarded voice") { fixture.resetVoice() }
                Button("Voice entry") { fixture.startVoice() }
                Button("Finish") { fixture.finished = true }
                Text("Guarded audio: \(fixture.attempts) · prepares: \(fixture.prepares)").font(.system(size: 11))
            }.padding(20)
            NativeMokuScene(state: fixture.scene) { NativePalette.overview.canvas.swiftUI } thread: {
                VStack {
                    Spacer()
                    NativeMokuHistoryComposer(draft: fixture.draft, cwd: "/tmp",
                        focusEnabled: fixture.history,
                        activeVoiceControls: AnyView(NativeMokuVoiceControls(client: fixture.voice, style: .dock)),
                        voiceModeActive: voiceActive, loadMentionDirectories: { directories },
                        onSend: { _ in throw GuardedAudio() }, onCancel: {},
                        canStartVoice: { canStartVoice }, startVoice: { fixture.startVoice() })
                        .frame(maxWidth: 560).padding(24)
                }
            } dock: {
                NativeMokuDock(state: fixture.scene, draft: fixture.draft, cwd: "/tmp",
                    voiceControls: AnyView(NativeMokuVoiceControls(client: fixture.voice, style: .dock)),
                    voiceStatusVisible: pinned, loadMentionDirectories: { directories },
                    onSend: { _ in throw GuardedAudio() }, onCancel: {},
                    canStartVoice: { canStartVoice }, startVoice: { fixture.startVoice() })
            } settings: { Color.clear }
        }.background(NativePalette.overview.canvas.swiftUI)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
    }
}

private struct CompletionFailure: Error, CustomStringConvertible { let description: String }
@MainActor private func checkCompletion(_ condition: Bool, _ message: String) throws {
    if !condition { throw CompletionFailure(description: message) }
}
@MainActor private func completionWait(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CompletionFailure(description: message)
}
@MainActor private func completionEditor(_ view: NSView) -> NSTextView? {
    if let text = view as? NSTextView { return text }
    return view.subviews.lazy.compactMap { completionEditor($0) }.first
}
@MainActor @Observable private final class CompletionFixture { var height: CGFloat = 58 }

/// Isolated NSApplication event loop, rather than several unit-test windows
/// competing for key-window admission and the native editor's focus.
@MainActor func inputCompletionReplay() async throws {
    let pasteboard = NSPasteboard.general
    let savedClipboard = (pasteboard.pasteboardItems ?? []).map { item in
        let copy = NSPasteboardItem()
        for type in item.types { if let bytes = item.data(forType: type) { copy.setData(bytes, forType: type) } }
        return copy
    }
    defer { pasteboard.clearContents(); pasteboard.writeObjects(savedClipboard) }
    NSApp.activate(ignoringOtherApps: true)
    for history in [false, true] {
        let state = NativeMokuSceneState()
        let fixture = CompletionFixture()
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in
            [.init(id: "completion-file", path: "/tmp/completion-file", name: "notes.txt", mimeType: "text/plain", size: 1, kind: .file)]
        }, discardAttachments: { _ in }))
        var sends = 0
        var submittedAttachments = 0
        let directories: [NativeComposerDirectory] = [.init(name: "Alpha", path: "/tmp/alpha"), .init(name: "Beta", path: "/tmp/beta")]
        let content: AnyView
        if history {
            content = AnyView(VStack {
                Spacer()
                NativeMokuHistoryComposer(draft: draft, cwd: "/tmp", loadMentionDirectories: { directories },
                    onSend: { sends += 1; submittedAttachments = $0.attachments.count }, onCancel: {})
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fixture.height = $0 }
                    .padding(24)
            })
        } else {
            state.setInputOpen(true)
            content = AnyView(NativeMokuScene(state: state) { Color.clear } thread: { Color.clear } dock: {
                NativeMokuDock(state: state, draft: draft, cwd: "/tmp", loadMentionDirectories: { directories },
                    onSend: { sends += 1; submittedAttachments = $0.attachments.count }, onCancel: {})
            } settings: { Color.clear })
        }
        let host = NSHostingView(rootView: content.frame(width: 620, height: 480))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 620, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(550))
        guard let input = completionEditor(host) else { throw CompletionFailure(description: "Missing actual Moku editor") }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try checkCompletion(window.makeFirstResponder(input), "Completion editor did not accept first responder")
        func key(_ code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = [], applicationDispatch: Bool = false) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else {
                throw CompletionFailure(description: "Missing key event")
            }
            // Route through this native window explicitly. macOS may deny app
            // activation to a detached verifier while other tasks own focus;
            // native composer key routing does not require global activation.
            if applicationDispatch { NSApp.sendEvent(event) } else { window.sendEvent(event) }
        }
        // The attachment bridge is an application event monitor. Exercise it
        // before completion and submit, using the same retained production draft.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("completion-\(UUID().uuidString).txt")
        try Data("notes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let clipboard = NSPasteboardItem()
        clipboard.setString(file.absoluteString, forType: .fileURL)
        clipboard.setString(file.lastPathComponent, forType: .string)
        pasteboard.clearContents(); pasteboard.writeObjects([clipboard])
        try key(9, "v", modifiers: history ? .control : .command, applicationDispatch: true)
        // The in-flight paste must keep its original clipboard snapshot.
        pasteboard.clearContents(); pasteboard.setString("replacement clipboard", forType: .string)
        try await completionWait("Native attachment shortcut did not stage exactly once") {
            !draft.importing && draft.attachments.count == 1 && draft.text.isEmpty && draft.error == nil
        }
        input.insertText("@", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await completionWait("Completion did not extend the capsule, history=\(history)") {
            history ? fixture.height > 70 : state.dockMentionHitRect != nil
        }
        try await Task.sleep(for: .milliseconds(500))
        if !history, let completion = state.dockMentionHitRect {
            try checkCompletion(state.capsuleFrame.contains(completion), "Completion escaped the shared glass/hit frame")
        }
        try key(125, "\u{f701}"); try key(36, "\r")
        do { try await completionWait("Keyboard completion did not select Beta") { draft.directories.first?.path == "/tmp/beta" } }
        catch { throw CompletionFailure(description: "\(error); history=\(history), draft=\(String(reflecting: draft.text)), editor=\(String(reflecting: input.string)), selection=\(input.selectedRange()), sends=\(sends), directories=\(draft.directories), firstResponder=\(String(describing: window.firstResponder)), key=\(window.isKeyWindow)") }
        try checkCompletion(draft.text.isEmpty && sends == 0, "Completion submitted text instead of choosing its directory")
        if !history {
            try await completionWait("Completion hit frame did not retire") { state.dockMentionHitRect == nil && state.inputOpen }
        }
        try await completionWait("Accepted completion did not clear the actual editor") { input.string.isEmpty }
        // Wait for SwiftUI's editor-state callback as well as the text binding.
        func replaceDraft(_ value: String) async throws {
            input.insertText(value, replacementRange: NSRange(location: 0, length: input.string.utf16.count))
            try await completionWait("Production binding missed keyboard fixture") { draft.text == value }
            try await Task.sleep(for: .milliseconds(100))
        }
        draft.removeDirectory("/tmp/beta")
        try await replaceDraft("@B")
        // Command-Enter inserts a newline even with a highlighted completion.
        try key(125, "\u{f701}"); try key(126, "\u{f700}")
        try key(36, "\r", modifiers: .command)
        do { try await completionWait("Command-Enter did not insert a newline") { draft.text == "@B\n" } }
        catch { throw CompletionFailure(description: "\(error); draft=\(String(reflecting: draft.text)), editor=\(String(reflecting: input.string)), selection=\(input.selectedRange()), sends=\(sends), directories=\(draft.directories)") }
        try checkCompletion(draft.directories.isEmpty && sends == 0, "Command-Enter selected or sent a mention")
        try await replaceDraft("@B")
        try key(125, "\u{f701}"); try key(126, "\u{f700}")
        try key(36, "\r")
        try await completionWait("Enter did not confirm Beta") {
            draft.directories.map(\.path) == ["/tmp/beta"] && draft.text.isEmpty && input.string.isEmpty
        }
        try checkCompletion(sends == 0 && draft.attachments.count == 1, "Enter sent or lost attachments instead of confirming a mention")
        draft.removeDirectory("/tmp/beta")
        try await replaceDraft("@")
        try key(36, "\r", modifiers: .shift)
        try await completionWait("Shift-Enter did not retain native newline behavior") { draft.text == "@\n" }
        try checkCompletion(draft.directories.isEmpty && sends == 0, "Shift-Enter selected or sent a mention")

        for modifiers: NSEvent.ModifierFlags in [[], .command] {
            try await replaceDraft("@")
            input.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: input.selectedRange())
            try checkCompletion(input.hasMarkedText(), "IME fixture did not establish marked text")
            try key(36, "\r", modifiers: modifiers)
            try checkCompletion(draft.directories.isEmpty && sends == 0, "IME confirmation selected or sent a mention: command=\(modifiers.contains(.command)), directories=\(draft.directories), sends=\(sends), marked=\(input.hasMarkedText())")
            input.unmarkText()
        }
        try await replaceDraft("plain")
        try key(36, "\r", modifiers: .command)
        try await completionWait("Command-Enter did not insert a newline outside completion") { draft.text == "plain\n" }
        try key(36, "\r", modifiers: .control)
        try checkCompletion(sends == 0, "Command/Control-Enter sent a message")
        try await replaceDraft("@")
        try key(48, "\t")
        try await completionWait("Tab did not retain mention confirmation") { draft.directories.first?.path == "/tmp/alpha" }
        try checkCompletion(draft.text.isEmpty && sends == 0, "Tab inserted text or sent a message")
        draft.removeDirectory("/tmp/alpha")
        try await replaceDraft("")
        input.insertText("@", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(200)); try key(53, "\u{1b}")
        try await Task.sleep(for: .milliseconds(450))
        try checkCompletion(draft.text == "@" && (history || state.inputOpen), "Escape closed history/input or lost its draft; history=\(history), open=\(state.inputOpen), text=\(draft.text), editor=\(input.string)")
        try checkCompletion(completionEditor(host) === input, "Completion remounted the input")
        try await replaceDraft("send without completion")
        try key(36, "\r")
        try await completionWait("Enter without completion did not submit") { sends == 1 && draft.text.isEmpty && draft.attachments.isEmpty }
        try checkCompletion(submittedAttachments == 1, "Enter submission omitted the retained attachment")
        window.close()
        print("PASS integrated completion, Enter selection/send, Command/Shift-Enter newline, Control passthrough, Tab, navigation, IME, native attachment paste, Escape and retained editor; history=\(history)")
    }
    try await inputMentionTypingReplay()
}

/// Includes actual SwiftUI menu construction/layout after every native edit.
/// Settling includes a 10ms event-loop yield; it is not a frame-rate capture.
@MainActor private func inputMentionTypingReplay() async throws {
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Measure Moku mention typing")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    let directories = (0..<2_000).map { NativeComposerDirectory(name: JSONText("Workspace-\($0)"), path: JSONText("/work/Workspace-\($0)")) }
    var sends = 0
    let host = NSHostingView(rootView: NativeMokuHistoryComposer(draft: draft, cwd: "/tmp",
        loadMentionDirectories: { directories }, onSend: { _ in sends += 1 }, onCancel: {})
        .frame(width: 620, height: 480, alignment: .bottom))
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 620, height: 480),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(550))
    guard let input = completionEditor(host) else { throw CompletionFailure(description: "Missing performance editor") }
    window.makeFirstResponder(input)
    var sampler: Process?
    if let path = ProcessInfo.processInfo.environment["MOKU_MENTION_SAMPLE"] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "1", "-file", path]
        try process.run()
        sampler = process
    }
    var expected = ""
    var durations: [Duration] = []
    for character in "@workspace-1" {
        let start = ContinuousClock.now
        expected.append(character)
        input.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        let inputDuration = ContinuousClock.now - start
        try await completionWait("Typing replay lost text") { draft.text == expected }
        try await Task.sleep(for: .milliseconds(10))
        let layoutStart = ContinuousClock.now
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        durations.append(ContinuousClock.now - start)
        print("Typing \(String(reflecting: String(character))): native-edit=\(inputDuration), explicit-layout/display=\(ContinuousClock.now - layoutStart), total-with-yield=\(durations.last ?? .zero)")
        try checkCompletion(completionEditor(host) === input && window.firstResponder === input, "Mention typing replaced or defocused the editor")
    }
    try checkCompletion(sends == 0 && draft.text == "@workspace-1", "Mention typing sent or lost text")
    let sorted = durations.sorted()
    if let sampler, sampler.isRunning { sampler.waitUntilExit() }
    print("PASS 2,000-directory native typing/layout replay: edits=\(durations.count), median=\(sorted[sorted.count / 2]), max=\(sorted.last ?? .zero); includes 10ms event-loop yield")
}
