// Own-window video regression: production canvas + production HarnessThreadCard.
// Synthetic conversation data; no runtime, installed app, or global input.
import AppKit
import AVFoundation
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiPluginUI
import MokuseiUI

@MainActor @Observable private final class Fixture {
    let state = NativeOverviewCanvasState()
    var items: [NativeOverviewItem] = []
    var selection = "all"
    var dark = false
    var label = "Background reference"
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var appearances: [String: Int] = [:]
    let presentation = try! composeThreadCard(.standard(identity: .init(), extensions: []), layoutContext: .init(availableCols: 4))
    let all = (0..<16).map { NativeOverviewItem(id: "card-\($0)", completed: true) }
    var subset: [NativeOverviewItem] { [all[5], all[9], all[13]] }
}

private struct Surface: View {
    let fixture: Fixture
    var body: some View {
        ZStack {
            LinearGradient(colors: [.orange.opacity(0.6), .purple.opacity(0.6), .blue.opacity(0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            NativeOverviewCanvas(items: fixture.items, sceneKey: fixture.selection, state: fixture.state,
                                 selectionID: fixture.selection) { item in
                HarnessThreadCard(identity: .init(title: "真实卡片 \(item.id)", model: "GPT-6", excerpt: "玻璃、角标和文字应当一起消失。\nProduction card transition regression."),
                    presentation: fixture.presentation, onFollowUp: {},
                    status: .init(kind: .completed, label: "已完成", terminal: .completed), emoji: "📏")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("capture")) } action: { fixture.frames[item.id] = $0 }
                    .onAppear { fixture.appearances[item.id, default: 0] += 1 }
            }.coordinateSpace(name: "capture")
            VStack { Text(fixture.label).font(.system(size: 16, weight: .medium)).padding(12); Spacer() }
                .allowsHitTesting(false)
        }.preferredColorScheme(fixture.dark ? .dark : .light)
    }
}

@MainActor private final class Recording: NSObject, SCRecordingOutputDelegate {
    var started = false
    var finished = false
    var error: String?
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.started = true }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finished = true }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        let message = String(describing: error)
        Task { @MainActor in self.error = message }
    }
}

private struct Failure: Error, CustomStringConvertible { let description: String }

@MainActor private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw Failure(description: "Capture condition timed out")
}

@MainActor private func capture() async throws {
    let directory = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MokuseiTransitionCaptureDirectory") as! String)
    let fixture = Fixture()
    let host = NSHostingView(rootView: Surface(fixture: fixture))
    let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1180, height: 780),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.level = .floating
    window.makeKeyAndOrderFront(nil); NSApp.activate()
    defer { fixture.state.camera.dispose(); window.close() }
    try await Task.sleep(for: .milliseconds(500))
    let content = try await SCShareableContent.currentProcess
    guard let target = content.windows.first(where: {
        $0.windowID == CGWindowID(window.windowNumber) && abs($0.frame.width - 1180) < 1 && abs($0.frame.height - 780) < 1
    }) else { throw Failure(description: "Full-size own native window unavailable") }
    let filter = SCContentFilter(desktopIndependentWindow: target)
    let config = SCStreamConfiguration()
    config.width = 2360; config.height = 1560; config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.queueDepth = 6; config.ignoreShadowsSingleWindow = true; config.scalesToFit = true
    config.showsCursor = false; config.capturesAudio = false; config.captureMicrophone = false
    config.colorSpaceName = CGColorSpace.sRGB
    let video = directory.appendingPathComponent("real-cards.mp4")
    try? FileManager.default.removeItem(at: video)
    let recordingConfig = SCRecordingOutputConfiguration()
    recordingConfig.outputURL = video; recordingConfig.videoCodecType = .h264; recordingConfig.outputFileType = .mp4
    let delegate = Recording()
    let recording = SCRecordingOutput(configuration: recordingConfig, delegate: delegate)
    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    try stream.addRecordingOutput(recording)
    try await stream.startCapture()
    try await wait { delegate.started || delegate.error != nil }
    if let error = delegate.error { throw Failure(description: error) }
    let start = ProcessInfo.processInfo.systemUptime
    var events: [[String: Any]] = []
    func event(_ name: String) {
        fixture.label = name
        events.append(["name": name, "at": ProcessInfo.processInfo.systemUptime - start])
    }
    func snapshot(_ name: String) async throws -> CGImage {
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard image.width == 2360 && image.height == 1560 else { throw Failure(description: "Invalid capture dimensions") }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            .write(to: directory.appendingPathComponent("\(name).png"))
        return image
    }
    for dark in [false, true] {
        fixture.dark = dark
        let theme = dark ? "dark" : "light"
        fixture.items = []; fixture.selection = "\(theme)-empty"
        try await wait { !fixture.state.isLayingOut && fixture.state.presentedPlacements.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await snapshot("\(theme)-background")
        event("\(theme): initial 16 real cards")
        fixture.items = fixture.all; fixture.selection = "\(theme)-all"
        try await wait { !fixture.state.isLayingOut && fixture.state.mountedCardIDs.count == 16 }
        try await Task.sleep(for: .milliseconds(400))
        _ = try await snapshot("\(theme)-grid")
        let oldFrames = fixture.frames.mapValues { NSStringFromRect($0) }
        let retainedAppearances = Dictionary(uniqueKeysWithValues: fixture.subset.map { ($0.id, fixture.appearances[$0.id, default: 0]) })
        event("\(theme): filter 16 → 3")
        fixture.items = fixture.subset; fixture.selection = "\(theme)-three"
        try await wait { fixture.state.isLayingOut && fixture.state.presentedPlacements.count == 3 }
        let began = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(210))
        _ = try await snapshot("\(theme)-exit-210ms")
        events.append(["name": "\(theme): exit snapshot", "elapsed": ProcessInfo.processInfo.systemUptime - began,
                       "layingOut": fixture.state.isLayingOut, "oldFrames": oldFrames])
        try await wait { !fixture.state.isLayingOut }
        try await Task.sleep(for: .milliseconds(350))
        event("\(theme): reverse 3 → 16")
        fixture.frames.removeValue(forKey: "card-0")
        fixture.items = fixture.all; fixture.selection = "\(theme)-all"
        try await wait { fixture.state.isLayingOut && fixture.state.presentedPlacements.count == 16 && fixture.frames["card-0"] != nil }
        guard let entering = fixture.frames["card-0"],
              let placement = fixture.state.presentedPlacements.first(where: { $0.id == "card-0" }) else {
            throw Failure(description: "Missing entering production card")
        }
        let finalWidth = Double(placement.columns * 376 - 16) * fixture.state.camera.liveTransform.scale
        guard entering.width < finalWidth * 0.99 else {
            throw Failure(description: "Dense entry skipped its initial scale: \(entering.width) / \(finalWidth)")
        }
        try await wait {
            guard let frame = fixture.frames["card-0"] else { return false }
            return frame.width > entering.width + 0.5 && frame.width < finalWidth - 0.1
        }
        events.append(["name": "\(theme): dense entry intermediate geometry", "at": ProcessInfo.processInfo.systemUptime - start,
                       "firstWidth": entering.width, "intermediateWidth": fixture.frames["card-0"]!.width, "finalWidth": finalWidth])
        _ = try await snapshot("\(theme)-entry-intermediate")
        try await wait { !fixture.state.isLayingOut && fixture.state.presentedPlacements.count == 16 }
        try await Task.sleep(for: .milliseconds(350))
        event("\(theme): interrupt after 95ms")
        fixture.items = fixture.subset; fixture.selection = "\(theme)-three"
        try await wait { fixture.state.isLayingOut && fixture.state.presentedPlacements.count == 3 }
        try await Task.sleep(for: .milliseconds(95))
        fixture.items = fixture.all; fixture.selection = "\(theme)-all"
        try await wait { !fixture.state.isLayingOut && fixture.state.presentedPlacements.count == 16 }
        try await Task.sleep(for: .milliseconds(350))
        guard retainedAppearances.allSatisfy({ fixture.appearances[$0.key] == $0.value }) else {
            throw Failure(description: "Filter/reversal remounted retained production card content")
        }
        event("\(theme): ordinary removal")
        fixture.items.removeAll { $0.id == "card-0" }
        try await wait { fixture.state.isLayingOut }
        try await Task.sleep(for: .milliseconds(190))
        _ = try await snapshot("\(theme)-ordinary-exit")
        try await wait { !fixture.state.isLayingOut }
        event("\(theme): ordinary empty result")
        // A single last card checks exit-before-camera-disposal without a long
        // sixteen-card sequential reflow. Filter down first, then ordinary clear.
        fixture.items = [fixture.all[5]]; fixture.selection = "\(theme)-one"
        try await wait { !fixture.state.isLayingOut && fixture.state.presentedPlacements.count == 1 }
        fixture.items = []
        try await wait { !fixture.state.isLayingOut && fixture.state.mountedCardIDs.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
    }
    try await stream.stopCapture()
    try await wait { delegate.finished || delegate.error != nil }
    if let error = delegate.error { throw Failure(description: error) }
    try JSONSerialization.data(withJSONObject: ["events": events, "duration": recording.recordedDuration.seconds,
        "capture": "ScreenCaptureKit own full-size WindowServer window; production HarnessThreadCard and NativeOverviewCanvas"],
        options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("events.json"))
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let result = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MokuseiReplayResult") as! String)
            do {
                try await capture()
                try Data("PASS real-card WindowServer recording completed\n".utf8).write(to: result)
                exit(0)
            } catch {
                try? Data("FAIL \(error)\n".utf8).write(to: result)
                exit(1)
            }
        }
    }
}

@main private enum Main {
    static func main() {
        prepareReplayEnvironment()
        let delegate = Delegate(), app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.delegate = delegate; app.run()
    }
}
