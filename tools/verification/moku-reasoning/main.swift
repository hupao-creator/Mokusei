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
        workspace.onCatalogChange = { [weak presentation] event in presentation?.receive(event) }
        workspace.onConnectionChange = { [weak presentation] status in presentation?.receive(.connection(status)) }
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
                    voiceBackground: AnyView(NativeVoiceCloud(level: 0.1, pitchHz: 220, confidence: 0.99,
                        capturedAt: ProcessInfo.processInfo.systemUptime, listening: true, motionEnabled: true)),
                    presentation: fixture.presentation, onSend: { _ in }, onCancel: {})
            }
        } settings: { Color.clear }
        .background(fixture.dark ? Color(red: 0.09, green: 0.10, blue: 0.088) : Color(red: 0.962, green: 0.958, blue: 0.938))
        .environment(\.colorScheme, fixture.dark ? .dark : .light)
    }
}
@MainActor private func wait(_ message: String, _ condition: () -> Bool) async throws {
    let until = ProcessInfo.processInfo.systemUptime + 6
    while !condition() {
        if ProcessInfo.processInfo.systemUptime > until { throw Failure(description: "Timeout: " + message) }
        try await Task.sleep(for: .milliseconds(20))
    }
}
@MainActor private func canvas(_ view: NSView) -> NativeMokuCapsuleReasoningCanvas? {
    if let view = view as? NativeMokuCapsuleReasoningCanvas { return view }
    return view.subviews.lazy.compactMap { canvas($0) }.first
}
@MainActor private func talk(_ view: NSView) -> NativeMokuTalkScrollView? {
    if let view = view as? NativeMokuTalkScrollView { return view }
    return view.subviews.lazy.compactMap { talk($0) }.first
}
@MainActor private func eye(_ view: NSView) -> NativeMokuCapsuleEyeCanvas? {
    if let view = view as? NativeMokuCapsuleEyeCanvas { return view }
    return view.subviews.lazy.compactMap { eye($0) }.first
}
private func png(_ image: CGImage, _ url: URL) throws {
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}
private func sagePixels(_ image: CGImage) -> [UInt8] {
    let count = image.width * image.height * 4
    var pixels = [UInt8](repeating: 0, count: count)
    pixels.withUnsafeMutableBytes { buffer in
        let cg = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    // Isolate the sage contour from glass, eyes, window and shadows.
    return stride(from: 0, to: count, by: 4).map { index in
        let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
        return g - r >= 6 && g - b >= 10 && r < 215 && pixels[index + 3] > 240 ? 1 : 0
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
    window.title = "Production Moku Reasoning integration — isolated fixture"
    window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    defer { window.close() }
    try await wait("mounted production contour") { canvas(host) != nil && fixture.scene.windowVisible }
    try require(fixture.presentation.reasoning == nil && canvas(host)?.animation.content == nil, "No-reasoning run displayed old text")
    let text = "先读已有实现，确认文字方向和阅读节奏。接着沿横条外轮廓展开，让新的思路顺着边缘流动。原生生产组件正在接收真实的公开活动数据结构。"
    try await fixture.send(text: text)
    try await wait("real Harness→presentation→Dock→canvas") { canvas(host)?.animation.content?.sourceText == text }
    try require(canvas(host)!.animation.content?.segmentKey == fixture.presentation.reasoning?.segmentKey,
        "Dock bypassed live production projection")
    try require(eye(host) != nil, "Production blinking eyes were replaced")
    try require(canvas(host)!.hasScheduledFrame, "Visible reasoning has no frame timer")
    if CommandLine.arguments.contains("--negative-control") { canvas(host)!.stop() }
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
        guard let view = canvas(host) else { throw Failure(description: "Missing production contour canvas") }
        let frame = view.convert(view.bounds, to: nil)
        let sx = Double(image.width) / window.frame.width, sy = Double(image.height) / window.frame.height
        let rect = CGRect(x: frame.minX * sx, y: (window.frame.height - frame.maxY) * sy,
                          width: frame.width * sx, height: frame.height * sy).integral
        guard let crop = image.cropping(to: rect) else { throw Failure(description: "Missing contour crop") }
        var mask = sagePixels(crop)
        // Exclude the body/rim too: the window's green zoom button and glass
        // reflection are not reasoning. Keep only the external letter region.
        let body = view.track.body.insetBy(dx: -8, dy: -8)
        for y in 0..<crop.height {
            for x in 0..<crop.width where body.contains(CGPoint(x: Double(x) / sx, y: Double(y) / sy)) {
                mask[y * crop.width + x] = 0
            }
        }
        return mask
    }
    let first = try await capture("01-stream-light-a")
    try await Task.sleep(for: .milliseconds(240))
    let second = try await capture("02-stream-light-b")
    let count = second.reduce(0) { $0 + Int($1) }
    try require(count > 80 && first != second, "no naturally changing reasoning pixels")
    let originalKey = fixture.presentation.reasoning!.segmentKey
    let originalClock = canvas(host)!.animation.clock
    try await fixture.send(text: text + "👩🏽‍💻 新的内容连续进入。")
    try await wait("stream append delivered") { canvas(host)?.animation.content?.sourceText?.hasSuffix("新的内容连续进入。") == true }
    try require(fixture.presentation.reasoning?.segmentKey == originalKey && canvas(host)!.animation.clock > originalClock,
        "Stream append reset execution reader")
    try await fixture.send(text: "窗口尾部继续", offset: 800)
    try await wait("UTF16 offset delivered") { canvas(host)?.animation.content?.sourceOffset == 800 }
    try await fixture.send(text: "", sequence: 2)
    try await wait("empty reasoning cleared") { canvas(host)?.animation.content == nil }
    try await fixture.send(text: "开始新的推理段", sequence: 3)
    try await wait("new sequence") { canvas(host)?.animation.content != nil }
    try require(fixture.presentation.reasoning?.segmentKey != originalKey, "Reasoning segment identity reused")
    try await fixture.send(text: "assistant", sequence: 4, kind: "assistant-text")
    try await wait("assistant role clears contour despite queued mode") { canvas(host)?.animation.content == nil }
    for status in [PublicExecution.Status.completed, .failed, .interrupted, .waitingForUser] {
        try await fixture.send(text: "terminal stale payload", status: status, sequence: 5)
        try await wait("terminal reasoning retired") { fixture.presentation.reasoning == nil && canvas(host)?.animation.content == nil }
    }
    try await fixture.send(text: nil, execution: "e2")
    try require(fixture.presentation.reasoning == nil, "New execution retained old reasoning")
    try await fixture.send(text: "第二次执行的思路，必须与前一次隔离。", execution: "e2")
    try await wait("replacement execution") { canvas(host)?.animation.content?.segmentKey.contains("e2") == true }
    try require(fixture.presentation.reasoning?.segmentKey != originalKey, "Execution change reused old reader")
    fixture.scene.setInputOpen(true)
    try await wait("composer suppresses contour") { canvas(host)?.animation.content == nil }
    // A real send seals the retiring editor snapshot until the next input opens.
    // That retained draft must not suppress the newly running execution's reader.
    fixture.scene.retainDraft(fixture.draft, seal: true)
    fixture.scene.setInputOpen(false)
    try require(fixture.scene.capsuleSealed, "Submission regression did not retain its sealed draft")
    try await wait("current reasoning restores after sealed composer submission") { canvas(host)?.animation.content != nil }
    fixture.scene.setSearchActive(true)
    try await wait("covered Dock clears contour") { canvas(host)?.animation.content == nil }
    try await fixture.send(text: nil, execution: "e3")
    fixture.scene.setSearchActive(false)
    try await Task.sleep(for: .milliseconds(150))
    try require(canvas(host)?.animation.content == nil, "Navigation restore resurrected expired reasoning")
    try await fixture.send(text: text, execution: "e3")
    try await wait("third execution ready") { canvas(host)?.animation.content != nil }
    fixture.dark = true
    NSApp.appearance = NSAppearance(named: .darkAqua)
    try await Task.sleep(for: .milliseconds(180))
    _ = try await capture("03-dark")
    // Exercise actual hide/show notifications. This replay does not attempt
    // programmatic miniaturization and makes no claim about that path.
    window.orderOut(nil)
    try await wait("hidden window timer stops") { canvas(host)?.hasScheduledFrame == false }
    window.makeKeyAndOrderFront(nil)
    try await wait("visible timer resumes") { canvas(host)?.hasScheduledFrame == true }
    await fixture.client.fixtureAvailability(.disconnected)
    try await wait("disconnect clears live reasoning") { fixture.presentation.reasoning == nil && canvas(host)?.animation.content == nil }
    await fixture.client.fixtureAvailability(.connected)
    try await wait("reconnected current content") { canvas(host)?.animation.content != nil }
    fixture.mounted = false
    try await wait("canvas removed") { canvas(host) == nil }
    fixture.mounted = true
    try await wait("new production canvas") { canvas(host)?.animation.content != nil }
    // Observe the real blink clock while reasoning frames and source updates run.
    var closedEye = false, reopenedEye = false, openEyeInk = 0
    let until = ProcessInfo.processInfo.systemUptime + 6
    while ProcessInfo.processInfo.systemUptime < until {
        if let eye = eye(host) {
            let image = try await presentedImage()
            let frame = eye.convert(eye.bounds, to: nil)
            let sx = Double(image.width) / window.frame.width, sy = Double(image.height) / window.frame.height
            let rect = CGRect(x: frame.minX * sx, y: (window.frame.height - frame.maxY) * sy,
                              width: frame.width * sx, height: frame.height * sy).integral
            guard let crop = image.cropping(to: rect) else { throw Failure(description: "Missing eye crop") }
            let bitmap = NSBitmapImageRep(cgImage: crop)
            let ink = (0..<bitmap.pixelsHigh).reduce(0) { total, y in total + (0..<bitmap.pixelsWide).reduce(0) { sum, x in
                let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                return sum + (min(c.redComponent, c.greenComponent, c.blueComponent) > 0.78 ? 1 : 0)
            } }
            openEyeInk = max(openEyeInk, ink)
            if openEyeInk > 40 && ink < openEyeInk / 3 {
                closedEye = true
                try png(image, directory.appendingPathComponent("07-natural-blink-closed.png"))
            }
            if closedEye && ink > openEyeInk * 4 / 5 {
                reopenedEye = true
                try png(image, directory.appendingPathComponent("08-natural-blink-reopened.png"))
                break
            }
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    try require(closedEye && reopenedEye, "Production eyes did not retain a natural blink with reasoning; maximum white ink=\(openEyeInk), closed=\(closedEye)")
    // Joint production surfaces: a real public talk audit owns the text seat,
    // while the native cloud and the same eye view remain mounted underneath.
    let residentEye = eye(host)
    fixture.talkAudit = [.object([
        "type": .text("tool-operation"), "name": .text("talk"), "id": .text("joint-talk"),
        "executionId": .text("e3"), "completedAt": .number(42),
        "arguments": .object(["text": .text("共同验证 Talk、光云与眨眼；reasoning 暂时让位。")]),
        "result": .object(["ok": .bool(true)])
    ])]
    try await fixture.send(text: text, execution: "e3")
    try await wait("talk takes priority over current reasoning") {
        fixture.scene.talkPresentation.presented && canvas(host)?.animation.content == nil
    }
    try await wait("joint talk reaches the production text view") {
        talk(host)?.messageView.string == "共同验证 Talk、光云与眨眼；reasoning 暂时让位。"
    }
    try await Task.sleep(for: .milliseconds(500))
    try require(fixture.presentation.reasoning != nil && eye(host) === residentEye
        && canvas(host)?.animation.content == nil && fixture.scene.capsuleFrame.width > 136,
        "Talk replaced the eye surface, lost priority or destroyed the live reasoning source")
    _ = try await capture("09-talk-cloud-priority")
    fixture.scene.dismissTalk()
    try await wait("current reasoning restores after talk") { canvas(host)?.animation.content != nil }
    try await Task.sleep(for: .milliseconds(500))
    try require(eye(host) === residentEye && talk(host) == nil, "Talk retirement replaced the eye clock or left old text")
    _ = try await capture("10-reasoning-cloud-restored")
    try await fixture.send(text: nil, execution: "e3", status: .completed)
    try await wait("final completion clears canvas and timer") { canvas(host)?.animation.content == nil && canvas(host)?.hasScheduledFrame == false }
    let completedPixels = try await capture("06-completed")
    let completedInk = completedPixels.reduce(0) { $0 + Int($1) }
    try require(completedInk < 5, "Completed execution left stale reasoning pixels: \(completedInk)")
    let result: [String: Any] = ["input": "RuntimeClient fixture events; production RuntimeState, workspace, Codex Harness, live presentation and Dock",
        "contourCapture": "own WindowServer window via ScreenCaptureKit; no forced contour drawing", "movingSagePixels": count, "completedSagePixels": completedInk,
        "lifecycle": "empty, append, UTF16 source offset, new segment, assistant, completed, failed, interrupted, waiting, execution replacement, sealed submission, search, disconnect, hide/show, remount and Talk/cloud priority",
        "blink": "natural close/reopen observed in own WindowServer window; no forced eye drawing", "realModelRequest": false, "minimize": "not exercised by this replay; real hide/show verified"]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("measurements.json"))
    await fixture.draft.dispose(); fixture.presentation.stop(); await fixture.client.close()
}
@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var failure: String?
            do { try await replay() } catch { failure = String(describing: error) }
            let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.json")
            try! JSONSerialization.data(withJSONObject: ["ok": failure == nil, "message": failure ?? "production reasoning data path, contour frames and lifecycle"]).write(to: url)
            if let failure { print("FAIL \(failure)") }
            NSApp.terminate(nil)
        }
    }
}
@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared; let delegate = Delegate(); app.delegate = delegate
        app.setActivationPolicy(.regular); app.run(); withExtendedLifetime(delegate) {}
    }
}
