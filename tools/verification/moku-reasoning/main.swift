import AppKit
import Observation
@testable import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiHarnessCodex
@testable import MokuseiUI
import ScreenCaptureKit
import SwiftUI

private struct Failure: Error, CustomStringConvertible { var description: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}

// Existing RuntimeClient event seam, only in this separately linked verifier.
// No daemon/profile is opened. All catalog/harness/presentation consumers below
// are production implementations; the incoming protocol records are fixtures.
extension RuntimeClient {
    fileprivate func seedReasoningFixture(_ snapshot: JSONValue) throws {
        try RuntimeState.validateSnapshot(snapshot)
        state = snapshot; setStatus(.connected)
    }
    fileprivate func sendReasoningFixture(_ thread: HarnessThread, activities: [JSONValue] = []) throws {
        let previous = state!
        let mutation: JSONValue = .object([
            "type": .text("state-patched"), "baseRevision": previous["revision"]!,
            "revision": .integer(previous["revision"]!.intValue! + 1),
            "threads": .object(["upserts": .array([thread.json]), "removedIds": .array([])]),
            "activities": .array(activities)
        ])
        let next = try RuntimeState.applying(mutation, to: previous)
        state = next; emit(.mutation(mutation, state: next, authority: stateAuthority))
    }
    fileprivate func fixtureAvailability(_ status: RuntimeConnectionStatus) { setStatus(status) }
}

@MainActor @Observable private final class Fixture {
    let client: RuntimeClient
    let workspace: NativeWorkspaceModel
    let presentation: NativeMokuWorkspacePresentation
    let scene = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var dark = false
    var mounted = true
    var voice = false
    var phase = ScenePhase.active
    var revision = 0
    var talkAudit: [JSONValue] = []
    init(directory: URL) throws {
        let profile = try RuntimeProfile(dataDirectory: directory, homeDirectory: directory)
        client = RuntimeClient(profile: profile)
        workspace = NativeWorkspaceModel(client: client, preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [], applications: []))
        let overview = NativeOverviewWorkspaceModel(workspace: workspace,
            applications: .init(projectionCapabilities: { _, _ in throw CancellationError() },
                                rendererContext: { _, _, _ in throw CancellationError() }))
        presentation = NativeMokuWorkspacePresentation(workspace: workspace, overview: overview)
        workspace.onCatalogChange = { [weak overview, weak presentation] event in
            overview?.receive(event); presentation?.receive(event)
        }
        workspace.onConnectionChange = { [weak overview, weak presentation] status in
            overview?.receive(.connection(status)); presentation?.receive(.connection(status))
        }
    }
    func record(text: String?, execution: String = "e1", status: PublicExecution.Status = .running,
                sequence: Int = 1, offset: Int = 0, kind: String = "reasoning") throws -> HarnessThread {
        revision += 1
        var turn: [JSONText: JSONValue] = [
            "executionId": .text(execution), "createdAt": .number(1), "updatedAt": .number(Double(revision + 2)),
            "status": .text(status == .waitingForUser ? "waiting-input" : status.rawValue),
            "answer": .text(""), "reasoning": .text(text ?? ""), "plan": .array([]), "notices": .array([]),
            "messages": .array([]), "timeline": .array([]), "activities": .array([]), "interactions": .array([])
        ]
        if let text {
            var foreground: [JSONText: JSONValue] = ["kind": .text(kind), "sequence": .integer(sequence)]
            if kind == "reasoning" { foreground["text"] = .text(text); foreground["textOffset"] = .integer(offset) }
            if kind == "tool-call" { foreground["toolName"] = .text("read_file"); foreground["callId"] = .text("call") }
            turn["foreground"] = .object(foreground)
        }
        if status != .running && status != .waitingForUser { turn["finishedAt"] = .number(Double(revision + 2)) }
        let state: JSONValue = .object([
            "schema": .text("mokusei.harness.codex.thread.v1"), "updatedAt": .number(Double(revision + 2)),
            "turns": .array([.object(turn)]), "backgroundTerminals": .array([])
        ])
        return try HarnessThread(id: "moku-reasoning-fixture", harnessID: "codex", revision: revision,
            sessionState: state, observation: .init(latestExecution: try PublicExecution(executionID: JSONText(execution),
                status: status, startedAt: 1, finishedAt: status == .running || status == .waitingForUser ? nil : Double(revision + 2),
                interactions: status == .waitingForUser ? [.init(id: "permission", kind: .permission, title: "Allow?",
                    actions: [.init(id: "allow", intent: .allow, label: "Allow")], questions: [])] : [])),
            cwd: "/tmp", settings: .object([:]), createdAt: 1, updatedAt: Double(revision + 2), title: "Moku",
            tags: [], moku: true, transcript: .array(talkAudit))
    }
    func send(text: String?, execution: String = "e1", status: PublicExecution.Status = .running,
              sequence: Int = 1, offset: Int = 0, kind: String = "reasoning") async throws {
        let thread = try record(text: text, execution: execution, status: status, sequence: sequence, offset: offset, kind: kind)
        try await client.sendReasoningFixture(thread)
        try await wait("installed catalog revision") { self.workspace.catalog.moku?.revision == thread.revision }
        try require(presentation.error == nil, "Production Codex projection failed: \(presentation.error ?? "")")
    }
}
private struct Scene: View {
    let fixture: Fixture
    var body: some View {
        NativeMokuScene(state: fixture.scene) { Color.clear } thread: { Color.clear } dock: {
            if fixture.mounted {
                NativeMokuDock(state: fixture.scene, draft: fixture.draft, cwd: "/tmp",
                    mode: fixture.presentation.dockMode, running: fixture.presentation.running,
                    interaction: fixture.presentation.interaction,
                    interactionIsQuestion: fixture.presentation.interactionIsQuestion,
                    voiceControls: AnyView(Text("Voice")), voiceStatusVisible: fixture.voice, voiceModeActive: fixture.voice,
                    presentation: fixture.presentation, note: .init(id: "note", text: "A fixture note for Arc ownership.", revision: 1, updatedAt: 1), onSend: { _ in }, onCancel: {})
            }
        } settings: { Color.clear }
        .background(fixture.dark ? Color(red: 0.09, green: 0.10, blue: 0.088) : Color(red: 0.962, green: 0.958, blue: 0.938))
        .environment(\.colorScheme, fixture.dark ? .dark : .light)
        .environment(\.scenePhase, fixture.phase)
    }
}
@MainActor private func wait(_ message: String, _ condition: () -> Bool) async throws {
    let until = ProcessInfo.processInfo.systemUptime + 6
    while !condition() {
        if ProcessInfo.processInfo.systemUptime > until { throw Failure(description: "Timeout: " + message) }
        try await Task.sleep(for: .milliseconds(20))
    }
}
@MainActor private func canvas(_ view: NSView) -> NativeMokuCharacterCanvas? {
    if let view = view as? NativeMokuCharacterCanvas, view.seat == .decorations { return view }
    return view.subviews.lazy.compactMap { canvas($0) }.first
}
@MainActor private func eye(_ view: NSView) -> NativeMokuCharacterCanvas? {
    if let view = view as? NativeMokuCharacterCanvas, view.seat == .face { return view }
    return view.subviews.lazy.compactMap { eye($0) }.first
}
private func png(_ image: CGImage, _ url: URL) throws {
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}
private func loadingPixels(_ image: CGImage) -> [UInt8] {
    let count = image.width * image.height * 4
    var pixels = [UInt8](repeating: 0, count: count)
    pixels.withUnsafeMutableBytes { buffer in
        let cg = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    // Isolate the saturated running dots from glass, eyes and shadows.
    return stride(from: 0, to: count, by: 4).map { index in
        let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
        return max(r, g, b) - min(r, g, b) > 45 && pixels[index + 3] > 240 ? 1 : 0
    }
}

// A reported full-size SCWindow can still be transformed by Stage Manager.
// Verify actual alpha coverage before using any pixels as rendering evidence.
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
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = try Fixture(directory: directory.appendingPathComponent("isolated-fixture"))
    let seed = try fixture.record(text: nil)
    try await fixture.client.seedReasoningFixture(.object([
        "revision": .integer(0), "settingsRevision": .integer(0), "defaultCwd": .text("/tmp"),
        "settings": .object([:]), "threads": .array([seed.json]), "executions": .array([]), "applicationThreads": .array([])
    ]))
    fixture.workspace.start()
    try await wait("production workspace connected") { fixture.workspace.runtimeAvailable && fixture.workspace.catalog.moku != nil }
    let host = NSHostingView(rootView: Scene(fixture: fixture))
    let window = NSWindow(contentRect: CGRect(x: 180, y: 180, width: 900, height: 520),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.level = .floating // Keep this auxiliary window out of Stage Manager thumbnail transforms.
    window.title = "Production Moku Thinking Loading — isolated fixture"
    window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    defer { window.close() }
    try await wait("mounted production contour") { canvas(host) != nil && fixture.scene.windowVisible }
    try require(fixture.presentation.reasoning == nil && canvas(host)?.controller.currentReasoning == nil, "No-reasoning run displayed old text")
    var text = "先读已有实现，确认文字方向和阅读节奏。接着沿开口圆弧展开，让新的思路顺着文字推进。原生生产组件正在接收真实的公开活动数据结构。"
    try await fixture.send(text: text)
    try await wait("live reasoning uses loading") { canvas(host)?.controller.input?.running == true && fixture.presentation.reasoning?.sourceText == text }
    let controller = canvas(host)!.controller
    let residentEye = eye(host)
    try require(residentEye != nil, "Production eyes missing")
    func noTrace() throws {
        try require(controller.currentReasoning == nil && controller.paintedReasoningGlyphs.isEmpty
            && controller.pose["arcAlpha"] == 0, "Moku exposed reasoning text")
    }
    try noTrace()
    if CommandLine.arguments.contains("--negative-control") { fixture.phase = .inactive }
    try await Task.sleep(for: .milliseconds(650))
    var target: SCWindow?
    for _ in 0..<40 {
        target = try await SCShareableContent.currentProcess.windows.first {
            $0.windowID == CGWindowID(window.windowNumber) &&
                abs($0.frame.width - window.frame.width) < 1 && abs($0.frame.height - window.frame.height) < 1
        }
        if target != nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    guard let target else { throw Failure(description: "Own full-size production fixture window is not capturable") }
    let filter = SCContentFilter(desktopIndependentWindow: target)
    let config = SCStreamConfiguration(); config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
    config.ignoreShadowsSingleWindow = true; config.scalesToFit = true; config.showsCursor = false
    config.capturesAudio = false; config.captureMicrophone = false; config.colorSpaceName = CGColorSpace.sRGB
    func presentedImage() async throws -> CGImage {
        var rejected: CGImage?
        for _ in 0..<40 {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if coversFullWindow(image) { return image }
            rejected = image
            try await Task.sleep(for: .milliseconds(75))
        }
        if let rejected { try png(rejected, directory.appendingPathComponent("invalid-window.png")) }
        throw Failure(description: "Refusing transformed/thumbnail WindowServer evidence")
    }
    func capture(_ name: String) async throws -> [UInt8] {
        let image = try await presentedImage()
        try png(image, directory.appendingPathComponent(name + ".png"))
        guard let view = canvas(host) else { throw Failure(description: "Missing decorations canvas") }
        let frame = view.convert(view.bounds, to: nil)
        let sx = Double(image.width) / window.frame.width, sy = Double(image.height) / window.frame.height
        let rect = CGRect(x: frame.minX * sx, y: (window.frame.height - frame.maxY) * sy,
                          width: frame.width * sx, height: frame.height * sy).integral
        guard let crop = image.cropping(to: rect) else { throw Failure(description: "Missing loading crop") }
        return loadingPixels(crop)
    }
    let first = try await capture("01-loading-light-a")
    try await Task.sleep(for: .milliseconds(240))
    let second = try await capture("02-loading-light-b")
    let count = second.reduce(0) { $0 + Int($1) }
    try require(count > 15 && first != second, "no naturally changing loading pixels; ink=\(count)")
    try require((0..<3).allSatisfy { controller.pose["d\($0)a"] > 0 && controller.pose["d\($0)radius"] == 2.5 },
        "Loading did not paint all three production dots")
    let originalKey = fixture.presentation.reasoning!.segmentKey
    let clock = controller.runningMilliseconds
    text += " 新内容仍保留在底层。"
    try await fixture.send(text: text)
    try await wait("append reaches projection") { fixture.presentation.reasoning?.sourceText == text }
    try await Task.sleep(for: .milliseconds(100))
    try require(fixture.presentation.reasoning?.segmentKey == originalKey && controller.runningMilliseconds > clock,
        "Reasoning append restarted loading or lost source identity")
    try noTrace()
    try await fixture.send(text: "窗口尾部继续", sequence: 2, offset: 800)
    try require(fixture.presentation.reasoning?.sourceOffset == 800, "Source offset was lost")
    try noTrace()
    fixture.dark = true
    try await Task.sleep(for: .milliseconds(250))
    _ = try await capture("03-loading-dark")
    // The live foreground must override an old generic tool role immediately.
    try await fixture.send(text: "tool", sequence: 3, kind: "tool-call")
    try await wait("tool owns expression") { controller.input?.running == false }
    try await fixture.send(text: "deep thinking", sequence: 4)
    try await wait("reasoning takes loading from queued tool") { controller.input?.running == true }
    try noTrace()
    fixture.scene.setInputOpen(true)
    try await wait("input covers loading") { controller.input?.running == false }
    fixture.scene.setInputOpen(false)
    try await wait("input releases loading") { controller.input?.running == true }
    fixture.scene.setNotePanelOpen(true)
    try await wait("note covers loading") { controller.input?.running == false }
    fixture.scene.setNotePanelOpen(false)
    try await wait("note releases loading") { controller.input?.running == true }
    fixture.voice = true
    try await wait("voice covers loading") { controller.input?.running == false }
    fixture.voice = false
    try await wait("voice releases loading") { controller.input?.running == true }
    await fixture.client.fixtureAvailability(.disconnected)
    try await wait("disconnect retires loading") { controller.input?.running == false && fixture.presentation.reasoning == nil }
    await fixture.client.fixtureAvailability(.connected)
    try await wait("reconnect restores current loading") { controller.input?.running == true }
    try noTrace()
    for (index, status) in [PublicExecution.Status.completed, .failed, .interrupted, .waitingForUser].enumerated() {
        let execution = "terminal-\(index)"
        try await fixture.send(text: "thinking", execution: execution)
        try await wait("execution starts loading") { controller.input?.running == true }
        try await fixture.send(text: "stale terminal reasoning", execution: execution, status: status)
        try await wait("terminal stops loading") { controller.input?.running == false && fixture.presentation.reasoning == nil }
        do {
            try await wait("dots retire") { !controller.isTransitioning }
        } catch {
            throw Failure(description: "\(error); status=\(status), clock=\(controller.clock), scheduled=\(controller.hasScheduledFrame), canvasVisible=\(canvas(host)?.motionVisible == true), eyeVisible=\(eye(host)?.motionVisible == true), sameController=\(canvas(host)?.controller === controller), frame=\(canvas(host)?.frame ?? .zero), windowVisible=\(window.occlusionState.contains(.visible))")
        }
        try require((0..<3).allSatisfy { controller.pose["d\($0)a"] < 0.001 }, "Terminal left loading dots")
        try noTrace()
    }
    // Terminal intent must reach the controller even while its display clock
    // is paused. Restoring visibility must schedule the existing handoff again.
    for hideWindow in [false, true] {
        let execution = hideWindow ? "hidden-terminal" : "inactive-terminal"
        try await fixture.send(text: "thinking before pause", execution: execution)
        try await wait("loading settles before pause") { controller.input?.running == true && !controller.isTransitioning }
        if hideWindow { window.orderOut(nil) } else { fixture.phase = .inactive }
        try await wait("display clock pauses") { !controller.hasScheduledFrame }
        try await fixture.send(text: "stale hidden reasoning", execution: execution, status: .completed)
        try await wait("paused terminal clears intent") { controller.input?.running == false && fixture.presentation.reasoning == nil }
        let pausedClock = controller.clock
        try await Task.sleep(for: .milliseconds(100))
        try require(controller.clock == pausedClock, "Hidden/inactive display clock advanced")
        if hideWindow { window.makeKeyAndOrderFront(nil) } else { fixture.phase = .active }
        try await wait("terminal handoff resumes") { controller.hasScheduledFrame && !controller.isTransitioning }
        try require(canvas(host)?.controller === controller && eye(host) === residentEye,
            "Pause/resume replaced the character host")
        try require((0..<3).allSatisfy { controller.pose["d\($0)a"] < 0.001 }, "Restored terminal left loading dots")
        try noTrace()
    }
    try await fixture.send(text: "thinking before reply", execution: "reply")
    try await wait("reply execution starts loading") { controller.input?.running == true }
    try await fixture.send(text: "answer", execution: "reply", sequence: 2, kind: "assistant-text")
    try require(fixture.presentation.reasoning == nil, "Assistant reply retained reasoning source")
    try await fixture.send(text: "answer", execution: "reply", status: .completed, sequence: 2, kind: "assistant-text")
    try await wait("completed reply stops loading") { controller.input?.running == false && !controller.isTransitioning }
    _ = try await capture("04-completed")
    try require(eye(host) === residentEye, "Loading replaced the persistent eye view")
    let result: [String: Any] = ["input": "Runtime fixtures through production workspace, Codex projection, presentation and Dock",
        "movingLoadingPixels": count, "reasoningTraceVisible": false,
        "lifecycle": "append, source offset, tool handoff, composer, note, voice, disconnect/reconnect, completed, failed, interrupted, waiting and reply completion",
        "pausedTerminalRetirement": ["inactive", "hidden"],
        "realModelRequest": false]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("measurements.json"))
    await fixture.draft.dispose(); fixture.presentation.stop(); await fixture.client.close()
}
@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var failure: String?
            do { try await replay() } catch { failure = String(describing: error) }
            let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.json")
            try! JSONSerialization.data(withJSONObject: ["ok": failure == nil, "message": failure ?? "production reasoning data path, three-dot loading and lifecycle"]).write(to: url)
            if let failure { print("FAIL \(failure)") }
            NSApp.terminate(nil)
        }
    }
}
@main struct Main {
    @MainActor static func main() throws {
        try prepareIsolatedNativeReplay()
        NativeTypography.registerFonts()
        let app = NSApplication.shared; let delegate = Delegate(); app.delegate = delegate
        app.setActivationPolicy(.regular); app.run(); withExtendedLifetime(delegate) {}
    }
}
