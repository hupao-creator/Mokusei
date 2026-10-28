import AppKit
import Observation
import MokuseiCore
import MokuseiPluginUI
@testable import MokuseiUI
import ScreenCaptureKit
import SwiftUI

private struct Failure: Error, CustomStringConvertible { var description: String }
@MainActor @Observable private final class Fixture {
    let state = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var running = false
    var reduceMotion = false
    var tool = false
    var talk: String?
    var mounted = true
    var phase: ScenePhase = .active
    var freezeBlink = false
    var probing = false
    var focus = 0.0
    var probeFrame = CGRect.zero
    var referenceFrame = CGRect.zero
    let reducedCharacter = NativeMokuCharacterMotion()
}
private struct Scene: View {
    let fixture: Fixture
    var body: some View {
        NativeMokuScene(state: fixture.state) { Color.white } thread: { Color.white } dock: {
            if fixture.mounted {
                NativeMokuDock(state: fixture.state, draft: fixture.draft, cwd: "/tmp",
                    mode: fixture.tool ? .tool : fixture.running && !fixture.reduceMotion ? .running : .idle, running: fixture.running,
                    talk: fixture.talk, reply: .init(id: "unread", readKey: "unread", excerpt: "Unread reply", executionID: "fixture"), onSend: { _ in }, onCancel: {})
                    .environment(\.scenePhase, fixture.freezeBlink ? .inactive : fixture.phase)
            }
        } settings: { Color.white }
        .overlay(alignment: .top) {
            if fixture.probing {
                VStack(spacing: 40) {
                    NativeMokuBlinkingEyes(expression: fixture.focus == 1 ? .focus : .happy, focus: fixture.focus)
                        .frame(width: 34, height: 25).scaleEffect(4)
                        .frame(width: 136, height: 100)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("blink-replay")) } action: { fixture.probeFrame = $0 }
                    NativeMokuCapsuleEyes(expression: .happy, focus: fixture.focus).fill(.primary)
                        .frame(width: 34, height: 25).scaleEffect(4)
                        .frame(width: 136, height: 100)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("blink-replay")) } action: { fixture.referenceFrame = $0 }
                }.padding(.top, 30).allowsHitTesting(false)
            }
        }
        .overlay {
            // Reduce Motion is a read-only system environment value. Exercise
            // the same production component's input without altering OS prefs.
            if fixture.reduceMotion {
                NativeMokuCharacterSurface(controller: fixture.reducedCharacter,
                    input: .init(expression: .idle, focus: 0, running: true, reasoning: nil,
                        presentsReasoning: false, executionKey: "reduced-orbit",
                        capsuleSize: fixture.state.capsuleFrame.size,
                        cornerRadius: NativeMokuCapsuleLayout.cornerRadius,
                        motion: true, reduceMotion: true, dark: false), seat: .decorations)
                    .frame(width: fixture.state.capsuleFrame.width + 24,
                           height: fixture.state.capsuleFrame.height + 24)
                    .position(x: fixture.state.capsuleFrame.midX, y: fixture.state.capsuleFrame.midY)
            }
        }
        .coordinateSpace(name: "blink-replay")
        .environment(\.colorScheme, .light)
    }
}
private func png(_ image: CGImage, _ url: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
private func ink(_ image: CGImage) -> Int {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let count = pixels.withUnsafeMutableBytes { buffer -> Int in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = buffer.bindMemory(to: UInt8.self)
        return stride(from: 0, to: bytes.count, by: 4).reduce(0) { result, offset in
            result + (bytes[offset + 3] > 240 && bytes[offset] < 110 && bytes[offset + 1] < 110 && bytes[offset + 2] < 110 ? 1 : 0)
        }
    }
    return count
}
// WindowServer can return a full-sized image of a window while Stage Manager
// is still transforming it. Transparent pixels outside that transformed window
// are not eye ink and must never become the open-eye reference.
private func coversFullWindow(_ image: CGImage) -> Bool {
    var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
    return pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let bytes = buffer.bindMemory(to: UInt8.self)
        return stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 240 }.count >= 1000
    }
}
@MainActor private func replay() async throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/mokusei-moku-blink-evidence")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = Fixture()
    let host = NSHostingView(rootView: Scene(fixture: fixture))
    let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 900, height: 480),
        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    // Keep this auxiliary fixture out of Stage Manager's app-switch transforms.
    window.level = .floating
    window.title = "Production Moku blink regression replay"
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(500))
    var target: SCWindow?
    for _ in 0..<60 {
        let content = try await SCShareableContent.currentProcess
        target = content.windows.first(where: {
            $0.windowID == CGWindowID(window.windowNumber)
                && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                && abs($0.frame.width - window.frame.width) < 1
                && abs($0.frame.height - window.frame.height) < 1
        })
        if target != nil { break }
        try await Task.sleep(for: .milliseconds(200))
    }
    guard let target else { throw Failure(description: "Full-size own native window unavailable; refusing thumbnail evidence") }
    let filter = SCContentFilter(desktopIndependentWindow: target)
    print("CAPTURE window=\(window.frame) target=\(target.frame) filter=\(filter.contentRect) scale=\(filter.pointPixelScale)")
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width * 2)
    configuration.height = Int(window.frame.height * 2)
    configuration.ignoreShadowsSingleWindow = true
    configuration.scalesToFit = true
    configuration.showsCursor = false
    configuration.capturesAudio = false
    configuration.captureMicrophone = false
    configuration.colorSpaceName = CGColorSpace.sRGB
    var results: [[String: Any]] = []
    func stableCapture() async throws -> CGImage {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var rejected: CGImage?
        while ProcessInfo.processInfo.systemUptime < deadline {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            if coversFullWindow(image) { return image }
            rejected = image
            try await Task.sleep(for: .milliseconds(50))
        }
        if let rejected { try png(rejected, directory.appendingPathComponent("invalid-window.png")) }
        throw Failure(description: "Full-size own WindowServer pixels unavailable; refusing transformed/thumbnail evidence")
    }
    func sample() async throws -> (CGImage, CGImage, Int) {
        let image = try await stableCapture()
        guard window.occlusionState.contains(.visible) else {
            throw Failure(description: "Production eyes must be visible in a real native window")
        }
        // The production eye is a SwiftUI Shape, with no AppKit canvas. The
        // settled capsule's scene coordinates locate its 34 x 25 point seat.
        let surface = fixture.state.capsuleFrame
        let expanded = surface.width > NativeMokuCapsuleLayout.idleSize.width + 0.5
        let frame = CGRect(x: expanded ? surface.minX + 15 : surface.midX - 17,
                           y: surface.midY - 12.5, width: 34, height: 25)
        let sx = Double(image.width) / window.frame.width, sy = Double(image.height) / window.frame.height
        let rect = CGRect(x: frame.minX * sx, y: (window.frame.height - host.bounds.height + frame.minY) * sy,
                          width: frame.width * sx, height: frame.height * sy).integral
        guard let crop = image.cropping(to: rect) else { throw Failure(description: "Eye screenshot crop failed") }
        return (image, crop, ink(crop))
    }
    func observe(_ name: String, cycles: Int = 1, streaming: Bool = false) async throws {
        var baseline = 0, closed = false, completed = 0, lowest = Int.max
        let started = ProcessInfo.processInfo.systemUptime
        var index = 0
        while ProcessInfo.processInfo.systemUptime - started < Double(cycles) * 4.5 + 1.5 {
            if streaming { fixture.talk = "Moku is talking. Streaming update \(index)" }
            let (image, crop, count) = try await sample()
            if !closed, count > baseline {
                baseline = count
                if completed == 0 {
                    try png(crop, directory.appendingPathComponent(name + "-open-eyes.png"))
                    try png(image, directory.appendingPathComponent(name + "-open.png"))
                }
            }
            if index < 3 { print("SAMPLE \(name) ink=\(count) surface=\(fixture.state.capsuleFrame) image=\(image.width)x\(image.height)") }
            lowest = min(lowest, count)
            if baseline > 80, count < baseline / 3, !closed {
                closed = true
                try png(image, directory.appendingPathComponent("\(name)-\(completed)-closed.png"))
                try png(crop, directory.appendingPathComponent("\(name)-\(completed)-closed-eyes.png"))
            }
            if closed, count > baseline * 4 / 5 {
                try png(image, directory.appendingPathComponent("\(name)-\(completed)-reopened.png"))
                try png(crop, directory.appendingPathComponent("\(name)-\(completed)-reopened-eyes.png"))
                completed += 1; closed = false
                if completed == cycles {
                    let result: [String: Any] = ["state": name, "cycles": completed, "openInkPixels": baseline,
                        "minimumInkPixels": lowest, "seconds": ProcessInfo.processInfo.systemUptime - started]
                    results.append(result)
                    print("PASS \(result)")
                    return
                }
            }
            index += 1
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure(description: "\(name): no natural close/reopen, cycles=\(completed), openInk=\(baseline), minInk=\(lowest)")
    }
    func crop(_ image: CGImage, frame: CGRect) throws -> CGImage {
        let scale = Double(image.width) / window.frame.width
        let rect = CGRect(x: frame.minX * scale,
            y: (window.frame.height - host.bounds.height + frame.minY) * scale,
            width: frame.width * scale, height: frame.height * scale).integral
        guard let result = image.cropping(to: rect) else { throw Failure(description: "Probe crop failed") }
        return result
    }
    func mask(_ image: CGImage) -> [Bool] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] < 110 && pixels[$0 + 3] > 240 }
    }
    func observeFocusTransitions() async throws {
        fixture.probing = true
        try await Task.sleep(for: .milliseconds(300))
        // Start just after a natural blink so its independent closure is not
        // mistaken for a focus-morph mismatch against the open-eye reference.
        while Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.2) < 0.4 {
            try await Task.sleep(for: .milliseconds(25))
        }
        var maximumDifference = 0.0, frames = 0
        for (target, seconds) in [(1.0, 0.55), (0.0, 0.55), (1.0, 0.14), (0.0, 0.55)] {
            withAnimation(.linear(duration: 0.42)) { fixture.focus = target }
            let started = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - started < seconds {
                let image = try await stableCapture()
                let date = Date()
                if NativeMokuCapsuleBlinkTiming.factor(at: date) == 1 {
                    let actual = mask(try crop(image, frame: fixture.probeFrame))
                    let expected = mask(try crop(image, frame: fixture.referenceFrame))
                    guard actual.count == expected.count else { throw Failure(description: "Probe sizes differ") }
                    let expectedInk = expected.filter { $0 }.count
                    guard expectedInk > 500 else { throw Failure(description: "No reference eye ink") }
                    let mismatch = Double(zip(actual, expected).filter { $0 != $1 }.count) / Double(expectedInk)
                    maximumDifference = max(maximumDifference, mismatch)
                    try png(image, directory.appendingPathComponent("focus-\(frames).png"))
                    frames += 1
                }
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        let measurement: [String: Any] = ["state": "focus-transitions", "frames": frames, "maximumMaskDifference": maximumDifference]
        results.append(measurement)
        try JSONSerialization.data(withJSONObject: measurement, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("focus-measurements.json"))
        guard frames >= 12, maximumDifference < 0.20 else {
            throw Failure(description: "Focus transition diverged from continuous Shape animation: frames=\(frames), difference=\(maximumDifference)")
        }
        fixture.probing = false
        print("PASS continuous focus transitions: \(frames) frames, difference=\(maximumDifference)")
    }
    if CommandLine.arguments.contains("--orbit-only") {
        func character(in view: NSView) -> NativeMokuCharacterMotion? {
            if let canvas = view as? NativeMokuCharacterCanvas, canvas.seat == .face { return canvas.controller }
            return view.subviews.lazy.compactMap { character(in: $0) }.first
        }
        func waitForRetirement() async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while let character = character(in: host), character.isTransitioning
                || (0..<3).contains(where: { character.pose["d\($0)a"] > 0.001 }) {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw Failure(description: "Running decoration did not finish its handoff")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func coloredPixels(_ name: String) async throws -> [Int] {
            let image = try await stableCapture()
            try png(image, directory.appendingPathComponent(name + ".png"))
            let surface = fixture.state.capsuleFrame
            let sx = Double(image.width) / window.frame.width
            let sy = Double(image.height) / window.frame.height
            let rect = CGRect(x: (surface.minX - 12) * sx,
                              y: (window.frame.height - host.bounds.height + surface.minY - 12) * sy,
                              width: (surface.width + 24) * sx, height: (surface.height + 24) * sy).integral
            guard let crop = image.cropping(to: rect) else { throw Failure(description: "Orbit crop failed") }
            var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            return pixels.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                let bytes = buffer.bindMemory(to: UInt8.self)
                return stride(from: 0, to: bytes.count, by: 4).compactMap { offset in
                    let rgb = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
                    return bytes[offset + 3] > 240 && rgb.max()! - rgb.min()! > 35 ? offset / 4 : nil
                }
            }
        }
        fixture.running = true
        try await Task.sleep(for: .milliseconds(600))
        var positions = Set<Int>()
        let surface = fixture.state.capsuleFrame
        let pixelWidth = Int((surface.width + 24) * 2)
        let pixelHeight = Int((surface.height + 24) * 2)
        let radius = min(NativeMokuCapsuleLayout.cornerRadius, surface.height / 2)
        for index in 0..<80 {
            let pixels = try await coloredPixels("orbit-\(index)")
            for pixel in pixels {
                let x = abs((Double(pixel % pixelWidth) + 0.5) / 2 - 12 - surface.width / 2)
                let y = abs((Double(pixel / pixelWidth) + 0.5) / 2 - 12 - surface.height / 2)
                let distance = hypot(max(0, x - (surface.width / 2 - radius)),
                                     max(0, y - (surface.height / 2 - radius))) - radius
                guard distance > 1 else {
                    throw Failure(description: "Orbit ink touched or entered the visible capsule: distance=\(distance)")
                }
            }
            positions.formUnion(pixels)
            try await Task.sleep(for: .milliseconds(80))
        }
        // The glass starts 24px inside this crop; all four extrema must be outside it.
        guard positions.contains(where: { $0 % pixelWidth < 20 }),
              positions.contains(where: { $0 % pixelWidth > pixelWidth - 20 }),
              positions.contains(where: { $0 / pixelWidth < 20 }),
              positions.contains(where: { $0 / pixelWidth > pixelHeight - 20 }) else {
            throw Failure(description: "Running dots did not follow the capsule contour")
        }
        fixture.phase = .inactive
        try await Task.sleep(for: .milliseconds(200))
        let paused = try await coloredPixels("orbit-paused")
        try await Task.sleep(for: .milliseconds(500))
        guard !paused.isEmpty, paused == (try await coloredPixels("orbit-paused-later")) else {
            throw Failure(description: "Inactive orbit did not freeze")
        }
        fixture.phase = .active
        fixture.running = false
        // Let the ordinary Dock finish its real exit before mounting a separate
        // reduced-motion input. Otherwise its retiring dots contaminate the
        // supposedly static reference during the first half-second.
        try await Task.sleep(for: .milliseconds(50))
        try await waitForRetirement()
        fixture.reduceMotion = true
        try await Task.sleep(for: .milliseconds(200))
        let still = try await coloredPixels("orbit-reduced")
        try await Task.sleep(for: .milliseconds(500))
        guard !still.isEmpty, still == (try await coloredPixels("orbit-reduced-later")) else {
            throw Failure(description: "Reduce Motion did not retain static dots")
        }
        let columns = Set(still.map { $0 % pixelWidth }).sorted()
        let groups = zip(columns, columns.dropFirst()).filter { $1 - $0 > 1 }.count + 1
        guard groups == 3, still.count >= 150 else {
            throw Failure(description: "Static feedback must contain three clearly visible, unclipped 5pt dots")
        }
        fixture.reduceMotion = false
        for state in ["tool", "input", "idle", "cancelled"] {
            fixture.tool = state == "tool"
            fixture.running = state != "idle" && state != "cancelled"
            fixture.state.setInputOpen(state == "input")
            try await Task.sleep(for: .milliseconds(650))
            try await waitForRetirement()
            guard try await coloredPixels("orbit-exit-" + state).isEmpty else {
                throw Failure(description: "Running dots survived \(state)")
            }
        }
        fixture.running = true
        try await Task.sleep(for: .milliseconds(650))
        guard try await !coloredPixels("orbit-restarted").isEmpty else {
            throw Failure(description: "Running dots did not restart")
        }
        await fixture.draft.dispose()
        print("PASS capsule contour orbit, pause, Reduce Motion, tool/input/idle/cancel exits and restart")
        return
    }
    try await observeFocusTransitions()
    func rightEyeSlope(_ image: CGImage) throws -> Double? {
        guard let strip = image.cropping(to: CGRect(x: 0, y: image.height - 160, width: image.width, height: 136)) else {
            throw Failure(description: "Dock crop failed")
        }
        let pixels = mask(strip), width = strip.width
        var visited = Set<Int>(), candidates: [(x: Double, slope: Double)] = []
        for seed in pixels.indices where pixels[seed] && !visited.contains(seed) {
            var queue = [seed], index = 0, points: [(Double, Double)] = []
            visited.insert(seed)
            while index < queue.count {
                let point = queue[index]; index += 1
                let x = point % width, y = point / width
                points.append((Double(x), Double(y)))
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy, next = ny * width + nx
                    if nx >= 0, nx < width, ny >= 0, ny < strip.height,
                       pixels[next], visited.insert(next).inserted { queue.append(next) }
                }
            }
            guard points.count > 200 else { continue } // Excludes caret/text, retains open eyes.
            let count = Double(points.count)
            let x = points.reduce(0) { $0 + $1.0 } / count
            let y = points.reduce(0) { $0 + $1.1 } / count
            let variance = points.reduce(0) { $0 + ($1.1 - y) * ($1.1 - y) }
            let covariance = points.reduce(0) { $0 + ($1.0 - x) * ($1.1 - y) }
            if variance > 0 { candidates.append((x, covariance / variance)) }
        }
        guard candidates.count == 2 else { return nil }
        return candidates.max(by: { $0.x < $1.x })?.slope
    }
    func observeDockTransitions() async throws {
        fixture.probing = false
        try await Task.sleep(for: .milliseconds(300))
        var frames: [[String: Any]] = []
        var closingSlopes: [Double] = []
        for (open, seconds) in [(true, 0.65), (false, 0.65), (true, 0.16), (false, 0.65)] {
            fixture.state.setInputOpen(open)
            let started = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - started < seconds {
                let before = Date()
                let image = try await stableCapture()
                let seconds = ProcessInfo.processInfo.systemUptime - started
                if !open, seconds > 0.18, seconds < 0.4,
                   NativeMokuCapsuleBlinkTiming.factor(at: before.addingTimeInterval(-0.05)) == 1,
                   NativeMokuCapsuleBlinkTiming.factor(at: Date()) == 1,
                   let slope = try rightEyeSlope(image) {
                    closingSlopes.append(slope)
                }
                try png(image, directory.appendingPathComponent("dock-\(frames.count).png"))
                frames.append(["open": open, "seconds": seconds])
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted])
            .write(to: directory.appendingPathComponent("dock-frames.json"))
        results.append(["state": "dock-transitions", "frames": frames.count, "closingRightEyeSlopes": closingSlopes])
        // Focus and happy both tilt the right eye in the same direction. A
        // detour through idle reverses that tilt while the editor retires.
        guard closingSlopes.count >= 2, closingSlopes.allSatisfy({ $0 < 0.04 }) else {
            throw Failure(description: "Closing eyes detoured through idle: \(closingSlopes)")
        }
    }
    try await observeDockTransitions()
    if CommandLine.arguments.contains("--focus-only") { return }
    let negativeControl = CommandLine.arguments.contains("--negative-control")
    if negativeControl {
        fixture.freezeBlink = true
        try await Task.sleep(for: .milliseconds(350))
    }
    try await observe("collapsed", cycles: negativeControl ? 1 : 2)
    fixture.state.setInputOpen(true)
    try await Task.sleep(for: .milliseconds(600))
    try await observe("expanded")
    fixture.state.setInputOpen(false)
    fixture.running = true
    try await Task.sleep(for: .milliseconds(600))
    try await observe("running")
    fixture.running = false
    fixture.talk = "Moku is talking"
    try await observe("talk-streaming", streaming: true)
    fixture.state.setSearchActive(true)
    try await Task.sleep(for: .seconds(5))
    fixture.state.setSearchActive(false)
    try await Task.sleep(for: .milliseconds(300))
    try await observe("after-search-hidden")
    fixture.phase = .inactive
    window.miniaturize(nil)
    try await Task.sleep(for: .seconds(5))
    window.deminiaturize(nil)
    fixture.phase = .active
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(500))
    try await observe("after-miniaturize")
    fixture.mounted = false
    try await Task.sleep(for: .milliseconds(300))
    fixture.mounted = true
    try await Task.sleep(for: .milliseconds(300))
    try await observe("remounted")
    try JSONSerialization.data(withJSONObject: ["capture": "ScreenCaptureKit own native WindowServer window, no forced drawing",
        "results": results, "windowFrame": NSStringFromRect(window.frame),
        "captureFrame": NSStringFromRect(target.frame)], options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("measurements.json"))
    await fixture.draft.dispose()
    print("Evidence: \(directory.path)")
}
@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var failure: String?
            do { try await replay() } catch { failure = String(describing: error) }
            let success = CommandLine.arguments.contains("--orbit-only")
                ? "production running orbit, pause, three static dots, ownership exits and restart"
                : "production natural blink, state changes, visibility and remount"
            let result: [String: Any] = ["ok": failure == nil, "message": failure ?? success]
            let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.json")
            try! JSONSerialization.data(withJSONObject: result).write(to: url)
            if let failure { print("FAIL \(failure)") }
            exit(failure == nil ? 0 : 1)
        }
    }
}
@main private enum Main {
    static func main() {
        let delegate = Delegate()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
