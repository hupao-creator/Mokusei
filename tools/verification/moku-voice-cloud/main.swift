import AppKit
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
@testable import MokuseiVoice
@testable import MokuseiUI
@testable import MokuseiPluginUI

private struct ReplayFailure: Error, CustomStringConvertible { var description: String }
@MainActor private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ReplayFailure(description: message) }
}

// Hold the real client at preparation, before permission or media allocation.
// Cancellation resumes the obsolete request so no fixture task is left behind.
@MainActor private final class VoiceEntranceFixture {
    var pending: CheckedContinuation<NativeVoiceResult, any Error>?
    private(set) var prepares = 0
    lazy var client = NativeVoiceMediaClient(role: .moku, ownership: NativeVoiceMediaOwnership(),
        requestMicrophone: { throw ReplayFailure(description: "Entrance replay requested microphone") },
        command: { [unowned self] request in
            guard request["action"] == .text("prepare") else { return try NativeVoiceResult(.object([:])) }
            prepares += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        })
    func start() async throws -> Task<Void, Never> {
        client.setOwner("moku", available: true)
        let task = Task { await client.start() }
        for _ in 0..<100 {
            if pending != nil { return task }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ReplayFailure(description: "Voice preparation did not start")
    }
    func stop(_ task: Task<Void, Never>) async {
        await client.stop()
        pending?.resume(throwing: CancellationError()); pending = nil
        await task.value
    }
}

@MainActor private final class InputFixture: ObservableObject {
    @Published var signal = NativeVoiceInputAnalysis()
    @Published var visible = true
    @Published var paused = false
    @Published var muted = false
    @Published var entrance = false
    @Published var history = false
    let voice = VoiceEntranceFixture()
    var voiceActive: Bool { [.preparing, .connecting, .listening, .stopping].contains(voice.client.state.phase) }
    var motion = NativeVoiceCloudMotion()
    @Published var scheme: ColorScheme = .dark
    let analyser = NativeVoiceCaptureAnalyser()
    var sampleIndex = 0
    var hz = 160.0
    var amplitude = 0.003
    func tick() {
        guard visible else { motion.pause(); return }
        for _ in 0..<5 {
            let samples = (0..<480).map { i in Float(32768 * amplitude * sin(2 * Double.pi * hz * Double(sampleIndex + i) / 48_000)) }
            sampleIndex += 480
            samples.withUnsafeBufferPointer {
                analyser.consumeWebRTCPCM($0.baseAddress!, frames: $0.count, capturedAt: ProcessInfo.processInfo.systemUptime)
            }
        }
        signal = analyser.latest
        guard !paused else { motion.pause(); return }
        motion.advance(at: ProcessInfo.processInfo.systemUptime, level: signal.level,
            pitchHz: signal.pitchHz, confidence: signal.confidence, capturedAt: signal.capturedAt,
            listening: true, muted: muted)
    }
}

@MainActor private struct Surface: View {
    let state: NativeMokuSceneState
    let draft: NativeComposerDraft
    @ObservedObject var input: InputFixture
    private var background: AnyView {
        if input.entrance { return AnyView(NativeMokuVoiceCloud(client: input.voice.client, visible: true)) }
        return AnyView(NativeVoiceCloud(level: input.signal.level, pitchHz: input.signal.pitchHz,
            confidence: input.signal.confidence, capturedAt: input.signal.capturedAt,
            listening: true, muted: input.muted, visible: input.visible, motionEnabled: !input.paused))
    }
    private var controls: AnyView {
        input.entrance ? AnyView(NativeMokuVoiceControls(client: input.voice.client, style: .dock))
            : AnyView(Image(systemName: "mic").frame(width: 34, height: 34))
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            if input.history {
                NativeMokuHistoryComposer(draft: draft, cwd: "/tmp", focusEnabled: false,
                    activeVoiceControls: controls, voiceBackground: background, voiceModeActive: input.voiceActive,
                    onSend: { _ in }, onCancel: {})
                    .frame(width: 560).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 40)
            } else {
                NativeMokuScene(state: state) { Color.clear } thread: { Color.clear } dock: {
                    NativeMokuDock(state: state, draft: draft, cwd: "/tmp",
                        voiceControls: controls, voiceBackground: background,
                        voiceStatusVisible: !input.entrance || input.voiceActive,
                        voiceModeActive: input.entrance && input.voiceActive, onSend: { _ in }, onCancel: {})
                } settings: { Color.clear }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("生产 Moku 语音光云 · 合成 PCM 回放").font(.headline)
                Text("实际 NativeMokuDock / NativeVoiceCloud / CaptureAnalyser；没有麦克风、模型请求或用户 profile。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("PCM 基频 \(Int((input.signal.pitchHz ?? 0).rounded())) Hz").monospacedDigit()
                    Toggle("窗口可见", isOn: Binding(get: { input.visible }, set: { input.visible = $0 }))
                    Toggle("静态绘制", isOn: Binding(get: { input.paused }, set: { input.paused = $0 }))
                }.font(.caption)
            }.padding(24)
        }
        .background(NativePalette.overview.canvas.swiftUI)
        .environment(\.colorScheme, input.scheme)
    }
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let input = InputFixture(), state = NativeMokuSceneState()
            let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
            state.setInputOpen(true)
            input.analyser.audioProcessingInitialize(sampleRate: 48_000, channels: 1)
            input.analyser.setEnabled(true)
            let window = NSWindow(contentRect: CGRect(x: 120, y: 100, width: 900, height: 620),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Production Moku Voice Cloud · Synthetic PCM"
            window.isReleasedWhenClosed = false;window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: Surface(state: state, draft: draft, input: input))
            self.window = window;window.makeKeyAndOrderFront(nil);NSApp.activate()
            // Feed continuously while ScreenCaptureKit awaits captures, just as
            // production WebRTC continues publishing fresh analysis at 20 Hz.
            let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated { input.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            do {
                for _ in 0..<60 { input.tick();try await Task.sleep(for: .milliseconds(50)) }
                let quietSpeed = input.motion.speed
                try require(quietSpeed > 0.8 && input.signal.pitchHz == nil,
                    "Quiet PCM without reliable pitch must visibly flow")
                input.amplitude = 0.12
                for _ in 0..<60 { input.tick();try await Task.sleep(for: .milliseconds(50)) }
                let strongSpeed = input.motion.speed
                try require(strongSpeed > quietSpeed + 2 && input.motion.shape > 0.8,
                    "PCM amplitude did not drive flow and deformation")
                try require(abs((input.signal.pitchHz ?? 0) - 160) < 3, "Production PCM adapter failed")
                try require(state.capsuleFrame.width > 136, "Production composer did not mount")
                let fullWidth = state.capsuleFrame.width
                let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("evidence")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let content = try await SCShareableContent.currentProcess
                let target = try content.windows.first(where: {
                    $0.windowID == CGWindowID(window.windowNumber)
                        && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                        && abs($0.frame.width - window.frame.width) < 1
                        && abs($0.frame.height - window.frame.height) < 1
                }).unwrap("Full own window unavailable; refusing thumbnail evidence")
                let filter = SCContentFilter(desktopIndependentWindow: target)
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * 2);config.height = Int(window.frame.height * 2)
                config.ignoreShadowsSingleWindow = true;config.scalesToFit = true;config.showsCursor = false
                config.capturesAudio = false;config.captureMicrophone = false;config.colorSpaceName = CGColorSpace.sRGB
                @MainActor func sample(_ name: String, fullWindow: Bool = false) async throws -> CGImage {
                    // Stage Manager can return a transformed thumbnail padded
                    // to full dimensions. Reject its transparent wedge rather
                    // than counting desktop/window-transition pixels as cloud.
                    window.makeKeyAndOrderFront(nil);NSApp.activate()
                    var captured: CGImage?
                    for _ in 0..<30 {
                        try await Task.sleep(for: .milliseconds(100))
                        let candidate = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        let rgba = pixels(candidate)
                        let opaque = stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] >= 250 }.count
                        if Double(opaque) / Double(candidate.width * candidate.height) > 0.97 {
                            captured = candidate;break
                        }
                    }
                    let image = try captured.unwrap("WindowServer returned a transformed/transparent thumbnail, not full native content")
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
                    if fullWindow { return image }
                    let host = window.contentView!
                    var rect = state.capsuleFrame.insetBy(dx: 0, dy: 8)
                    rect.origin.x += 210;rect.size.width -= 270
                    if !host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
                    let inWindow = host.convert(rect, to: nil)
                    let sx = Double(image.width) / window.frame.width, sy = Double(image.height) / window.frame.height
                    let crop = CGRect(x: inWindow.minX * sx, y: (window.frame.height - inWindow.maxY) * sy,
                                      width: inWindow.width * sx, height: inWindow.height * sy).integral
                    return try image.cropping(to: crop).unwrap("Cloud sample crop unavailable")
                }
                let movingFirst = try await sample("moving-first")
                var movement = 0.0
                for index in 0..<5 {
                    for _ in 0..<8 { input.tick();try await Task.sleep(for: .milliseconds(50)) }
                    movement = max(movement, try pixelDelta(movingFirst, await sample("moving-\(index)")))
                }
                try require(movement > 1, "Production voice cloud did not visibly move in native window: \(movement)")
                input.paused = true
                try await Task.sleep(for: .milliseconds(350))
                let staticFirst = try await sample("static-first")
                try await Task.sleep(for: .milliseconds(450))
                let staticDelta = try pixelDelta(staticFirst, await sample("static-next"))
                try require(staticDelta < 0.2, "Static cloud moved: \(staticDelta)")
                input.paused = false
                input.scheme = .light;window.appearance = NSAppearance(named: .aqua)
                for _ in 0..<10 { input.tick();try await Task.sleep(for: .milliseconds(50)) }
                _ = try await sample("light-theme")
                input.scheme = .dark;window.appearance = NSAppearance(named: .darkAqua)
                try JSONSerialization.data(withJSONObject: ["capture": "ScreenCaptureKit current-process full native window",
                    "movingMeanRGBDelta": movement, "staticMeanRGBDelta": staticDelta,
                    "quietUnvoicedSpeed": quietSpeed, "strongSpeed": strongSpeed,
                    "source": "synthetic FloatS16 through production capture analyser; not live mic"],
                    options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("measurements.json"))
                input.amplitude = 0
                for _ in 0..<80 { input.tick();try await Task.sleep(for: .milliseconds(50)) }
                try require(input.motion.speed < 0.18 && input.motion.shape < 0.01,
                    "Silence did not release motion to idle")
                input.amplitude = 0.12;input.muted = true
                for _ in 0..<30 { input.tick();try await Task.sleep(for: .milliseconds(50)) }
                try require(input.motion.speed < 0.18, "Muted PCM drove motion")
                input.muted = false
                input.hz = 110
                for _ in 0..<35 { input.tick();try await Task.sleep(for: .milliseconds(50)) }
                try require(abs((input.signal.pitchHz ?? 0) - 110) < 2, "Pitch did not follow frequency change")
                input.analyser.setEnabled(false)
                input.visible = false
                try await Task.sleep(for: .milliseconds(150))
                try require(input.analyser.latest == .init(), "Hidden analyser retained audio")
                input.visible = true;input.analyser.setEnabled(true);input.hz = 570
                for _ in 0..<10 { input.tick();try await Task.sleep(for: .milliseconds(50)) }
                try require(abs((input.signal.pitchHz ?? 0) - 570) < 3, "Capture did not resume after hiding")
                state.setInputOpen(false)
                try await Task.sleep(for: .milliseconds(600))
                try require(state.capsuleFrame.width < fullWidth, "Collapse did not preserve live voice background")
                state.setInputOpen(true)
                try await Task.sleep(for: .milliseconds(600))
                input.entrance = true
                draft.text = "Keep this draft through voice cancellation"
                let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                for (history, openInput) in [(false, false), (false, true), (true, true)] {
                    input.history = history
                    if !history { state.setInputOpen(openInput) }
                    try await Task.sleep(for: .milliseconds(600))
                    let surface = history ? "history" : openInput ? "dock-expanded" : "dock-compact"
                    let prefix = "entrance-\(surface)-\(reduced ? "reduced" : "animated")"
                    _ = try await sample(prefix + "-before", fullWindow: true)
                    let prepares = input.voice.prepares
                    let start = try await input.voice.start()
                    _ = try await sample(prefix + "-entering", fullWindow: true)
                    try await Task.sleep(for: .milliseconds(500))
                    _ = try await sample(prefix + "-active", fullWindow: true)
                    try require(input.voice.client.state.phase == .preparing && input.voice.prepares == prepares + 1,
                        "Rendering restarted or ended voice preparation")
                    if !history { try require(!state.inputOpen, "Voice did not close Dock input") }
                    await input.voice.stop(start)
                    _ = try await sample(prefix + "-leaving", fullWindow: true)
                    try await Task.sleep(for: .milliseconds(500))
                    _ = try await sample(prefix + "-restored", fullWindow: true)
                    if !history { try require(state.inputOpen == openInput, "Cancelled voice did not restore Dock input") }
                    for _ in 0..<3 {
                        let quick = try await input.voice.start()
                        try await Task.sleep(for: .milliseconds(60))
                        await input.voice.stop(quick)
                    }
                    try await Task.sleep(for: .milliseconds(600))
                    try require(input.voice.client.state.phase == .closed && draft.text == "Keep this draft through voice cancellation",
                        "Rapid cancellation lost draft or left voice active")
                    if !history { try require(state.inputOpen == openInput, "Rapid cancellation lost composer restoration") }
                }
                if ProcessInfo.processInfo.environment["MOKU_VOICE_INSPECT"] == "1" {
                    for _ in 0..<600 { input.tick();try await Task.sleep(for: .milliseconds(50)) }
                }
                input.analyser.setEnabled(false);input.analyser.audioProcessingRelease()
                await draft.dispose();window.close()
                finish(nil)
            } catch { input.analyser.setEnabled(false);finish(error) }
        }
    }
    private func finish(_ error: Error?) -> Never {
        let report: [String: Any] = ["ok": error == nil, "message": error.map(String.init(describing:))
            ?? "production PCM, WindowServer motion/pause pixels, compact/expanded Dock and history voice entrance under current system motion preference, rapid preparation cancellation/draft restoration; no live mic"]
        let output = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        exit(error == nil ? 0 : 1)
    }
}
private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw ReplayFailure(description: message) };return self
    }
}
private func pixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}
private func pixelDelta(_ first: CGImage, _ next: CGImage) throws -> Double {
    guard first.width == next.width, first.height == next.height else { throw ReplayFailure(description: "Capture dimensions changed") }
    let a = pixels(first), b = pixels(next)
    var sum = 0
    for offset in stride(from: 0, to: a.count, by: 4) {
        for c in 0..<3 { sum += abs(Int(a[offset + c]) - Int(b[offset + c])) }
    }
    return Double(sum) / Double(first.width * first.height * 3)
}
@main private enum Main {
    static func main() {
        let app = NSApplication.shared, delegate = Delegate()
        app.setActivationPolicy(.regular);app.delegate = delegate;app.run()
    }
}
