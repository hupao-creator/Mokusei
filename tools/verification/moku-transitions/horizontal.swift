import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI

private struct HorizontalFailure: Error, CustomStringConvertible { let description: String }

@MainActor @Observable private final class HorizontalFixture {
    let state = NativeMokuSceneState()
    let normal = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    let annotation = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    let requestID = UUID()
    var right = false
    var leftWidth: CGFloat = 600
    var arrivals: [Int: TimeInterval] = [:]
    var draft: NativeComposerDraft { right ? annotation : normal }
    var request: SidecardComposerRequest? {
        right ? .init(id: requestID, placeholder: "Describe the selection", ready: true, submit: { _ in }, cancel: {}) : nil
    }
    init() {
        normal.text = "Ordinary draft retained across annotation"
        annotation.text = "Annotation description"
        state.readingPanelVisible = true
        state.setComposerContext(normal, opensInput: true, keepsInputOpen: true)
    }
    func toggle() {
        arrivals.removeAll()
        right.toggle()
        state.setComposerContext(draft, opensInput: true, keepsInputOpen: true)
    }
}

private struct HorizontalScene: View {
    let fixture: HorizontalFixture
    var body: some View {
        NativeMokuScene(state: fixture.state) {
            Color.white.overlay(alignment: .topLeading) {
                NativeExecutionDockRegion(placement: fixture.state.executionDockPlacement, threadID: "horizontal-fixture",
                    onSettled: {
                        let revision = fixture.state.executionDockPlacement.travelRevision
                        if fixture.arrivals[revision] == nil { fixture.arrivals[revision] = ProcessInfo.processInfo.systemUptime }
                    })
                    .destinationFrame(CGRect(x: fixture.right ? 640 : 20, y: 20,
                        width: fixture.right ? 600 : fixture.leftWidth, height: 600))
            }
        } thread: { Color.white } dock: {
            NativeMokuDock(state: fixture.state, draft: fixture.draft, cwd: "/tmp",
                threadID: "horizontal-fixture", threadTitle: "Fixture Agent", sidecardComposer: fixture.request,
                onSend: { _ in }, onCancel: {})
        } settings: { Color.white }
        .environment(\.colorScheme, .light)
    }
}

/// Captures only the fixture's window, on a queue independent of the main actor.
/// Timer callbacks or model-layer endpoints cannot prove compositor continuity.
private final class HorizontalCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Frame: Codable { let time: Double; let x: Int; let width: Int }
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var images: [CGImage] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard height > 70, let pixels = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        var left = width, right = 0
        // The fixture is white; the production dark capsule is the sole dark
        // region on this scanline through its lower, fixed reading seat.
        for x in 0..<width {
            let index = (height - 55) * stride + x * 4
            if Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) < 220 {
                left = min(left, x); right = max(right, x)
            }
        }
        guard right - left > 250 else { return }
        lock.lock(); defer { lock.unlock() }
        frames.append(Frame(time: ProcessInfo.processInfo.systemUptime, x: left, width: right - left))
        if frames.count <= 96, frames.count % 12 == 0,
           let context = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
           let image = context.makeImage() { images.append(image) }
    }

    func snapshot() -> [Frame] { lock.lock(); defer { lock.unlock() }; return frames }
    func export(to output: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try JSONEncoder().encode(frames).write(to: output.appendingPathComponent("horizontal-frames.json"))
        for (index, image) in images.enumerated() {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent("horizontal-\(index).png"))
        }
    }
}

@MainActor private func horizontalEditor(in view: NSView) -> NSTextView? {
    if let text = view as? NSTextView, text.isEditable { return text }
    return view.subviews.lazy.compactMap { horizontalEditor(in: $0) }.first
}

@MainActor private func horizontalSurface(in view: NSView) -> MokuHorizontalTravelView? {
    if let surface = view as? MokuHorizontalTravelView { return surface }
    return view.subviews.lazy.compactMap { horizontalSurface(in: $0) }.first
}

@MainActor private func awaitHorizontal(_ label: String, _ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw HorizontalFailure(description: "Timeout: " + label) }
        try await Task.sleep(for: .milliseconds(15))
    }
}

@MainActor private func holdMainActor() { Thread.sleep(forTimeInterval: 0.20) }

@MainActor func replayHorizontalTravel(output: URL) async throws -> [String: Any] {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let fixture = HorizontalFixture(), capture = HorizontalCapture()
    let host = NSHostingView(rootView: HorizontalScene(fixture: fixture))
    let window = NSWindow(contentRect: CGRect(x: 30, y: 30, width: 1280, height: 760),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Production Moku horizontal travel"
    window.isReleasedWhenClosed = false; window.contentView = host
    window.makeKeyAndOrderFront(nil); NSApp.activate()
    defer { window.close(); try? capture.export(to: output) }
    try await awaitHorizontal("initial editor and column") {
        horizontalEditor(in: host) != nil && fixture.state.executionDockPlacement.frame != nil && !fixture.arrivals.isEmpty
    }
    try await Task.sleep(for: .milliseconds(700))
    let windows = try await SCShareableContent.currentProcess.windows
    guard let target = windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
        throw HorizontalFailure(description: "Own WindowServer window unavailable")
    }
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width); config.height = Int(window.frame.height)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60); config.queueDepth = 8
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.ignoreShadowsSingleWindow = true; config.showsCursor = false
    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: nil)
    try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "moku-horizontal-capture"))
    try await stream.startCapture()
    do {
        try await Task.sleep(for: .milliseconds(150))
        guard let initialPixels = capture.snapshot().last else { throw HorizontalFailure(description: "Missing initial capsule pixels") }
        let motionStart = ProcessInfo.processInfo.systemUptime
        let previousRevision = fixture.state.executionDockPlacement.travelRevision
        fixture.toggle()
        try await awaitHorizontal("new column publication") { fixture.state.executionDockPlacement.travelRevision > previousRevision }
        let targetRevision = fixture.state.executionDockPlacement.travelRevision
        try await Task.sleep(for: .milliseconds(180))
        guard fixture.arrivals[targetRevision] == nil else { throw HorizontalFailure(description: "Column admitted before horizontal arrival") }
        guard let surface = horizontalSurface(in: host), let optical = capture.snapshot().last else {
            throw HorizontalFailure(description: "Missing native travel surface or optical frame")
        }
        let visiblePoint = CGPoint(x: CGFloat(optical.x) + CGFloat(optical.width) / 2, y: fixture.state.capsuleFrame.midY)
        guard surface.hitTest(surface.convert(visiblePoint, to: surface.superview)) === surface,
              surface.hitTest(surface.convert(CGPoint(x: 5, y: 5), to: surface.superview)) == nil else {
            throw HorizontalFailure(description: "Moving capsule leaks pointer hits or blocks unrelated workspace space")
        }
        let holdStart = ProcessInfo.processInfo.systemUptime
        holdMainActor()
        let holdEnd = ProcessInfo.processInfo.systemUptime
        try await awaitHorizontal("compositor arrival") { fixture.arrivals[targetRevision] != nil }
        guard let arrivalPixels = capture.snapshot().last else { throw HorizontalFailure(description: "Missing arrival pixels") }
        let movingFrames = capture.snapshot().filter { $0.time > holdStart + 0.03 && $0.time < holdEnd - 0.02 }
        let positions = Set(movingFrames.map(\.x))
        guard positions.count >= 3, (positions.max() ?? 0) - (positions.min() ?? 0) > 20 else {
            throw HorizontalFailure(description: "Capsule froze during main-actor hold: \(positions.sorted())")
        }
        fixture.toggle()
        try await Task.sleep(for: .milliseconds(120))
        let returnRevision = fixture.state.executionDockPlacement.travelRevision
        fixture.toggle()
        try await awaitHorizontal("reversed column publication") { fixture.state.executionDockPlacement.travelRevision > returnRevision }
        let reversedRevision = fixture.state.executionDockPlacement.travelRevision
        try await Task.sleep(for: .milliseconds(120))
        guard fixture.arrivals[reversedRevision] == nil else { throw HorizontalFailure(description: "Interrupted travel admitted a newer column") }
        try await awaitHorizontal("reversed arrival") { fixture.arrivals[reversedRevision] != nil }
        let fixedWidthFrames = capture.snapshot().filter { $0.time >= motionStart }
        let envelope = (min(initialPixels.x, arrivalPixels.x) - 30)...(max(initialPixels.x, arrivalPixels.x) + 30)
        let minimumWidth = min(initialPixels.width, arrivalPixels.width) - 2
        guard fixedWidthFrames.allSatisfy({ envelope.contains($0.x) && $0.width >= minimumWidth }) else {
            let invalid = fixedWidthFrames.filter { !envelope.contains($0.x) || $0.width < minimumWidth }
            throw HorizontalFailure(description: "Reversal escaped its optical envelope or clipped the capsule: \(invalid)")
        }
        fixture.leftWidth = 420
        fixture.toggle()
        var widths = Set<Int>()
        let deadline = ProcessInfo.processInfo.systemUptime + 1.6
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let width = horizontalEditor(in: host)?.enclosingScrollView?.frame.width { widths.insert(Int((width * 100).rounded())) }
            try await Task.sleep(for: .milliseconds(8))
        }
        guard !widths.isEmpty, widths.count <= 2 else {
            throw HorizontalFailure(description: "Native editor missing or reflowed during travel: \(widths.sorted())")
        }
        guard fixture.normal.text == "Ordinary draft retained across annotation", fixture.annotation.text == "Annotation description" else {
            throw HorizontalFailure(description: "Column travel changed a retained draft")
        }
        let resizePreviousRevision = fixture.state.executionDockPlacement.travelRevision
        fixture.toggle()
        try await awaitHorizontal("resize column publication") { fixture.state.executionDockPlacement.travelRevision > resizePreviousRevision }
        try await Task.sleep(for: .milliseconds(120))
        window.setContentSize(CGSize(width: 1200, height: 700))
        try await awaitHorizontal("resize settles travel") { fixture.arrivals[fixture.state.executionDockPlacement.travelRevision] != nil }
        try await stream.stopCapture()
        return ["busyIntervalPositions": positions.count, "nativeEditorWidths": widths.count,
                "checks": ["WindowServer motion during main-actor hold", "arrival-gated input", "moving capsule absorbs pointer hits", "optical reversal envelope and unclipped width", "discrete native editor width", "retained drafts", "resize settling"]]
    } catch {
        try? await stream.stopCapture()
        throw error
    }
}
