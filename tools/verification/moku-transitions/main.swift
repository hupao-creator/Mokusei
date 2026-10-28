import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiPluginUI
@testable import MokuseiUI

private struct Failure: Error, CustomStringConvertible { let description: String }

@MainActor @Observable private final class Fixture {
    let state = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var mode = MokuCharacterMode.idle
    var running = false
    var landing = false
    var reasoning: MokuReasoningContent?
    var phase = ScenePhase.active
    var stage = "idle"
}

private struct Scene: View {
    let fixture: Fixture
    var body: some View {
        NativeMokuScene(state: fixture.state) {
            Color.white.overlay(alignment: .topLeading) {
                Text(fixture.stage).font(.system(size: 12)).foregroundStyle(.gray).padding(16)
            }
        } thread: { Color.white } dock: {
            NativeMokuDock(state: fixture.state, draft: fixture.draft, cwd: "/tmp",
                landing: fixture.landing, mode: fixture.mode, running: fixture.running, reasoning: fixture.reasoning,
                onSend: { _ in }, onCancel: { fixture.running = false; fixture.reasoning = nil; fixture.mode = .idle })
                .environment(\.scenePhase, fixture.phase)
        } settings: { Color.white }
        .environment(\.colorScheme, .light)
    }
}

@MainActor private func canvases(in view: NSView) -> [NativeMokuCharacterCanvas] {
    (view as? NativeMokuCharacterCanvas).map { [$0] } ?? view.subviews.flatMap { canvases(in: $0) }
}

@MainActor private func wait(_ name: String, _ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(description: "Timeout: " + name) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor private func replay(output: URL) async throws -> [String: Any] {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let fixture = Fixture()
    let host = NSHostingView(rootView: Scene(fixture: fixture))
    let window = NSWindow(contentRect: CGRect(x: 150, y: 150, width: 820, height: 480),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "Production Moku transition replay"
    window.level = .floating
    window.isReleasedWhenClosed = false; window.contentView = host
    window.makeKeyAndOrderFront(nil); NSApp.activate()
    defer { window.close() }
    try await wait("one mounted production face") { canvases(in: host).filter { $0.seat == .face }.count == 1 }
    let face = canvases(in: host).first { $0.seat == .face }!
    let controller = face.controller
    try await wait("native display link") { controller.hasScheduledFrame && controller.frameCount > 2 }
    var target: SCWindow?
    for _ in 0..<40 {
        target = try await SCShareableContent.currentProcess.windows.first {
            $0.windowID == CGWindowID(window.windowNumber)
                && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                && abs($0.frame.width - window.frame.width) < 1
                && abs($0.frame.height - window.frame.height) < 1
        }
        if target != nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    guard let target else { throw Failure(description: "Own full-size WindowServer window unavailable") }
    let filter = SCContentFilter(desktopIndependentWindow: target)
    var observations: [[String: Any]] = []
    defer {
        try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("frames.json"))
    }
    var screenshots = 0
    var lastPose = controller.pose
    var lastClock = controller.clock
    var greatestEyeStep = 0.0
    let eyeChannels = ["lx", "ly", "lw", "lh", "rx", "ry", "rw", "rh"]

    func sample(_ name: String) throws {
        let faces = canvases(in: host).filter { $0.seat == .face }
        guard faces.count == 1, faces[0] === face else { throw Failure(description: name + ": replaced or duplicated the eye seat") }
        let pose = controller.pose, dt = max(0, controller.clock - lastClock)
        guard pose.values.values.allSatisfy(\.isFinite) else { throw Failure(description: name + ": non-finite pose") }
        let step = eyeChannels.map { abs(pose[$0] - lastPose[$0]) * 0.22 }.max() ?? 0
        // A role redirect happens without advancing the display clock. Permit
        // ordinary between-frame motion, but reject a one-frame geometry jump.
        guard step <= 0.8 + dt * 0.15 else {
            throw Failure(description: "\(name): eye jump \(step)pt over \(dt)ms")
        }
        greatestEyeStep = max(greatestEyeStep, step)
        observations.append(["state": name, "clock": controller.clock, "eyeStep": step,
            "dt": dt, "transitioning": controller.isTransitioning,
            "faceFrame": NSStringFromRect(face.convert(face.bounds, to: nil)),
            "runningClock": controller.runningMilliseconds,
            "reasoning": controller.currentReasoning != nil, "arcAlpha": pose["arcAlpha"],
            "retiring": controller.isRetiringReasoning])
        lastPose = pose; lastClock = controller.clock
    }

    func capture(_ name: String) async throws {
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
        config.ignoreShadowsSingleWindow = true; config.scalesToFit = true; config.showsCursor = false
        config.capturesAudio = false; config.captureMicrophone = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent(String(format: "%03d-", screenshots) + name + ".png"))
        screenshots += 1
    }

    func observe(_ name: String, milliseconds: Int, images: Bool = true) async throws {
        fixture.stage = name
        let deadline = ProcessInfo.processInfo.systemUptime + Double(milliseconds) / 1000
        var frame = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            try sample(name)
            if images && frame % 5 == 0 { try await capture(name) }
            frame += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        try sample(name)
    }

    try await observe("idle", milliseconds: 100)
    let idleFace = face.convert(face.bounds, to: nil)
    let inputStart = observations.count
    fixture.state.setInputOpen(true)
    try await observe("idle-to-input-full", milliseconds: 750)
    let inputFace = face.convert(face.bounds, to: nil)
    guard idleFace.midX - inputFace.midX > 100 else {
        throw Failure(description: "Input did not move the mounted eye seat to the editor")
    }
    fixture.state.setInputOpen(false)
    try await observe("input-to-idle-full", milliseconds: 750)
    fixture.state.setInputOpen(true)
    try await observe("idle-to-input-reverse", milliseconds: 100)
    fixture.state.setInputOpen(false)
    try await observe("input-to-idle-reverse", milliseconds: 750)
    fixture.state.setInputOpen(true)
    try await observe("input-reopen-full", milliseconds: 750)
    fixture.state.setInputOpen(false)
    try await observe("input-collapse-reverse", milliseconds: 100)
    fixture.state.setInputOpen(true)
    try await observe("input-reverse-to-open", milliseconds: 750)
    fixture.state.setInputOpen(false)
    try await observe("input-final-close", milliseconds: 750)
    // The mounted seat must stay between its real resting positions. Shape-only
    // checks miss a parent-layout jump even when every eye pose is continuous.
    // One point permits native backing alignment, not a second vertical excursion.
    let left = min(idleFace.midX, inputFace.midX) - 1
    let right = max(idleFace.midX, inputFace.midX) + 1
    let bottom = min(idleFace.midY, inputFace.midY) - 1
    let top = max(idleFace.midY, inputFace.midY) + 1
    for frame in observations[inputStart...] {
        let rect = NSRectFromString(frame["faceFrame"] as! String)
        guard (left...right).contains(rect.midX), (bottom...top).contains(rect.midY) else {
            throw Failure(description: "\(frame["state"]!): eye seat escaped input trajectory: \(rect)")
        }
    }
    fixture.running = true; fixture.mode = .running
    try await observe("idle-to-running", milliseconds: 650)
    try await observe("running-orbit", milliseconds: 4300, images: false)
    let runningClock = controller.runningMilliseconds
    fixture.mode = .namedTool("read_file")
    try await observe("orbit-to-tool-interrupted", milliseconds: 100)
    fixture.mode = .running
    try await observe("reverse-to-running", milliseconds: 650)
    guard controller.runningMilliseconds > runningClock else { throw Failure(description: "Running clock restarted after interruption") }

    let source = "先读已有实现，确认文字方向，再沿圆弧顺滑推进。👩🏽‍💻 新的输入不会重启动作，角色也不会突然卡断。"
    fixture.reasoning = MokuReasoningContent(sourceText: source, segmentKey: "execution-a:reasoning-1")
    try await observe("running-to-thinking", milliseconds: 1200)
    try await wait("thinking handoff settled") { controller.currentReasoning != nil && !controller.isTransitioning }
    try sample("thinking-settled")
    let readingClock = controller.reasoningAnimation.clock
    fixture.reasoning = MokuReasoningContent(sourceText: source + " 同段继续追加。", segmentKey: "execution-a:reasoning-1")
    try await observe("thinking-append", milliseconds: 180)
    guard controller.reasoningAnimation.clock > readingClock, !controller.isTransitioning else {
        throw Failure(description: "Text append restarted its role or reader")
    }
    fixture.state.setInputOpen(true)
    try await observe("thinking-to-input", milliseconds: 100)
    fixture.state.setInputOpen(false)
    try await observe("reverse-input-to-thinking", milliseconds: 1400)

    for index in 0..<12 {
        if index % 3 == 0 { fixture.reasoning = nil; fixture.mode = .running }
        else if index % 3 == 1 { fixture.mode = .namedTool("read_file") }
        else { fixture.reasoning = MokuReasoningContent(sourceText: source, segmentKey: "execution-a:reasoning-1") }
        try await observe("rapid-\(index)", milliseconds: 65, images: index % 3 == 0)
    }
    fixture.reasoning = MokuReasoningContent(sourceText: source, segmentKey: "execution-a:reasoning-1")
    try await observe("rapid-settled-thinking", milliseconds: 1200)
    fixture.phase = .inactive
    try await wait("paused display link") { !controller.hasScheduledFrame }
    let paused = controller.clock
    try await Task.sleep(for: .milliseconds(250))
    guard controller.clock == paused else { throw Failure(description: "Inactive scene advanced a role clock") }
    fixture.phase = .active
    try await observe("resume-current-pose", milliseconds: 250)

    for landing in [false, true] {
        fixture.landing = landing
        window.setContentSize(CGSize(width: 820, height: 480))
        try await observe(landing ? "landing-thinking" : "bottom-thinking", milliseconds: 900)
        if landing {
            guard !fixture.state.inputOpen, fixture.state.capsuleFrame.width > 168,
                  abs(fixture.state.capsuleFrame.midY - host.bounds.midY) < 1 else {
                throw Failure(description: "Landing did not retain its enlarged centered thinking resident")
            }
            fixture.state.setInputOpen(true)
            try await observe("landing-thinking-to-input", milliseconds: 900)
            fixture.state.setInputOpen(false)
            try await observe("landing-input-to-thinking", milliseconds: 1400)
        }
        for size in [CGSize(width: 300, height: 190), CGSize(width: 180, height: 140)] {
            window.setContentSize(size)
            try await observe("fit-\(Int(size.width))-\(Int(size.height))", milliseconds: 900)
            let surface = fixture.state.capsuleFrame
            let bodySize = controller.input!.capsuleSize
            let scale = surface.width / bodySize.width
            let bounds = NativeMokuReasoningArcTrack(body: CGRect(origin: .zero, size: bodySize))
                .inkBounds(for: controller.paintedReasoningGlyphs)
            let actual = CGRect(x: surface.midX + (bounds.minX - bodySize.width / 2) * scale,
                y: surface.midY + (bounds.minY - bodySize.height / 2) * scale,
                width: bounds.width * scale, height: bounds.height * scale)
            let viewport = CGRect(origin: .zero, size: host.bounds.size).insetBy(dx: -0.5, dy: -0.5)
            guard viewport.contains(actual) else { throw Failure(description: "Arc glyphs clipped in \(size): \(actual) outside \(viewport)") }
        }
    }
    fixture.landing = false
    window.setContentSize(CGSize(width: 820, height: 480))
    fixture.reasoning = nil; fixture.running = false; fixture.mode = .idle
    try await observe("thinking-to-idle-and-landing", milliseconds: 1300)
    guard controller.currentReasoning == nil, !controller.isRetiringReasoning,
          controller.pose["arcAlpha"] < 0.001 else { throw Failure(description: "Expired reasoning survived its handoff") }
    try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("frames.json"))
    return ["samples": observations.count, "screenshots": screenshots, "maximumEyeStep": greatestEyeStep,
            "nativeFrames": controller.frameCount,
            "checks": ["single persistent eye seat", "input screen-space trajectory", "bounded inter-frame eye motion", "running clock continuation",
                       "append does not redirect", "rapid reversal", "inactive pause", "bottom/landing narrow/short arc fit", "centered enlarged thinking and input handoff", "retired glyph cleanup"]]
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let root = Bundle.main.bundleURL.deletingLastPathComponent()
            var result: [String: Any]
            do {
                let evidence = try await replay(output: URL(fileURLWithPath: CommandLine.arguments[1]))
                result = ["ok": true, "message": "continuous production Moku transitions", "evidence": evidence]
            } catch { result = ["ok": false, "message": String(describing: error)] }
            try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("result.json"))
            NSApp.terminate(nil)
        }
    }
}

@main private struct Replay {
    @MainActor static func main() throws {
        try prepareIsolatedNativeReplay()
        NativeTypography.registerFonts()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
