import AppKit
import AVFoundation
import MokuseiCore
import MokuseiUI
import MokuseiPluginUI
import Observation
import ScreenCaptureKit
import SwiftUI

@MainActor @Observable private final class Fixture {
    let state = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var long = true
    var landing = false
    var animationsDisabled = false
    var zoom: CGFloat = 1
    var size = CGSize(width: 900, height: 720)
    var note: NativeMokuNote {
        NativeMokuNote(id: "isolated-note-preview", text: long ? Self.prose : "笔记内容保留。", revision: 1, updatedAt: 1)
    }
    static let prose = "# 本地笔记 · 动画预览\n\n" + (1...10).map {
        "- 第 \($0) 项：收起、展开和快速往返只改变面板呈现，保留 Note 和输入草稿。"
    }.joined(separator: "\n")
}

private struct Preview: View {
    let fixture: Fixture
    var body: some View {
        ZStack {
            Color(red: 0.95, green: 0.94, blue: 0.96)
            VStack(spacing: 16) {
                ForEach(0..<4) { _ in
                    HStack(spacing: 16) {
                        ForEach(0..<2) { _ in
                            VStack(alignment: .leading, spacing: 12) {
                                Text("背景卡片").font(.headline)
                                Text("隔离 fixture · 不读取用户笔记\n用浅色背景观察收缩时的玻璃与暖黑渐变").font(.caption)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(20).background(.white, in: .rect(cornerRadius: 24))
                        }
                    }
                }
            }.padding(50)
            NativeMokuDock(state: fixture.state, draft: fixture.draft, cwd: "/isolated/note-preview",
                landing: fixture.landing, note: fixture.note, onSend: { _ in }, onCancel: {})
                .frame(width: fixture.size.width / fixture.zoom, height: fixture.size.height / fixture.zoom)
                .scaleEffect(fixture.zoom)
                .transaction { transaction in
                    if fixture.animationsDisabled {
                        transaction.animation = nil; transaction.disablesAnimations = true
                    }
                }
        }
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .environment(\.colorScheme, .light)
        .environment(\.scenePhase, .active)
        .frame(width: fixture.size.width, height: fixture.size.height)
    }
}

private final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        print("recording error:", error)
    }
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let fixture = Fixture()
    var previewTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        fixture.draft.text = "Retained draft 草稿"
        window = NSPanel(contentRect: NSRect(origin: CGPoint(x: 180, y: 180), size: fixture.size),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Production Moku Note · isolated transition preview"
        window.contentView = NSHostingView(rootView: Preview(fixture: fixture))
        window.orderFrontRegardless()
        previewTask = Task { @MainActor in
            do { try await record() }
            catch { print("preview error:", error) }
            window.close()
            NSApp.terminate(nil)
        }
    }

    func record() async throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else {
            throw CocoaError(.fileWriteFileExists)
        }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        try await Task.sleep(for: .milliseconds(600))
        let shareable = try await SCShareableContent.currentProcess
        guard let ownWindow = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.fileReadUnknown)
        }
        let config = SCStreamConfiguration()
        config.width = 1800; config.height = 1500
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false; config.captureMicrophone = false
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: config, delegate: nil)
        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = destination.appendingPathComponent("note-transitions.mp4")
        let recordingDelegate = RecordingDelegate()
        let output = SCRecordingOutput(configuration: outputConfig, delegate: recordingDelegate)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        let start = ContinuousClock.now
        var events: [[String: Any]] = []
        func event(_ name: String) {
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            events.append(["seconds": seconds, "event": name, "open": fixture.state.notePanelOpen,
                "size": [fixture.size.width, fixture.size.height], "zoom": fixture.zoom, "animationsDisabled": fixture.animationsDisabled])
        }
        func capture(_ name: String) async throws {
            // A stream retains its original output canvas through native window
            // resizes. Refresh the own-window filter for full-bounds stills.
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw CocoaError(.fileReadUnknown)
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            configuration.ignoreShadowsSingleWindow = true
            configuration.showsCursor = false
            configuration.scalesToFit = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: destination.appendingPathComponent(name + ".png"))
        }
        func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }
        func toggle(_ open: Bool, _ name: String) {
            if open { fixture.state.openNotePanelFromUser() } else { fixture.state.setNotePanelOpen(false) }
            event(name)
        }
        try await pause(350)
        toggle(true, "long-open"); try await pause(850)
        toggle(false, "long-close"); try await pause(650)
        toggle(true, "reopen"); try await pause(120)
        toggle(false, "reverse-opening"); try await pause(90)
        toggle(true, "reverse-closing"); try await pause(650)
        toggle(false, "close-again"); try await pause(650)
        fixture.long = false; event("short-note")
        toggle(true, "short-open"); try await pause(650)
        toggle(false, "short-close"); try await pause(650)
        fixture.size = CGSize(width: 360, height: 380)
        window.setContentSize(fixture.size); fixture.long = true; event("narrow-window")
        toggle(true, "narrow-open"); try await pause(650); try await capture("narrow-open")
        fixture.size = CGSize(width: 440, height: 300)
        window.setContentSize(fixture.size); event("resize-open-note"); try await pause(650); try await capture("resized-open")
        toggle(false, "narrow-close"); try await pause(650)
        fixture.size = CGSize(width: 900, height: 720)
        window.setContentSize(fixture.size); fixture.landing = true; event("landing")
        try await pause(650)
        toggle(true, "landing-open"); try await pause(650); try await capture("landing-open")
        toggle(false, "landing-close"); try await pause(650)
        fixture.landing = false; fixture.zoom = 5; event("zoom-5x")
        toggle(true, "zoom-open"); try await pause(650); try await capture("zoom-open")
        toggle(false, "zoom-close"); try await pause(650)
        fixture.zoom = 1; fixture.animationsDisabled = true; event("disable-animations-fixture")
        try await pause(350)
        toggle(true, "reduced-open"); try await pause(180)
        toggle(false, "reduced-close"); try await pause(180)
        toggle(true, "reduced-reopen"); try await pause(180)
        toggle(false, "reduced-close-again"); try await pause(350)
        try await stream.stopCapture()
        try await pause(500)
        withExtendedLifetime(recordingDelegate) {}
        let report: [String: Any] = ["events": events, "draft": fixture.draft.text,
            "note": fixture.note.text, "foregroundUnchanged": foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier,
            "scope": "Visual preview of production Dock with synthetic note; no Runtime, assertions, tests or live profile"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("observations.json"))
        print("preview saved:", destination.path)
    }
}

@main private struct Main {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: MokuNoteTransitionPreview /absolute/empty/output-directory")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
