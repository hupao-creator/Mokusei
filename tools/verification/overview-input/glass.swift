// Own-window captures of the shared production glass fixture.
import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiHarnessCodex
import MokuseiHarnessClaude
import MokuseiHarnessPi
import MokuseiHarnessOpenCode
@testable import MokuseiApplications
@testable import MokuseiUI

private struct GlassFailure: Error, CustomStringConvertible { let description: String }

@MainActor private func wait(_ label: String, _ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw GlassFailure(description: "Timed out: \(label)")
}

@MainActor private func captureGlass() async throws {
    let directory = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MokuseiGlassCaptureDirectory") as! String)
    let fixture = GlassFixture()
    fixture.moku.setWindowVisible(true)
    let size = CGSize(width: 1200, height: 760)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: GlassSurface(fixture: fixture))
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
    defer { fixture.moku.setWindowVisible(false); fixture.state.camera.dispose(); window.close() }
    try await wait("five semantic cards") { !fixture.state.isLayingOut && fixture.state.mountedCardIDs.count == 5 && fixture.frames.count == 5 }
    try await wait("production Moku Dock") { fixture.moku.capsuleFrame.size == NativeMokuCapsuleLayout.idleSize }
    let mokuFrame = fixture.moku.capsuleFrame
    let expectedMokuFrame = NativeMokuCapsuleLayout.surface(
        in: NativeMokuCapsuleLayout.frame(in: CGRect(origin: .zero, size: size)),
        expanded: false, height: NativeMokuCapsuleLayout.idleSize.height)
    guard mokuFrame == expectedMokuFrame else {
        throw GlassFailure(description: "Moku Dock must use its production bottom-center seat: \(mokuFrame)")
    }
    fixture.state.camera.setManualTransform(fixture.state.camera.liveTransform)
    try await wait("manual fixed view") { fixture.state.camera.manual && !fixture.state.camera.isAnimating }
    let placements = fixture.state.presentedPlacements, transform = fixture.state.camera.liveTransform
    let appearances = fixture.appearances, snapshots = fixture.state.sceneSnapshotCount
    guard transform.scale >= 0.8, fixture.frames.values.allSatisfy({ CGRect(origin: .zero, size: size).contains($0) }) else {
        throw GlassFailure(description: "Fixture cards must fit at readable scale: \(transform), \(fixture.frames)")
    }
    let content = try await SCShareableContent.currentProcess
    let captureFrames = content.windows.map { "\($0.windowID): \($0.frame)" }
    // ScreenCaptureKit's enumerated frame includes WindowServer framing (one
    // point per edge on macOS 26). Validate the actual content, then exclude
    // framing through ignoreShadowsSingleWindow when capturing.
    guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }),
          window.contentView?.bounds.size == size else {
        throw GlassFailure(description: "Own full-size window unavailable: expected \(window.windowNumber) \(size), AppKit \(window.frame), capture windows \(captureFrames)")
    }
    let filter = SCContentFilter(desktopIndependentWindow: target)
    let config = SCStreamConfiguration()
    config.width = Int(size.width * window.backingScaleFactor); config.height = Int(size.height * window.backingScaleFactor)
    config.ignoreShadowsSingleWindow = true; config.showsCursor = false; config.colorSpaceName = CGColorSpace.sRGB
    var captures: [[String: Any]] = []
    for dark in [false, true] {
        fixture.dark = dark
        for glassWorld in [true, false] {
            fixture.glassWorld = glassWorld
            try await Task.sleep(for: .milliseconds(650))
            guard fixture.appearances == appearances, fixture.state.presentedPlacements == placements,
                  fixture.state.sceneSnapshotCount == snapshots, fixture.state.camera.liveTransform == transform,
                  fixture.state.mountedCardIDs == Set(fixture.items.map(\.id)),
                  fixture.moku.capsuleFrame == mokuFrame else {
                throw GlassFailure(description: "Theme/material changed mounted semantic cards or spatial state")
            }
            let name = "\(dark ? "dark" : "light")-\(glassWorld ? "on" : "off")"
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard image.width == config.width, image.height == config.height else { throw GlassFailure(description: "Invalid capture size") }
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: directory.appendingPathComponent(name + ".png"))
            captures.append(["name": name, "glassWorld": glassWorld, "dark": dark,
                "camera": ["scale": transform.scale, "x": transform.x, "y": transform.y],
                "frames": fixture.frames.mapValues { NSStringFromRect($0) },
                "mokuFrame": NSStringFromRect(mokuFrame),
                "mounted": fixture.state.mountedCardIDs.sorted(), "pixels": [image.width, image.height],
                "contentSize": NSStringFromSize(size), "captureFrame": NSStringFromRect(target.frame)])
        }
    }
    try JSONSerialization.data(withJSONObject: ["captures": captures,
        "components": ["NativeOverviewCanvas", "HarnessThreadCard", "NativeReportCard", "CardPlanLadder", "NativeOverviewChrome", "NativeMokuDock"],
        "limits": "Fixed semantic fixtures and own-window WindowServer screenshots; no runtime, settings controls, physical hover or optical frame pacing."],
        options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("captures.json"))
}

@MainActor private final class GlassDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let result = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MokuseiReplayResult") as! String)
            do {
                try await captureGlass()
                try Data("PASS glass-world production fixture completed\n".utf8).write(to: result)
                exit(0)
            } catch {
                try? Data("FAIL \(error)\n".utf8).write(to: result)
                exit(1)
            }
        }
    }
}

@main private enum GlassMain {
    static func main() {
        prepareReplayEnvironment()
        let delegate = GlassDelegate(), app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.delegate = delegate; app.run()
    }
}
