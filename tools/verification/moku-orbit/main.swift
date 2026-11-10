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
                    .environment(\.scenePhase, fixture.phase)
            }
        } settings: { Color.white }
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
        .environment(\.nativeMokuTheme, .opencode)
        .environment(\.colorScheme, .light)
    }
}
private func png(_ image: CGImage, _ url: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
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
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/mokusei-moku-orbit-evidence")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = Fixture()
    let host = NSHostingView(rootView: Scene(fixture: fixture))
    let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 900, height: 480),
        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    // Keep this auxiliary fixture out of Stage Manager's app-switch transforms.
    window.level = .floating
    window.title = "Production Moku orbit regression replay"
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
    do {
        func character(in view: NSView) -> NativeMokuCharacterMotion? {
            if let canvas = view as? NativeMokuCharacterCanvas, canvas.seat == .decorations { return canvas.controller }
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
}
@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var failure: String?
            do { try await replay() } catch { failure = String(describing: error) }
            let success = "production running orbit, pause, three static dots, ownership exits and restart"
            let result: [String: Any] = ["ok": failure == nil, "message": failure ?? success]
            let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.json")
            try! JSONSerialization.data(withJSONObject: result).write(to: url)
            if let failure { print("FAIL \(failure)") }
            exit(failure == nil ? 0 : 1)
        }
    }
}
@main private enum Main {
    static func main() throws {
        try prepareIsolatedNativeReplay()
        let delegate = Delegate()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
