import AppKit
import Observation
import MokuseiCore
import MokuseiHarnessCodex
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI
import ScreenCaptureKit
import SwiftUI
import Vision

// Snapshots go directly to the production monitor, never into AppKit dispatch.
private final class NoteScrollSample: NSEvent {
    var target: NSWindow?
    var point = CGPoint.zero
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var direct: NSEvent.Phase = .began
    var inertia: NSEvent.Phase = []
    var precise = true
    var inverted = true
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var isDirectionInvertedFromDevice: Bool { inverted }
    override var phase: NSEvent.Phase { direct }
    override var momentumPhase: NSEvent.Phase { inertia }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}

private struct Failure: Error, CustomStringConvertible { let description: String }
@MainActor func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}
@MainActor func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw Failure(description: message) }
    return value
}
@MainActor func wait(_ label: String, _ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw Failure(description: label)
}
@MainActor func find<T: NSView>(_ root: NSView, _ type: T.Type) -> T? {
    if let view = root as? T { return view }
    return root.subviews.lazy.compactMap { find($0, type) }.first
}
@MainActor func find<T: NSView>(_ root: NSView, _ type: T.Type, where predicate: (T) -> Bool) -> T? {
    if let view = root as? T, predicate(view) { return view }
    for child in root.subviews { if let match = find(child, type, where: predicate) { return match } }
    return nil
}
@MainActor func viewTree(_ view: NSView, depth: Int = 0) -> String {
    let line = String(repeating: " ", count: depth * 2) + String(describing: type(of: view))
        + " \(NSStringFromRect(view.frame))"
    return ([line] + view.subviews.map { viewTree($0, depth: depth + 1) }).joined(separator: "\n")
}
@MainActor func axTexts(_ view: NSView) -> Set<String> {
    var result = Set<String>()
    if let label = view.accessibilityLabel(), !label.isEmpty { result.insert(label) }
    if let value = view.accessibilityValue() as? String, !value.isEmpty { result.insert(value) }
    if let field = view as? NSTextField, !field.stringValue.isEmpty { result.insert(field.stringValue) }
    if let text = view as? NSTextView, !text.string.isEmpty { result.insert(text.string) }
    for child in view.accessibilityChildren() ?? [] {
        if let child = child as? NSView { result.formUnion(axTexts(child)) }
    }
    for child in view.subviews { result.formUnion(axTexts(child)) }
    return result
}

@MainActor private struct Harness: HarnessPlugin {
    let descriptor = HarnessPluginDescriptor(id: "mock", displayName: "Fixture",
        threadCapabilities: .init(instructions: false, threadContext: false, sendContext: false, toolModes: []))
    let logoSource = ""
    var threadSettingsCodec: PluginValueCodec<JSONValue> { .json }
    var harnessSettingsCodec: PluginValueCodec<JSONValue> { .json }
    var settingsPresentationCodec: PluginValueCodec<JSONValue> { .json }
    func logo(size: CGFloat) -> some View { CodexLogo(size: size) }
    func projectOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewProjection<String> {
        .init(footprint: .init(columns: 1, rows: 1), structureKey: "fixture", excerpt: "", view: "")
    }
    func threadView(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext) -> some View { EmptyView() }
    func overviewCard(input: HarnessThreadInput, projection: String, actions: HarnessThreadActions, openThread: @escaping () -> Void) -> some View { EmptyView() }
    func threadSettings(input: HarnessThreadInput, resource: HarnessSettingsResource<JSONValue>, update: @escaping (JSONValue) async throws -> Void) -> some View { EmptyView() }
    func harnessSettings(props: HarnessSettingsProps<JSONValue, JSONValue>) -> some View { EmptyView() }
}

@MainActor @Observable final class Fixture {
    let state: NativeMokuSceneState
    var regions: NativeCanvasInputRegions { state.canvasInputRegions }
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    let workspace: NativeWorkspaceModel
    let overview: NativeOverviewWorkspaceModel
    let presentation: NativeMokuWorkspacePresentation
    var scheme: ColorScheme = .light
    var voiceMotionDisabled = false
    var voiceActive = false
    var voiceTranscript: NativeMokuTalkMessage?
    var voiceControlClicks = 0
    var overrideNote: NativeMokuNote?
    var usesOverrideNote = false
    var exposureAttempts: [String] = []
    var displayedNote: NativeMokuNote? { usesOverrideNote ? overrideNote : presentation.note }
    private var revision = 0
    private var snapshot: JSONValue?
    private let authority = UUID()

    init(directory: URL) throws {
        state = NativeMokuSceneState()
        workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory, homeDirectory: directory)),
            preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [AnyHarnessPlugin(Harness())], sidecards: [], applications: []))
        overview = NativeOverviewWorkspaceModel(workspace: workspace,
            applications: .init(projectionCapabilities: { _, _ in throw CancellationError() }, rendererContext: { _, _, _ in throw CancellationError() }))
        presentation = NativeMokuWorkspacePresentation(workspace: workspace, overview: overview)
    }
    func install(_ thread: JSONValue) throws {
        revision += 1
        let hydrated: JSONValue = .object(["revision": .integer(revision), "settingsRevision": .integer(0),
            "defaultCwd": .text("/isolated/moku"), "settings": .object([:]), "threads": .array([thread]),
            "executions": .array([]), "applicationThreads": .array([])])
        let event: RuntimeClientEvent
        if let previous = snapshot, let old = previous["threads"]?.arrayValue?.first,
           (thread["revision"]?.intValue ?? 0) > (old["revision"]?.intValue ?? 0) {
            let mutation: JSONValue = .object(["type": .text("state-patched"),
                "baseRevision": .integer(revision - 1), "revision": .integer(revision),
                "threads": .object(["upserts": .array([thread]), "removedIds": .array([])])])
            let next = try RuntimeState.applying(mutation, to: previous)
            try workspace.catalog.install(next); snapshot = next
            event = .mutation(mutation, state: next, authority: authority)
        } else {
            try workspace.catalog.install(hydrated); snapshot = hydrated
            event = .snapshot(hydrated, authority: authority)
        }
        overview.receive(event); presentation.receive(event)
    }
}
private struct Dock: View {
    let fixture: Fixture
    var body: some View {
        NativeMokuDock(state: fixture.state, draft: fixture.draft, cwd: "/isolated/moku",
            mode: fixture.presentation.dockMode, running: fixture.presentation.running,
            talk: nil,
            voiceControls: AnyView(Button { fixture.voiceControlClicks += 1 } label: {
                Image(systemName: "mic").frame(width: 34, height: 34)
            }.buttonStyle(.plain)),
            voiceStatusVisible: fixture.voiceActive, voiceModeActive: fixture.voiceActive,
            voiceTranscript: fixture.voiceTranscript,
            presentation: fixture.presentation, note: fixture.displayedNote,
            onSend: { _ in }, onCancel: {})
    }
}
private struct Scene: View {
    let fixture: Fixture
    var body: some View {
        NativeMokuScene(state: fixture.state) {
            NativeOverviewWorkspaceView(model: fixture.overview, callbacks: .init(
                openThread: { _, _ in }, openApplication: { _, _ in }, onSettings: {}))
        } thread: {
            Text("History fixture")
        } dock: { Dock(fixture: fixture) } settings: { Text("Settings fixture") }
        .environment(\.nativeCanvasInputRegions, fixture.regions)
        .environment(\.colorScheme, fixture.scheme)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .transaction { transaction in
            if fixture.voiceMotionDisabled {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }
}

private func coversFullWindow(_ image: CGImage) -> Bool {
    var rgba = [UInt8](repeating: 0, count: 32 * 32 * 4)
    return rgba.withUnsafeMutableBytes { buffer in
        let cg = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let bytes = buffer.bindMemory(to: UInt8.self)
        return stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 240 }.count >= 1000
    }
}

@MainActor private func replay() async throws {
    guard CommandLine.arguments.count >= 3 else { throw Failure(description: "Expected note-records.json and evidence directory") }
    let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let evidence = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    let data = try JSONValue.parse(data: Data(contentsOf: fixtureURL))
    guard let records = data["records"]?.arrayValue, let texts = data["texts"]?.arrayValue?.compactMap(\.stringValue),
          records.count == 3, texts.count == 3 else { throw Failure(description: "Missing real Go update_note records") }
    // Exercise the production pending-submission owner independently of Cocoa
    // activation timing: errors wait for an explicit retry and never change
    // the catalog-derived indicator.
    let retryState = NativeMokuSceneState()
    let retryNote = NativeMokuNote(id: "retry-note", text: "Pending review", revision: 1, updatedAt: 1)
    var retryAttempts = 0
    retryState.submitNoteExposure = { _, _ in
        retryAttempts += 1
        if retryAttempts == 1 { throw Failure(description: "fixture disconnected") }
        return "accepted"
    }
    retryState.recordNoteExposure(retryNote)
    try await wait("Failed receipt was never submitted") { retryAttempts == 1 }
    try await Task.sleep(for: .milliseconds(100))
    try require(retryAttempts == 1 && retryState.noteUnread(retryNote), "Failed receipt retried eagerly or changed the indicator")
    retryState.suspendNoteExposureSubmission()
    retryState.reconcileNoteExposure(retryNote)
    retryState.retryNoteExposure()
    try await wait("Same-version reconnect lost completed pending evidence") { retryAttempts == 2 }
    try require(retryState.noteUnread(retryNote), "Accepted response optimistically changed catalog evidence")
    retryState.suspendNoteExposureSubmission()
    retryState.reconcileNoteExposure(NativeMokuNote(id: "retry-note", text: "New version", revision: 2, updatedAt: 2))
    retryState.retryNoteExposure()
    try await Task.sleep(for: .milliseconds(100))
    try require(retryAttempts == 2, "New-version reconciliation retried an obsolete receipt")
    retryState.resetNoteExposureAuthority()
    let profile = evidence.appendingPathComponent("isolated-profile")
    // Every replay owns a fresh profile and no local note-read authority.
    try? FileManager.default.removeItem(at: profile)
    let noteSeen = profile.appendingPathComponent("native-moku-note-seen.json")
    let fixture = try Fixture(directory: profile)
    fixture.state.submitNoteExposure = { [weak fixture] id, revision in
        fixture?.exposureAttempts.append("\(id.string):\(revision)")
        return "accepted"
    }
    let host = NSHostingView(rootView: Scene(fixture: fixture))
    let window = NSWindow(contentRect: CGRect(x: 150, y: 100, width: 900, height: 620),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.level = .floating
    window.title = "Production Moku note regression replay"
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    try await wait("Scene did not mount") { fixture.state.windowVisible && fixture.state.capsuleFrame.height > 0 }
    var measurements: [[String: Any]] = []

    @discardableResult
    func capture(_ name: String) async throws -> CGImage {
        var target: SCWindow?
        for _ in 0..<30 {
            let content = try await SCShareableContent.currentProcess
            target = content.windows.first { $0.windowID == CGWindowID(window.windowNumber)
                && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                && abs($0.frame.width - window.frame.width) < 1 && abs($0.frame.height - window.frame.height) < 1 }
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let target else { throw Failure(description: "No full-size own window; refusing thumbnail evidence") }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2); configuration.height = Int(window.frame.height * 2)
        configuration.ignoreShadowsSingleWindow = true; configuration.showsCursor = false
        configuration.capturesAudio = false; configuration.captureMicrophone = false
        var captured: CGImage?
        let filter = SCContentFilter(desktopIndependentWindow: target)
        for _ in 0..<40 {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            if coversFullWindow(image) { captured = image; break }
            try await Task.sleep(for: .milliseconds(75))
        }
        guard let image = captured else { throw Failure(description: "Refusing transformed/thumbnail WindowServer evidence") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: evidence.appendingPathComponent(name + ".png"))
        return image
    }
    func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    func textViews(_ root: NSView) -> [NSTextView] {
        var result: [NSTextView] = []
        if let view = root as? NSTextView { result.append(view) }
        for child in root.subviews { result += textViews(child) }
        return result
    }
    func panelText() -> String? {
        let parts = textViews(host).filter { $0.isSelectable && !$0.isEditable && !$0.string.isEmpty }.map(\.string)
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
    func rectValues(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY),
         "width": Double(rect.width), "height": Double(rect.height)]
    }
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(650))
        host.layoutSubtreeIfNeeded()
    }
    func checkExpandedSurface(above collapsed: CGRect, label: String) throws {
        let surface = fixture.state.capsuleFrame
        try require(surface.width <= min(480, host.bounds.width - 48) + 1,
                    "\(label): expanded surface exceeded the viewport's note width: \(surface)")
        try require(surface.width > collapsed.width && surface.height > collapsed.height,
                    "\(label): the Moku surface itself did not grow: \(collapsed) → \(surface)")
        try require(abs(surface.maxY - collapsed.maxY) < 1,
                    "\(label): expansion lost Moku's bottom anchor: \(collapsed) → \(surface)")
        try require(surface.minX >= 0 && surface.maxX <= host.bounds.width + 1 && surface.minY >= 0,
                    "\(label): expanded Moku escaped the window: \(surface), window \(host.bounds)")
        // The sole published surface contains the note and Moku row, rather
        // than exposing the old capsule and a detached panel as two regions.
        try require(fixture.state.dockHitRects.count == 1,
                    "\(label): note retained separate panel/button hit regions: \(fixture.state.dockHitRects)")
        try require(fixture.state.dockHitRects[0].contains(surface),
                    "\(label): dismissal bounds did not cover the expanded Moku surface")
        let blankAbove = CGPoint(x: surface.midX, y: max(0, surface.minY - 10))
        try require(!NativeMokuOutsideClick.isInside(point: blankAbove, dockRects: fixture.state.dockHitRects),
                    "\(label): blank space above the fitted surface swallowed outside clicks")
        measurements.append(["state": label, "surface": rectValues(surface), "collapsed": rectValues(collapsed)])
    }

    try fixture.install(records[0])
    try await wait("First note did not reach the presentation") { fixture.presentation.note?.text == texts[0] }
    try await settle()
    let collapsed = fixture.state.capsuleFrame
    let visibleWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
    try await capture("light-collapsed")
    let note = fixture.presentation.note
    try require(fixture.state.noteUnread(note), "A new note was not unread")
    let swipe = try unwrap(find(host, NativeMokuSwipeMonitor.MonitorView.self), "Missing production note swipe monitor")
    func scroll(_ y: CGFloat, x: CGFloat = 0, phase: NSEvent.Phase = .began,
                momentum: NSEvent.Phase = [], point: CGPoint? = nil,
                precise: Bool = true, inverted: Bool = true) async throws -> NSEvent? {
        // Snapshot events must not race physical mouse presses on the desktop.
        try await wait("Physical mouse remained pressed during scroll replay") { NSEvent.pressedMouseButtons == 0 }
        let event = NoteScrollSample()
        event.target = window
        let p = point ?? CGPoint(x: collapsed.midX, y: collapsed.midY)
        event.point = swipe.convert(p, to: nil)
        event.dy = y; event.dx = x; event.direct = phase; event.inertia = momentum
        event.precise = precise; event.inverted = inverted
        return swipe.handle(event)
    }
    let mokuPoint = swipe.convert(CGPoint(x: collapsed.midX, y: collapsed.midY), to: nil)
    try require(fixture.regions.contains(mokuPoint, in: window), "Moku did not exclude canvas navigation")
    if let canvas = find(host, NativeOverviewScrollInput.MonitorView.self) {
        try require(!canvas.canStart(at: canvas.canvasPoint(mokuPoint)), "Canvas acquired Moku's scroll gesture")
    } else { throw Failure(description: "Missing production overview scroll monitor") }
    try require(try await scroll(-40, point: CGPoint(x: 20, y: 20)) != nil, "Outside scrolling was consumed")
    _ = try await scroll(-40, phase: .changed)
    try require(!fixture.state.notePanelOpen, "Gesture starting elsewhere opened the note after entering Moku")
    _ = try await scroll(40)
    try require(!fixture.state.notePanelOpen, "Downward fingers opened the note")
    _ = try await scroll(-40, x: 60)
    try require(!fixture.state.notePanelOpen && !fixture.state.inputOpen, "Diagonal gesture triggered a mode")
    _ = try await scroll(-40, phase: [], momentum: .began)
    try require(!fixture.state.notePanelOpen, "Momentum opened the note")
    _ = try await scroll(-40, phase: [], precise: false)
    try require(!fixture.state.notePanelOpen, "Mouse wheel opened the note")
    _ = try await scroll(-10)
    try require(!fixture.state.notePanelOpen, "Small touch opened the note")
    _ = try await scroll(-16, phase: .changed)
    try await Task.sleep(for: .milliseconds(100))
    try await capture("light-note-expanding")
    try await wait("Note panel did not open") { fixture.state.notePanelOpen }
    try await wait("Moku surface did not expand") { fixture.state.capsuleFrame.height > collapsed.height }
    try await wait("Note panel did not render the Markdown body") { panelText()?.contains("Dispatched the schema migration") == true }
    try require(fixture.state.noteUnread(note), "Opening alone incorrectly marked the note exposed")
    try require(!FileManager.default.fileExists(atPath: noteSeen.path), "Legacy note-seen authority was written")
    try require(fixture.exposureAttempts.isEmpty, "Opening emitted exposure before dwell")
    fixture.state.setNotePanelOpen(false)
    try await settle()
    try require(fixture.exposureAttempts.isEmpty, "Quick close emitted exposure")
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try await wait("Note replay could not become foreground/key") { NSApp.isActive && window.isKeyWindow }
    fixture.state.openNotePanelFromUser()
    try await wait("Note did not reopen") { fixture.state.notePanelOpen }
    try await Task.sleep(for: .milliseconds(2_300))
    let exposureView = find(host, NSView.self, where: { String(describing: type(of: $0)).contains("ExposureView") })
    let exposureClip = exposureView?.enclosingScrollView?.contentView
    try require(fixture.exposureAttempts.contains("\(note?.id.string ?? ""):1"),
                "Stable complete short note did not emit exposure: active=\(NSApp.isActive) key=\(window.isKeyWindow) " +
                "probe=\(exposureView.map { String(describing: $0.bounds) } ?? "nil") " +
                "clip=\(exposureClip.map { String(describing: $0.bounds) } ?? "nil") " +
                "generation=\(fixture.state.noteOpenGeneration)")
    try await settle()
    try checkExpandedSurface(above: collapsed, label: "short-note-open")
    try require(Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)) == visibleWindows,
                "Opening the note created a separate visible AppKit window")
    try await capture("light-note-expanded")
    measurements.append(["state": "open", "text": panelText() ?? "", "unexposed": fixture.state.noteUnread(note)])

    _ = try await scroll(-80, phase: [], momentum: .changed)
    try require(fixture.state.notePanelOpen && !fixture.state.inputOpen, "Opening gesture toggled or opened the composer")
    fixture.state.setNotePanelOpen(false)
    try await settle()
    _ = try await scroll(30, inverted: false)
    try await wait("Finger-up with Natural Scrolling disabled did not open") { fixture.state.notePanelOpen }
    try await settle()

    // A catalog update replaces content in place but has no new exposure.
    try fixture.install(records[1])
    try await wait("Open panel did not update in place") { panelText()?.contains("Schema migration merged") == true }
    try await Task.sleep(for: .milliseconds(2_300))
    try require(!fixture.exposureAttempts.contains("\(note?.id.string ?? ""):2"),
                "A new revision in an open panel emitted exposure without user action")
    try require(fixture.state.noteUnread(fixture.presentation.note), "A new version was optimistically marked exposed")
    try require(!FileManager.default.fileExists(atPath: noteSeen.path), "A note-seen file was recreated")
    fixture.scheme = .dark; window.appearance = NSAppearance(named: .darkAqua)
    try await Task.sleep(for: .milliseconds(300))
    try await capture("dark-note-expanded")

    // Left swipe on the retained Moku row switches from note to composer.
    let noteRow = CGPoint(x: fixture.state.capsuleFrame.midX, y: fixture.state.capsuleFrame.maxY - 22)
    _ = try await scroll(0, x: 30, point: noteRow, inverted: false)
    try await wait("Left swipe from note did not open composer") { fixture.state.inputOpen }
    // Composer and interaction panels take priority over the note.
    try require(!fixture.state.notePanelOpen, "Opening the composer kept the note panel")
    try await settle()
    _ = try await scroll(-40)
    try require(!fixture.state.notePanelOpen && fixture.state.inputOpen, "Swipe stole focus from the composer")
    fixture.state.setInputOpen(false)
    try await wait("Composer did not collapse") { !fixture.state.inputLeaving }
    fixture.state.openNotePanelFromUser()
    try await wait("Panel did not reopen") { panelText()?.contains("Schema migration merged") == true }
    fixture.state.setDockInteractionVisible(true, question: false)
    try require(!fixture.state.notePanelOpen, "A permission/question panel kept the note panel")
    try await settle()
    _ = try await scroll(-40)
    try require(!fixture.state.notePanelOpen, "Swipe opened a note over an interaction")
    fixture.state.setDockInteractionVisible(false, question: false)

    // Escape closes the panel.
    fixture.state.setNotePanelOpen(true)
    try await wait("Panel did not reopen for Escape") { fixture.state.notePanelOpen }
    // State intent is synchronous; let SwiftUI mount the native key monitor.
    try await settle()
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: 53)!
    NSApp.sendEvent(escape)
    try await wait("Escape did not close the note panel") { !fixture.state.notePanelOpen }

    // An outside click closes the panel; an inside click does not.
    fixture.state.setNotePanelOpen(true)
    try await wait("Panel did not reopen for outside click") { fixture.state.notePanelOpen }
    try await settle()
    func click(_ point: CGPoint) async throws {
        try await wait("Physical mouse remained pressed during click replay") { NSEvent.pressedMouseButtons == 0 }
        window.makeKeyAndOrderFront(nil)
        // Published Dock geometry uses SwiftUI's top-left origin; AppKit
        // events use the window's bottom-left origin.
        let location = CGPoint(x: point.x, y: host.bounds.height - point.y)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        // Queue both events so SwiftUI sees AppKit's actual currentEvent.
        // Enqueue release before yielding: native text/button tracking can
        // synchronously wait for mouse-up while dispatching mouse-down.
        NSApp.postEvent(event(.leftMouseDown), atStart: false)
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        try await Task.sleep(for: .milliseconds(100))
    }
    try await click(CGPoint(x: 20, y: 20))
    try await wait("Outside click did not close the note panel") { !fixture.state.notePanelOpen }
    fixture.state.setNotePanelOpen(true)
    try await wait("Panel did not reopen for inside click") { fixture.state.notePanelOpen }
    try await settle()
    try await click(CGPoint(x: fixture.state.capsuleFrame.midX, y: fixture.state.capsuleFrame.minY + 12))
    try await Task.sleep(for: .milliseconds(100))
    try require(fixture.state.notePanelOpen, "An inside click closed the note panel")
    try await click(CGPoint(x: fixture.state.capsuleFrame.maxX - 30, y: fixture.state.capsuleFrame.minY + 30))
    try await wait("The title close control did not collapse the note") { !fixture.state.notePanelOpen }
    try await Task.sleep(for: .milliseconds(100))
    try await capture("dark-note-contracting")
    try await settle()
    try require(abs(fixture.state.capsuleFrame.width - collapsed.width) < 1 &&
                abs(fixture.state.capsuleFrame.height - collapsed.height) < 1 &&
                abs(fixture.state.capsuleFrame.maxY - collapsed.maxY) < 1,
                "Closing the note did not restore Moku's original size and bottom anchor")
    try await capture("dark-note-collapsed-again")
    try await click(CGPoint(x: collapsed.midX, y: collapsed.midY))
    try await Task.sleep(for: .milliseconds(100))
    try require(!fixture.state.notePanelOpen && !fixture.state.inputOpen, "Single click still opened a mode")
    _ = try await scroll(0, x: 40)
    try require(!fixture.state.inputOpen, "Right swipe opened the composer")
    _ = try await scroll(0, x: -12)
    try require(!fixture.state.inputOpen, "Small left touch opened the composer")
    _ = try await scroll(0, x: -16, phase: .changed)
    try await wait("Left swipe did not open the Moku composer") { fixture.state.inputOpen }
    try require(!fixture.state.notePanelOpen, "Left swipe opened the note")
    fixture.state.setInputOpen(false)
    try await settle()

    // Voice is a presentation fixture: no microphone/provider is opened. Route
    // through the production Dock monitor and reuse its real note/close paths.
    // Inactive apps can pause SwiftUI presentation animations. Keep functional
    // hit tests deterministic; ordinary motion checks outside this section remain.
    fixture.voiceMotionDisabled = true
    fixture.draft.text = "keep this voice draft"
    fixture.state.setInputOpen(true)
    try await settle()
    try await wait("Original composer did not receive focus") {
        (window.firstResponder as? NSTextView)?.isEditable == true
    }
    fixture.voiceActive = true
    try await wait("Voice did not retain the composer seat") { !fixture.state.inputOpen && !fixture.state.inputLeaving }
    try await settle()
    try require((window.firstResponder as? NSTextView)?.isEditable != true, "Voice retained hidden editor focus")
    let voiceRow = fixture.state.capsuleFrame
    let voicePoint = CGPoint(x: voiceRow.midX, y: voiceRow.midY)
    let controlPoint = CGPoint(x: voiceRow.maxX - 20, y: voiceRow.midY)
    try require(try await scroll(-40, point: controlPoint) != nil, "Voice control scroll was acquired by Moku")
    _ = try await scroll(-40, phase: .changed, point: voicePoint)
    try require(!fixture.state.notePanelOpen, "Scroll starting on voice controls acquired the note")
    try await click(controlPoint)
    try require(fixture.voiceControlClicks == 1 && !fixture.state.notePanelOpen, "Voice button click was stolen")
    _ = try await scroll(0, x: -40, point: voicePoint)
    try require(!fixture.state.inputOpen && !fixture.state.notePanelOpen, "Voice left swipe changed the composer seat")
    for (y, x, phase, momentum, precise) in [
        (CGFloat(40), CGFloat(0), NSEvent.Phase.began, NSEvent.Phase(), true),
        (-40, 60, .began, [], true), (-40, 0, [], .began, true),
        (-40, 0, [], [], false), (-10, 0, .began, [], true)
    ] {
        _ = try await scroll(y, x: x, phase: phase, momentum: momentum, point: voicePoint, precise: precise)
        try require(!fixture.state.notePanelOpen, "Non-upward/direct voice gesture opened note")
    }
    _ = try await scroll(-40, point: CGPoint(x: 20, y: 20))
    _ = try await scroll(-40, phase: .changed, point: voicePoint)
    try require(!fixture.state.notePanelOpen, "Outside-origin voice scroll acquired note")
    fixture.state.setSearchActive(true)
    _ = try await scroll(-40, point: voicePoint)
    try require(!fixture.state.notePanelOpen, "Covered voice Dock opened note")
    fixture.state.setSearchActive(false)
    fixture.state.setDockInteractionVisible(true, question: false)
    _ = try await scroll(-40, point: voicePoint)
    try require(!fixture.state.notePanelOpen, "Voice note overrode an interaction")
    fixture.state.setDockInteractionVisible(false, question: false)
    try await settle()
    _ = try await scroll(-10, point: voicePoint)
    _ = try await scroll(-16, phase: .changed, point: voicePoint)
    try await wait("Voice upward swipe did not open note") { fixture.state.notePanelOpen }
    try await settle()
    try require(panelText()?.contains("Schema migration merged") == true, "Voice did not reuse persisted note content")
    try await capture("voice-note-expanded")
    let noteBody = CGPoint(x: fixture.state.capsuleFrame.midX, y: fixture.state.capsuleFrame.minY + 65)
    try require(try await scroll(-40, point: noteBody) != nil, "Voice swipe acquired note reading scroll")
    NSApp.sendEvent(escape)
    try await wait("Voice note Escape did not close") { !fixture.state.notePanelOpen }
    try await settle()
    _ = try await scroll(30, point: voicePoint, inverted: false)
    try await wait("Voice upward swipe with natural scrolling disabled failed") { fixture.state.notePanelOpen }
    try await settle()
    try await click(CGPoint(x: 20, y: 20))
    try await wait("Voice note outside click did not close") { !fixture.state.notePanelOpen }
    try await settle()

    // A transcript keeps its native scrolling region; only the eye seat opens notes.
    fixture.voiceTranscript = NativeMokuTalkMessage(id: "voice-fixture", text: "Voice transcript stays visible")
    try await settle()
    let transcriptRow = fixture.state.capsuleFrame
    _ = try await scroll(-40, point: CGPoint(x: transcriptRow.midX, y: transcriptRow.midY))
    try require(!fixture.state.notePanelOpen, "Transcript scrolling opened note")
    _ = try await scroll(-40, point: CGPoint(x: transcriptRow.minX + 30, y: transcriptRow.midY))
    try await wait("Voice transcript eye swipe did not open note") { fixture.state.notePanelOpen }
    try await settle()
    try await capture("voice-transcript-note-expanded")
    try await click(CGPoint(x: fixture.state.capsuleFrame.maxX - 30, y: fixture.state.capsuleFrame.minY + 30))
    try await wait("Voice note close control failed") { !fixture.state.notePanelOpen }
    try require(fixture.voiceActive && fixture.voiceControlClicks == 1 && fixture.draft.text == "keep this voice draft",
                "Note interactions changed voice controls or draft")
    fixture.state.setNotePanelOpen(true)
    fixture.state.overviewVisible = false
    try require(!fixture.state.notePanelOpen, "Leaving Overview retained voice note")
    fixture.state.overviewVisible = true
    fixture.voiceTranscript = nil
    try await settle()
    fixture.state.setNotePanelOpen(true)
    try await settle()
    fixture.voiceActive = false
    try await wait("Ending voice over a note did not restore the original composer and focus") {
        fixture.state.inputOpen && !fixture.state.notePanelOpen
            && (window.firstResponder as? NSTextView)?.isEditable == true
    }
    try require(fixture.draft.text == "keep this voice draft", "Voice note lost the restored draft")
    fixture.state.setInputOpen(false)
    try await settle()

    // A voice session started from idle must not invent an editor restoration.
    // Exercise the same note command with no persisted note in a narrow viewport.
    fixture.voiceActive = true
    fixture.usesOverrideNote = true
    fixture.overrideNote = nil
    window.setContentSize(NSSize(width: 340, height: 420))
    try await settle()
    let narrowVoiceRow = fixture.state.capsuleFrame
    _ = try await scroll(-40, point: CGPoint(x: narrowVoiceRow.midX, y: narrowVoiceRow.midY))
    try await wait("Voice could not open an empty note") { fixture.state.notePanelOpen }
    try await settle()
    try checkExpandedSurface(above: narrowVoiceRow, label: "voice-empty-note-narrow")
    let emptyVoiceText = try recognizedText(try await capture("voice-empty-note-narrow"))
    try require(emptyVoiceText.contains("还没有"), "Empty voice note retained stale content: \(emptyVoiceText)")
    fixture.state.toggleNotePanel()
    try require(!fixture.state.notePanelOpen && !fixture.state.inputOpen, "Voice note command opened the editor")
    fixture.state.toggleNotePanel()
    fixture.voiceActive = false
    try await settle()
    try require(fixture.state.notePanelOpen && !fixture.state.inputOpen,
                "Ending idle-origin voice changed the note or opened an editor")
    try require((window.firstResponder as? NSTextView)?.isEditable != true, "Idle-origin voice invented editor focus")
    fixture.state.setNotePanelOpen(false)
    let unsupported: [(String, String)] = [
        ("code", "# Code case\n\n```swift\nlet value = 1\n```"),
        ("table", "# Table case\n\n| Key | Value |\n| --- | --- |\n| a | b |"),
        ("image", "# Image case\n\n![preview](/tmp/mokusei-note-missing.png)"),
        ("local-link", "# Link case\n\n[preview](/tmp/mokusei-note-missing.png)")
    ]
    for (kind, source) in unsupported {
        fixture.overrideNote = NativeMokuNote(id: JSONText("unsupported-\(kind)"),
                                               text: source, revision: 1, updatedAt: 3)
        try await settle()
        fixture.state.openNotePanelFromUser()
        let marker = kind == "local-link" ? "Link case" : "\(kind.capitalized) case"
        try await wait("Unsupported \(kind) note did not render") { panelText()?.contains(marker) == true }
        try await Task.sleep(for: .milliseconds(2_300))
        try require(!fixture.exposureAttempts.contains("unsupported-\(kind):1"),
                    "Unsupported \(kind) Markdown emitted complete exposure")
        fixture.state.setNotePanelOpen(false)
    }
    fixture.usesOverrideNote = false
    window.setContentSize(NSSize(width: 900, height: 620))
    try await settle()
    measurements.append(["state": "voice-note", "draftPreserved": true, "focusRestored": true,
                         "idleOriginKeepsNote": true, "controlClicks": fixture.voiceControlClicks])
    fixture.voiceMotionDisabled = false
    try await settle()

    if CommandLine.arguments.contains("--voice-only") {
        let report: [String: Any] = ["source": data["source"]?.stringValue ?? "unknown",
            "measurements": measurements,
            "checks": ["production Dock upward note swipe during voice, both natural scrolling settings",
                "voice control scroll exclusion and native click delivery; left swipe leaves composer closed",
                "outside-origin, wheel, momentum, diagonal, small, covered and interaction gestures rejected",
                "transcript and note body retain scrolling; Escape, outside click and close button dismiss",
                "note navigation preserves draft and original composer focus restoration",
                "empty note fits narrow voice Dock; note command and idle-origin voice termination preserve editor ownership"],
            "limits": "Voice functional checks disable animations to avoid inactive-app presentation pauses; status/transcript and button actions are fixtures; no live microphone, playback or provider session. Later rapid-toggle and narrow-window long-note layout stress cases are excluded."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("report.json"))
        await fixture.draft.dispose()
        return
    }

    // Redirecting the same glass surface must not leave an exiting note or an
    // oversized capsule behind when the user changes their mind mid-motion.
    for _ in 0..<6 {
        fixture.state.setNotePanelOpen(true)
        try await Task.sleep(for: .milliseconds(35))
        fixture.state.setNotePanelOpen(false)
        try await Task.sleep(for: .milliseconds(35))
    }
    fixture.state.setNotePanelOpen(true)
    try await settle()
    try checkExpandedSurface(above: collapsed, label: "rapid-toggle-final-open")
    fixture.state.setInputOpen(true)
    try require(!fixture.state.notePanelOpen, "Composer lost priority after rapid note toggles")
    fixture.state.setInputOpen(false)
    try await wait("Composer did not finish leaving after rapid toggle") { !fixture.state.inputLeaving }
    try await settle()
    try require(abs(fixture.state.capsuleFrame.height - collapsed.height) < 1,
                "Rapid toggle/composer interruption stranded an expanded surface")

    // Keep real Coordinator records for lifecycle checks above, and inject a
    // UI-only contract-sized note for the wrapping and scrolling stress case.
    let longText = "# Long note\n\n" + (1...24).map {
        "- Milestone \($0): migration review is complete."
    }.joined(separator: "\n") + "\n\nFinal milestone"
    try require(longText.unicodeScalars.count <= ThreadNote.maximumCodePoints,
                "Long-note fixture exceeded the production contract")
    fixture.overrideNote = NativeMokuNote(id: "long-note-fixture", text: longText, revision: 1, updatedAt: 3)
    fixture.usesOverrideNote = true
    window.setContentSize(NSSize(width: 340, height: 420))
    try await settle()
    let narrowCollapsed = fixture.state.capsuleFrame
    fixture.state.openNotePanelFromUser()
    try await wait("Long note did not render") { panelText()?.contains("Final milestone") == true }
    func availableNoteSurface() -> CGRect {
        NativeMokuCapsuleLayout.frame(in: fixture.state.dockViewport(in: host.bounds.size), landing: false)
    }
    do {
        try await wait("Long note did not fill the available surface") {
            fixture.state.capsuleFrame.height >= availableNoteSurface().height - 1
        }
    } catch {
        throw Failure(description: "Long note surface \(fixture.state.capsuleFrame), available \(availableNoteSurface()), host \(host.bounds)")
    }
    try await settle()
    try checkExpandedSurface(above: narrowCollapsed, label: "long-note-narrow-window")
    guard let scroll = find(host, NSScrollView.self, where: {
        ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 10
    }), let document = scroll.documentView else {
        throw Failure(description: "Long note did not expose a native scrolling viewport")
    }
    try await capture("long-note-narrow-before-scroll")
    try await Task.sleep(for: .milliseconds(2_300))
    try require(!fixture.exposureAttempts.contains("long-note-fixture:1"),
                "Long note first screen was mistaken for complete coverage")
    // AppKit reserves extra outer width for the overlay scroller; the clip
    // view is the visible reading viewport that must fit inside Moku.
    let nativeScrollFrame = scroll.contentView.convert(scroll.contentView.bounds, to: host)
    let scrollFrame = host.isFlipped ? nativeScrollFrame : CGRect(
        x: nativeScrollFrame.minX, y: host.bounds.height - nativeScrollFrame.maxY,
        width: nativeScrollFrame.width, height: nativeScrollFrame.height)
    let longSurface = fixture.state.capsuleFrame
    try require(longSurface.contains(scrollFrame) &&
                abs(longSurface.maxY - scrollFrame.maxY - narrowCollapsed.height) < 1,
                "The note scrolling viewport did not fit above Moku's retained bottom row: \(scrollFrame), surface \(longSurface)")
    scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.bounds.maxY - scroll.contentView.bounds.height)))
    scroll.reflectScrolledClipView(scroll.contentView)
    try require(scroll.contentView.bounds.minY > 0, "Long note could not scroll to its final milestone")
    try await capture("long-note-narrow-scrolled")
    try await Task.sleep(for: .milliseconds(2_300))
    try require(!fixture.exposureAttempts.contains("long-note-fixture:1"),
                "Jumping over the long note's middle was mistaken for coverage")

    // Traverse overlapping viewports through the real clip view. The tracker
    // must observe each settled range, rather than infer a path from offsets.
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .milliseconds(100))
    window.makeKeyAndOrderFront(nil)
    try await wait("Long note lost foreground/key eligibility; inspect permission/focus diagnostics before retrying") {
        NSApp.isActive && window.isKeyWindow
    }
    try await click(CGPoint(x: scrollFrame.midX, y: scrollFrame.midY))
    let step = max(1, scroll.contentView.bounds.height * 0.75)
    let bottom = max(0, document.bounds.maxY - scroll.contentView.bounds.height)
    var offset: CGFloat = 0
    while true {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(2_150))
        if offset >= bottom { break }
        offset = min(bottom, offset + step)
    }
    try await wait("Settled complete long-note coverage did not emit exposure") {
        fixture.exposureAttempts.contains("long-note-fixture:1")
    }

    fixture.state.setNotePanelOpen(false)
    fixture.usesOverrideNote = false
    window.setContentSize(NSSize(width: 900, height: 620))
    fixture.scheme = .light; window.appearance = NSAppearance(named: .aqua)
    try await settle()

    // The empty clear is a real empty state, not stale content.
    try fixture.install(records[2])
    try await wait("Cleared note was not published") { fixture.presentation.note == nil }
    fixture.state.setNotePanelOpen(true)
    try await wait("Empty panel did not open") { fixture.state.notePanelOpen }
    try await settle()
    try checkExpandedSurface(above: collapsed, label: "empty-note-open")
    let emptyShot = try await capture("light-note-empty")
    let emptyText = try recognizedText(emptyShot)
    try require(emptyText.contains("Moku") && emptyText.contains("还没有"), "Empty state or panel title is missing: \(emptyText)")

    fixture.state.setNotePanelOpen(false)

    let report: [String: Any] = ["source": data["source"]?.stringValue ?? "unknown",
        "measurements": measurements,
        "checks": ["real Coordinator update_note records → catalog snapshot/patch → WorkspacePresentation → production Dock",
            "Moku's single surface grows within the window and shrinks back at its original bottom anchor; no new AppKit window",
            "Markdown body remains read-only and selectable inside the expanded surface",
            "opening and in-place updates retain unexposed state until Runtime accepts a full-coverage receipt",
            "composer and permission/question panels take priority",
            "voice upward swipe, retained transcript scroll, control exclusion/clicks, close paths and draft/focus restoration",
            "empty voice note fits a narrow viewport; idle-origin voice termination preserves the note without opening input",
            "Escape, outside click and the title close control dismiss; inside click keeps the panel",
            "rapid open/close redirects and composer interruptions settle to the requested size",
            "contract-sized long note wraps and scrolls natively in a narrow window",
            "long-note first screen and middle gap stay unknown; overlapping settled viewports complete coverage",
            "clear shows the empty state; light and dark appearances"],
        "limits": "Voice functional checks disable animations to avoid inactive-app presentation pauses. Voice mode/transcript and button actions are presentation fixtures; media/session continuity is source-reviewed, not a live capture/playback test. Mock Harness and isolated profile; long note is a UI-only fixture within the production 1200-code-point contract; screenshots sample expansion/contraction and settled endpoints; hover reveal and full frame-by-frame continuity are source-reviewed (no physical pointer or video capture); Reduce Motion is source-reviewed (the SwiftUI system environment value is read-only; user preferences were not changed); no live provider, microphone or user runtime started"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("report.json"))
    await fixture.draft.dispose()
}

/// The Go replay starts an authenticated temporary Runtime with a real Moku
/// note. This path mounts the production Dock, lets its renderer and viewport
/// tracker finish, and sends through the same RuntimeClient path as the shell.
@MainActor private func replayExposure() async throws {
    guard CommandLine.arguments.count >= 4 else { throw Failure(description: "Expected Runtime profile and evidence directory") }
    let profile = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let evidence = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    let fixture = try Fixture(directory: profile)
    let started = ProcessInfo.processInfo.systemUptime
    func trace(_ message: String) {
        print("EXPOSURE \(ProcessInfo.processInfo.systemUptime - started): \(message)")
    }
    fixture.state.submitNoteExposure = { [weak fixture] id, revision in
        guard let fixture else { throw CancellationError() }
        trace("submit \(id) revision=\(revision)")
        do {
            let status = try await NativeMokuNoteExposureSender.submit(workspace: fixture.workspace, id: id,
                                                                     revision: revision)
            trace("submit returned \(status)")
            return status
        } catch {
            trace("submit failed: \(error)")
            throw error
        }
    }
    fixture.workspace.onCatalogChange = { [weak fixture] event in
        guard let fixture else { return }
        fixture.overview.receive(event)
        fixture.presentation.receive(event)
        fixture.state.reconcileNoteExposure(fixture.presentation.note)
        trace("catalog revision=\(String(describing: fixture.presentation.note?.revision)) exposure=\(String(describing: fixture.presentation.note?.lastExposureRevision))")
    }
    fixture.workspace.onConnectionChange = { [weak fixture] status in
        if status == .connected { fixture?.state.retryNoteExposure() }
    }
    fixture.workspace.start()
    try await wait("Authenticated Runtime did not publish the note") {
        fixture.workspace.connection == .connected && fixture.presentation.note != nil
    }
    let note = try unwrap(fixture.presentation.note, "Missing note projection")
    try require(note.hasUnexposedUpdate, "Go fixture note was already exposed")

    let host = NSHostingView(rootView: Scene(fixture: fixture))
    let window = NSWindow(contentRect: CGRect(x: 160, y: 120, width: 900, height: 620),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Production note exposure replay"
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    try await wait("Note window did not become qualified") {
        fixture.state.windowVisible && window.isKeyWindow && NSApp.isActive
    }
    fixture.state.openNotePanelFromUser()
    try await wait("Note panel did not render the current document") {
        fixture.state.notePanelOpen && fixture.state.capsuleFrame.height > 100
    }
    try require(fixture.state.noteUnread(note), "Opening optimistically acknowledged the note")
    do {
        try await wait("Production tracker/Runtime did not publish exact exposure") {
            fixture.presentation.note?.lastExposureRevision == note.revision
        }
    } catch {
        trace("active=\(NSApp.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) panel=\(fixture.state.notePanelOpen) capsule=\(fixture.state.capsuleFrame)")
        trace(viewTree(host))
        // Inspect the actual mounted probe only after failure. No instrumentation
        // changes its arming, geometry, dwell or authenticated submission path.
        if let probe = find(host, NSView.self, where: { String(describing: type(of: $0)) == "ExposureView" }) {
            for member in Mirror(reflecting: probe).children {
                trace("probe \(member.label ?? "?")=\(String(describing: member.value))")
                if let tracker = member.value as? NativeMokuNoteExposureTracker {
                    for state in Mirror(reflecting: tracker).children {
                        trace("tracker \(state.label ?? "?")=\(String(describing: state.value))")
                    }
                }
            }
        }
        throw error
    }
    let current = try unwrap(fixture.workspace.catalog.moku?.note, "Runtime note missing after receipt")
    try require(current.lastExposure?.revision == note.revision && current.lastExposure?.text == JSONText(note.text),
                "Receipt did not retain the exact rendered revision and text")
    try JSONSerialization.data(withJSONObject: ["noteId": note.id.string, "revision": note.revision,
        "readingRevision": current.readingRevision, "signal": current.lastExposure?.signal.string ?? ""],
        options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("exposure.json"))
    await fixture.draft.dispose()
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var failure: String?
            do {
                if CommandLine.arguments.dropFirst().first == "--exposure-connection" { try await replayExposure() }
                else { try await replay() }
            } catch { failure = String(describing: error) }
            let result: [String: Any] = ["ok": failure == nil, "message": failure ?? "production note native replay"]
            let path = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.json")
            try! JSONSerialization.data(withJSONObject: result).write(to: path)
            print(failure.map { "FAIL: \($0)" } ?? "PASS production note native replay")
            exit(failure == nil ? 0 : 1)
        }
    }
}
@main private enum Main {
    static func main() {
        do { try prepareIsolatedNativeReplay() }
        catch { print("FAIL replay isolation: \(error)"); exit(1) }
        if CommandLine.arguments.contains("--isolation-only") {
            let path = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.json")
            try! JSONSerialization.data(withJSONObject: ["ok": true, "message": "isolated paths and packaged resources"])
                .write(to: path)
            return
        }
        let delegate = Delegate(), app = NSApplication.shared
        app.setActivationPolicy(.regular); app.delegate = delegate
        app.run()
    }
}
