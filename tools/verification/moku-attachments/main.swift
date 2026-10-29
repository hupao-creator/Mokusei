import AppKit
import SwiftUI
import Observation
import MokuseiCore
import MokuseiPluginUI
@testable import MokuseiUI

private struct ReplayFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ReplayFailure(description: message) }
}

@MainActor private func waitFor(_ message: String, _ predicate: () -> Bool) async throws {
    for _ in 0..<1000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ReplayFailure(description: message)
}

@MainActor private func click(_ point: CGPoint, in view: NSView, window: NSWindow) throws {
    let location = view.convert(point, to: nil)
    let timestamp = ProcessInfo.processInfo.systemUptime
    func event(_ type: NSEvent.EventType) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: timestamp + (type == .leftMouseDown ? 0 : 0.01), windowNumber: window.windowNumber,
            context: nil, eventNumber: type == .leftMouseDown ? 1 : 2,
            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
            throw ReplayFailure(description: "Could not create a mouse event")
        }
        return event
    }
    // SwiftUI needs AppKit's currentEvent, including during mouse tracking.
    NSApp.postEvent(try event(.leftMouseUp), atStart: true)
    NSApp.postEvent(try event(.leftMouseDown), atStart: true)
    for mask: NSEvent.EventTypeMask in [.leftMouseDown, .leftMouseUp] {
        if let event = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
}

@MainActor private func replay(narrow: Bool) async throws {
    let state = NativeMokuSceneState()
    var staged = 0
    let draft = NativeComposerDraft(services: .init(stageFiles: { files, _ in
        staged += files.count
        return []
    }, discardAttachments: { _ in }))
    state.setInputOpen(true)
    let scene = NativeMokuScene(state: state) { Color.clear } thread: { Color.clear } dock: {
        NativeMokuDock(state: state, draft: draft, cwd: "/tmp", onSend: { _ in }, onCancel: {})
    } settings: { Color.clear }
    let host = NSHostingView(rootView: scene)
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: narrow ? 420 : 900, height: narrow ? 360 : 700),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer {
        (window.attachedSheet as? NSOpenPanel)?.cancel(nil)
        for panel in NSApp.windows.compactMap({ $0 as? NSOpenPanel }) where panel.isVisible { panel.cancel(nil) }
        window.close()
    }
    try await Task.sleep(for: .milliseconds(550))
    host.layoutSubtreeIfNeeded()
    try require(!state.capsuleFrame.isEmpty, "Moku input did not appear")
    for disposing in [false, true] {
        Task { await draft.chooseFiles(cwd: "/tmp") }
        // The service uses a sheet for a key window and a standalone panel
        // when the replay is launched without foreground activation.
        func picker() -> NSOpenPanel? {
            (window.attachedSheet as? NSOpenPanel)
                ?? NSApp.windows.compactMap { $0 as? NSOpenPanel }.first { $0.isVisible }
        }
        do {
            try await waitFor("No attachment picker, narrow=\(narrow)") { picker() != nil }
        } catch {
            throw ReplayFailure(description: "\(error); app active=\(NSApp.isActive), owner visible=\(window.isVisible), key=\(window.isKeyWindow), canKey=\(window.canBecomeKey), importing=\(draft.importing); windows=\(NSApp.windows.map { "\(type(of: $0)):visible=\($0.isVisible),sheet=\($0.sheetParent != nil)" })")
        }
        guard let panel = picker() else {
            throw ReplayFailure(description: "Attachment picker disappeared")
        }
        try require(draft.importing && state.inputOpen, "Opening a picker lost the draft/input state")
        try require(panel.canChooseFiles && !panel.canChooseDirectories && panel.allowsMultipleSelection,
                    "Unexpected attachment picker configuration")
        // Cancellation must permit reopening. Draft disposal must also close
        // the outstanding native sheet through its PluginLifetime.
        if disposing { await draft.dispose() } else { panel.cancel(nil) }
        try await waitFor("Attachment picker did not finish") { !draft.importing && !panel.isVisible && panel.sheetParent == nil }
        try require(draft.error == nil && draft.attachments.isEmpty && staged == 0,
                    "Cancelled picker changed attachments or reported an error")
    }
    print("PASS chooser narrow=\(narrow): open, cancel, reopen, dispose")
}

/// Accept first mouse even when a detached runner cannot activate its app.
/// The assertion exercises the production scene's routing to its outside seat.
private struct OutsideClickProbe: NSViewRepresentable {
    var onClick: () -> Void
    func makeNSView(context: Context) -> Probe { Probe(onClick: onClick) }
    func updateNSView(_ view: Probe, context: Context) { view.onClick = onClick }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Probe, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
    final class Probe: NSView {
        var onClick: () -> Void
        init(onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
            wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick() }
    }
}

private struct ReplayObserved<Content: View>: View {
    var content: () -> Content
    var body: some View { content() }
}

@MainActor @Observable private final class CapsuleFixture {
    var interaction = false
    var question = false
    var reply = false
    var responseClicks = 0
}

@MainActor @Observable private final class CapsuleAppearanceFixture {
    var dark = false
    var patterned = false
}

/// The actual production dock over the overview canvas and a deliberately
/// contrasting backdrop. Keep one editor alive across local theme changes.
@MainActor private func capsuleAppearanceReplay() async throws {
    let fixture = CapsuleAppearanceFixture()
    let state = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    state.setInputOpen(true)
    let host = NSHostingView(rootView: ReplayObserved {
        NativeMokuScene(state: state) {
            ZStack {
                NativePalette.overview.canvas.swiftUI
                if fixture.patterned {
                    LinearGradient(colors: [.white, .black, .orange, .cyan, .white],
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
        } thread: { Color.clear } dock: {
            NativeMokuDock(state: state, draft: draft, cwd: "/tmp", onSend: { _ in }, onCancel: {})
        } settings: { Color.clear }
        .environment(\.colorScheme, fixture.dark ? .dark : .light)
        .overlay(alignment: .top) {
            if ProcessInfo.processInfo.environment["MOKU_CAPSULE_INSPECT"] == "contrast" {
                HStack {
                    Button("Light") { fixture.dark = false; state.setInputOpen(true) }
                    Button("Dark") { fixture.dark = true; state.setInputOpen(true) }
                    Button("Backdrop") { fixture.patterned.toggle(); state.setInputOpen(true) }
                    Button("Draft") {
                        draft.text = draft.text.isEmpty ? "Readable 中文 · Moku" : ""
                        state.setInputOpen(true)
                    }
                }.padding(16).environment(\.colorScheme, fixture.dark ? .dark : .light)
            }
        }
    })
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 900, height: 360),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Moku production material — theme contrast replay"
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    func editor(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { editor($0) }.first
    }
    func capture(_ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MOKU_CAPSULE_EVIDENCE"] else { return }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw ReplayFailure(description: "Could not render appearance evidence: \(name)")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ReplayFailure(description: "Could not encode appearance evidence: \(name)")
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
    }
    try await waitFor("Appearance replay editor not focused") { window.firstResponder is NSTextView }
    guard let original = editor(host) else { throw ReplayFailure(description: "Missing theme replay editor") }
    func checkSingleLineLayout(_ text: NSTextView) throws {
        guard let scroll = text.enclosingScrollView else { throw ReplayFailure(description: "Missing composer viewport") }
        // A persistent legacy scroller remains resident for a stable gutter; only
        // painted pixels would mean the composer is displaying a scrollbar.
        if let scroller = scroll.verticalScroller,
           let bitmap = scroller.bitmapImageRepForCachingDisplay(in: scroller.bounds) {
            scroller.cacheDisplay(in: scroller.bounds, to: bitmap)
            var ink = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.02 { ink += 1 }
                }
            }
            try require(ink == 0, "Single-line composer displays a scrollbar knob")
        }
        let caret = text.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let capsule = window.convertToScreen(host.convert(state.capsuleFrame, to: nil))
        try require(abs(caret.midY - capsule.midY) <= 0.5, "Single-line composer is not vertically centered")
    }
    for dark in [false, true, false] {
        fixture.dark = dark
        // A local SwiftUI override must win even over an opposite window.
        window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        for patterned in [false, true] {
            fixture.patterned = patterned
            draft.text = ""
            try await Task.sleep(for: .milliseconds(280))
            host.layoutSubtreeIfNeeded()
            guard let text = editor(host) else { throw ReplayFailure(description: "Theme update removed editor") }
            try require(text === original, "Theme update replaced the production editor")
            try checkSingleLineLayout(text)
            try require(text.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                        "Production Moku editor must stay dark under either workspace theme")
            let name = "contrast-\(dark ? "dark" : "light")-glass-\(patterned ? "pattern" : "canvas")"
            try capture(name + "-placeholder")
            text.insertText("Readable 中文 · Moku", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await waitFor("Theme fixture lost draft binding") { draft.text == "Readable 中文 · Moku" }
            try await Task.sleep(for: .milliseconds(100))
            try checkSingleLineLayout(text)
            try capture(name + "-text")
        }
    }
    // Return to glass and retain existing text through both theme directions.
    for dark in [true, false] {
        fixture.dark = dark
        try await Task.sleep(for: .milliseconds(150))
        try require(editor(host) === original && original.string == "Readable 中文 · Moku",
                    "Theme switch discarded the existing draft/editor")
    }
    if ProcessInfo.processInfo.environment["MOKU_CAPSULE_INSPECT"] == "contrast" {
        fixture.dark = true; fixture.patterned = false; draft.text = ""
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(original)
        print("INSPECT production capsule contrast for 60 seconds")
        try await Task.sleep(for: .seconds(60))
    }
    await draft.dispose()
    print("PASS production capsule centered single lines without scrollbars, fixed dark Moku under light/dark workspace themes, opposite window appearance, overview/contrasting backgrounds, placeholder/text captures and retained draft")
}

@MainActor private func capsuleReplay() async throws {
    // Pure placement checks include negative display origins and clipped/scrolling viewports.
    for viewport in [CGRect(x: 0, y: 0, width: 900, height: 700),
                     CGRect(x: -900, y: 65, width: 420, height: 360),
                     CGRect(x: 80, y: 120, width: 320, height: 280)] {
        let frame = NativeMokuCapsuleLayout.frame(in: viewport)
        let closed = NativeMokuCapsuleLayout.surface(in: frame, expanded: false, height: 58)
        let open = NativeMokuCapsuleLayout.surface(in: frame, expanded: true, height: 126)
        try require(abs(closed.midX - viewport.midX) < 0.1 && open.midX == closed.midX,
                    "Capsule is not centered in available viewport")
        try require(closed.width == min(NativeMokuCapsuleLayout.idleSize.width, frame.width) && open.width > closed.width && closed.maxY == open.maxY,
                    "Capsule did not preserve its bottom anchor")
        try require(viewport.contains(open) && viewport.maxY - open.maxY >= 24,
                    "Capsule escaped available frame or Dock margin")
    }
    let state = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var sent: [NativeComposerSubmission] = []
    var failSend = false
    var outsideClicks = 0
    let fixture = CapsuleFixture()
    let scene = NativeMokuScene(state: state) {
        OutsideClickProbe { outsideClicks += 1 }
    } thread: { Text("Moku history") } dock: {
        ReplayObserved { NativeMokuDock(state: state, draft: draft, cwd: "/tmp",
            reply: fixture.reply ? NativeMokuDockReply(id: "reply", readKey: "reply", excerpt: "Reply fixture", executionID: "execution") : nil,
            interaction: fixture.interaction ? AnyView(Button { fixture.responseClicks += 1 } label: {
                Text("Respond \(fixture.responseClicks)").frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain)) : nil,
            interactionIsQuestion: fixture.question,
            loadMentionDirectories: { [.init(name: "Fixture", path: "/tmp/fixture")] }, onSend: { value in
            if failSend { throw ReplayFailure(description: "retry fixture") }
            sent.append(value)
        }, onCancel: {}) }
    } settings: { Text("Settings") }
    let host = NSHostingView(rootView: scene)
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 900, height: 700),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    func editor(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { editor($0) }.first
    }
    func sceneClick(_ point: CGPoint) throws {
        try click(CGPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y), in: host, window: window)
    }
    func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
        NSApp.sendEvent(event)
    }
    func capture(_ name: String) {
        guard let path = ProcessInfo.processInfo.environment["MOKU_CAPSULE_EVIDENCE"],
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
    }
    // This isolated app does not install the workspace Commands menu, so the
    // Cmd-Shift-B key equivalent has nowhere to route. Exercise the same scene
    // action that the production menu command invokes.
    func toggleComposeFromWorkspaceCommand() { state.toggleInput() }
    // Completion closes its last window; mouse replay needs fresh activation.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    try await waitFor("Capsule mouse replay requires an active key window") { NSApp.isActive && window.isKeyWindow }
    try await waitFor("Collapsed capsule did not mount") { state.capsuleFrame.width == NativeMokuCapsuleLayout.idleSize.width }
    capture("collapsed")
    let anchor = state.capsuleFrame
    try require(state.dockHitRects == [anchor.insetBy(dx: -5, dy: -5)],
                "Collapsed capsule retained a removed control's hit region")
    try sceneClick(CGPoint(x: anchor.minX - 29, y: anchor.midY))
    try await waitFor("Removed left controls still intercept clicks") { outsideClicks == 1 }
    try require(!state.mokuOpen && !state.inputOpen, "Removed left controls still navigate")
    outsideClicks = 0
    try sceneClick(CGPoint(x: anchor.midX, y: anchor.midY))
    try await Task.sleep(for: .milliseconds(100))
    try require(!state.inputOpen && !state.mokuOpen, "Single click unexpectedly opened Moku")
    toggleComposeFromWorkspaceCommand()
    do { try await waitFor("Compose command did not expand and focus production editor") {
        state.inputOpen && window.firstResponder is NSTextView
    } } catch { throw ReplayFailure(description: "\(error); open=\(state.inputOpen), responder=\(String(describing: window.firstResponder)), key=\(window.isKeyWindow), active=\(NSApp.isActive), anchor=\(anchor), capsule=\(state.capsuleFrame), host=\(host.bounds)") }
    try require(state.capsuleFrame.width > NativeMokuCapsuleLayout.idleSize.width && abs(state.capsuleFrame.maxY - anchor.maxY) < 0.5,
                "Expanding moved bottom anchor")
    guard let text = editor(host) else { throw ReplayFailure(description: "Missing production text editor") }
    text.insertText("@Fix", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await waitFor("Directory completion did not appear") { state.dockMentionHitRect != nil }
    try key(53, "\u{1b}")
    try await waitFor("Mention Escape collapsed composer instead of menu") { state.inputOpen && state.dockMentionHitRect == nil }
    text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
    text.insertText("Preserve 中文 draft", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await waitFor("Production binding missed edit") { draft.text == "Preserve 中文 draft" }
    try await Task.sleep(for: .milliseconds(450)); capture("expanded")
    if ProcessInfo.processInfo.environment["MOKU_CAPSULE_INSPECT"] == "1" { try await Task.sleep(for: .seconds(45)) }
    try key(53, "\u{1b}")
    try await waitFor("Escape did not collapse") { !state.inputOpen && !state.inputLeaving }
    try require(draft.text == "Preserve 中文 draft", "Escape lost draft")
    toggleComposeFromWorkspaceCommand()
    try await Task.sleep(for: .milliseconds(500))
    do { try await waitFor("Cmd Shift B did not reopen/focus") { state.inputOpen && window.firstResponder is NSTextView } }
    catch { throw ReplayFailure(description: "\(error); open=\(state.inputOpen), firstResponder=\(String(describing: window.firstResponder)), marked=\((window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true)") }
    try sceneClick(CGPoint(x: 32, y: 90))
    do { try await waitFor("Outside click did not collapse/pass through") { !state.inputOpen && outsideClicks == 1 } }
    catch { throw ReplayFailure(description: "\(error); open=\(state.inputOpen), outsideClicks=\(outsideClicks), active=\(NSApp.isActive)") }
    try require(draft.text == "Preserve 中文 draft", "Outside click lost draft")
    toggleComposeFromWorkspaceCommand()
    try await Task.sleep(for: .milliseconds(500))
    try await waitFor("Reopen focus failed") { state.inputOpen && window.firstResponder is NSTextView }
    try key(36, "\r")
    do { try await waitFor("Return did not use real submission path") { sent.count == 1 && draft.text.isEmpty && !state.inputOpen } }
    catch { throw ReplayFailure(description: "\(error); sent=\(sent.count), text=\(draft.text), open=\(state.inputOpen), editable=\(editor(host)?.isEditable == true)") }
    try require(sent[0].text == "Preserve 中文 draft", "Submission payload changed")
    try await Task.sleep(for: .milliseconds(500))
    failSend = true; draft.text = "retry draft"
    state.setInputOpen(true)
    try await Task.sleep(for: .milliseconds(500))
    try await waitFor("Retry editor not focused") { state.inputOpen && window.firstResponder is NSTextView }
    try key(36, "\r")
    try await waitFor("Failed send did not retain/reopen draft") { state.inputOpen && draft.error != nil && draft.text == "retry draft" }
    capture("send-error")
    state.setInputOpen(false)
    try await Task.sleep(for: .milliseconds(500))
    state.toggleMoku()
    try await waitFor("History shortcut failed") { state.mokuOpen && !state.cameraActive }
    state.toggleMoku()
    try await waitFor("History did not return") { !state.mokuOpen && !state.cameraActive }
    state.openSettings()
    try await Task.sleep(for: .milliseconds(550))
    state.closeSettings()
    try await waitFor("Settings close stuck waiting for retired flight") { !state.settingsOpen && !state.flightActive }
    window.setContentSize(CGSize(width: 420, height: 360))
    try await Task.sleep(for: .milliseconds(550))
    try require(abs(state.capsuleFrame.midX - state.dockViewport(in: host.bounds.size).midX) < 0.5,
                "Resize lost bottom center")
    capture("narrow")
    fixture.reply = true
    try await Task.sleep(for: .milliseconds(250))
    capture("reply")
    let replySurface = state.capsuleFrame
    let replyPoint = CGPoint(x: replySurface.maxX + 9, y: replySurface.minY - 3)
    try require(!state.dockHitRects.contains { $0.contains(replyPoint) }, "Removed unread badge still intercepts clicks")
    try require(state.dockHitRects == [replySurface.insetBy(dx: -5, dy: -5)],
                "Unread projection changed capsule hit regions")
    try require(state.liveReplyKey == "reply", "Reply projection did not update")
    state.markReplyRead("reply")
    try require(state.dockHitRects == [replySurface.insetBy(dx: -5, dy: -5)],
                "Read state changed capsule hit regions")
    fixture.reply = false
    for question in [false, true] {
        fixture.question = question; fixture.interaction = true
        try await Task.sleep(for: .milliseconds(300))
        let panel = NativeMokuCapsuleLayout.panel(in: state.dockViewport(in: host.bounds.size),
                                                  above: state.capsuleFrame, question: question)
        try require(state.dockHitRects.contains(panel), "Response panel missing from hit regions")
        capture(question ? "question-panel" : "permission-panel")
        // Native SwiftUI tracking in a background process consults the physical
        // pointer. Keep deterministic geometry/read-state coverage here; opt in
        // to Computer Use to exercise a real response-button click.
        if question, ProcessInfo.processInfo.environment["MOKU_CAPSULE_INSPECT"] == "panels" {
            let before = fixture.responseClicks
            try await Task.sleep(for: .seconds(30))
            try require(fixture.responseClicks == before + 1, "Computer Use response button did not fire exactly once")
        }
        fixture.interaction = false
        try await Task.sleep(for: .milliseconds(100))
    }
    await draft.dispose()
    print("PASS capsule placement, open/focus, Escape/draft, outside click-through, scene command actions, send/retry, history/settings, resize, mention Escape, removed left controls/badge hit routing, unread projection/read state and response panel geometry")
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    private func finish(error: Error? = nil) -> Never {
        let result: [String: Any] = ["ok": error == nil, "message": error.map(String.init(describing:))
            ?? (ProcessInfo.processInfo.environment["MOKU_CAPSULE_INSPECT"] == "contrast"
                || ProcessInfo.processInfo.environment["MOKU_CAPSULE_REPLAY"] == "appearance"
                ? "production capsule single-line alignment, scrollbars and theme/background contrast"
                : ProcessInfo.processInfo.environment["MOKU_CAPSULE_REPLAY"] == "completion"
                ? "dock/history native attachment paste, mention confirmation, navigation, IME, newline and no accidental send"
                : ProcessInfo.processInfo.environment["MOKU_CAPSULE_REPLAY"] == "pickers"
                ? "4 attachment picker open/cancel/reopen/dispose presentations"
                : "capsule lifecycle, geometry, focus, draft, send/retry, shortcuts, click routing, history/settings, theme/background contrast and 4 picker presentations")]
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.json")
        do {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        } catch {
            FileHandle.standardError.write(Data("Could not write replay result: \(error)\n".utf8))
            exit(1)
        }
        exit(error == nil ? 0 : 1)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                if ProcessInfo.processInfo.environment["MOKU_CAPSULE_INSPECT"] == "presentation" {
                    try await inputPresentationReplay()
                } else if ProcessInfo.processInfo.environment["MOKU_CAPSULE_INSPECT"] == "contrast"
                            || ProcessInfo.processInfo.environment["MOKU_CAPSULE_REPLAY"] == "appearance" {
                    try await capsuleAppearanceReplay()
                } else if ProcessInfo.processInfo.environment["MOKU_CAPSULE_REPLAY"] == "completion" {
                    try await inputCompletionReplay()
                } else if ProcessInfo.processInfo.environment["MOKU_CAPSULE_REPLAY"] == "pickers" {
                    for narrow in [true, false] { try await replay(narrow: narrow) }
                } else {
                    try await inputCompletionReplay()
                    try await capsuleReplay()
                    try await capsuleAppearanceReplay()
                    for narrow in [true, false] {
                        try await replay(narrow: narrow)
                    }
                }
                finish()
            } catch {
                finish(error: error)
            }
        }
    }
}

@main private enum Main {
    static func main() {
        let delegate = Delegate()
        let app = NSApplication.shared
        app.setActivationPolicy(ProcessInfo.processInfo.environment["MOKU_CAPSULE_INSPECT"] != nil ? .regular : .accessory)
        app.delegate = delegate
        app.run()
    }
}
