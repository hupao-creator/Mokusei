import AppKit
import Observation
import ScreenCaptureKit
import MokuseiHarnessCodex
import MokuseiPluginAPI
import SpriteKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .requiresDisplay)
struct NativeOnboardingTagSurfaceTests {
    @Test func mountedSurfacePreservesPlaybackAndReleasesRetiredScenes() async throws {
        let fixture = TagSurfaceFixture()
        let window = SwiftUIReplay.window(TagSurfaceReplay(fixture: fixture), width: 320, height: 180)
        defer { window.orderOut(nil); window.contentView = nil }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { surface(in: root) != nil }
        let firstView = try #require(surface(in: root))
        expectTransparent(firstView)
        let firstScene = fixture.scene
        try await SwiftUIReplay.wait { firstScene.updates > 1 }
        #expect(firstView.scene === firstScene && firstScene.presentations == 1)

        fixture.paused = true
        try await SwiftUIReplay.wait { firstView.isPaused }
        let pausedUpdates = firstScene.updates
        // Once the mounted view acknowledges pause, scene updates must stop.
        try await Task.sleep(for: .milliseconds(100))
        #expect(firstScene.updates == pausedUpdates)
        #expect(surface(in: root) === firstView && firstScene.presentations == 1)

        fixture.paused = false
        try await SwiftUIReplay.wait { !firstView.isPaused && firstScene.updates > pausedUpdates }
        #expect(firstView.scene === firstScene && firstScene.presentations == 1)

        let replacement = TagSurfaceScene()
        fixture.scene = replacement
        try await SwiftUIReplay.wait { firstView.scene === replacement && replacement.updates > 1 }
        expectTransparent(firstView)
        #expect(surface(in: root) === firstView)
        #expect(firstScene.view == nil && replacement.presentations == 1)

        fixture.mounted = false
        try await SwiftUIReplay.wait { surface(in: root) == nil && firstView.scene == nil }
        #expect(replacement.view == nil)
        // Keep the old view alive so this proves detachment stops scene updates,
        // independently of releasing the retired native surface.
        let retiredUpdates = replacement.updates
        try await Task.sleep(for: .milliseconds(100))
        #expect(replacement.updates == retiredUpdates)

        fixture.mounted = true
        try await SwiftUIReplay.wait { surface(in: root) != nil && replacement.updates > retiredUpdates }
        let remountedView = try #require(surface(in: root))
        expectTransparent(remountedView)
        #expect(remountedView !== firstView && remountedView.scene === replacement)
        #expect(replacement.presentations == 2 && firstView.scene == nil)
    }

    @Test func productionAnimationMountsWithoutAnOpaqueFirstFrame() async throws {
        try #require(NSApp?.isRunning == true, "Tag entry capture requires the native AppKit replay owner")
        let fixture = TagAnimationFixture()
        let window = SwiftUIReplay.window(TagAnimationReplay(fixture: fixture), width: 620, height: 300)
        defer { window.orderOut(nil); window.contentView = nil }
        let available = try await SCShareableContent.currentProcess
        let target = try #require(available.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * window.backingScaleFactor)
        config.height = Int(window.frame.height * window.backingScaleFactor)
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        let frames = TagGlassFrames()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "tag-onboarding-first-frame"))
        try await stream.startCapture()
        var visits: [[TagGlassFrames.Sample]] = []
        var visitEvents: [[String: Any]] = []
        var captureFailure: (any Error)?
        do {
            try await SwiftUIReplay.wait { frames.ready }
            _ = frames.take()
            for visit in 0..<3 {
                fixture.appearedAt = nil
                let applicationActive = NSApp.isActive
                let windowKey = window.isKeyWindow
                let windowVisible = window.isVisible
                let windowUnoccluded = window.occlusionState.contains(.visible)
                let mountBefore = ProcessInfo.processInfo.systemUptime
                fixture.mounted = true
                let mountAfter = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .milliseconds(400))
                let drainBefore = ProcessInfo.processInfo.systemUptime
                let samples = frames.takeSamples()
                let drainAfter = ProcessInfo.processInfo.systemUptime
                visits.append(samples)
                visitEvents.append(["visit": visit, "mountBefore": mountBefore, "mountAfter": mountAfter,
                    "appearanceAt": fixture.appearedAt.map { $0 as Any } ?? NSNull(),
                    "drainBefore": drainBefore, "drainAfter": drainAfter, "completeFrames": samples.count,
                    "applicationActiveAtInput": applicationActive, "windowKeyAtInput": windowKey,
                    "windowVisibleAtInput": windowVisible, "windowOcclusionVisibleAtInput": windowUnoccluded])
                try #require(samples.count >= 2, "Missing intermediate WindowServer frames during Tag entry")
                fixture.mounted = false
                try await Task.sleep(for: .milliseconds(100))
                _ = frames.take()
            }
            try await stream.stopCapture()
        } catch {
            try? await stream.stopCapture()
            captureFailure = error
        }
        let root = ProcessInfo.processInfo.environment["MOKUSEI_READING_MOTION_ARTIFACTS"]
            ?? ProcessInfo.processInfo.environment["MOKUSEI_CI_EVIDENCE"]
        let directory = root.map { URL(fileURLWithPath: $0).appendingPathComponent("tag-first-frame") }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        if let directory {
            try JSONSerialization.data(withJSONObject: visitEvents, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("visit-events.json"))
        }
        for (visit, samples) in visits.enumerated() {
            for (index, sample) in samples.enumerated() {
                let image = sample.image
                // Inspect the central animation area, not view properties or a
                // settled screenshot. The original SpriteView fills this region
                // with a light rectangle for one frame before its first drawable.
                let data = try #require(image.dataProvider?.data)
                let bytes = try #require(CFDataGetBytePtr(data))
                var bright = 0, sampled = 0
                for y in (image.height / 4)..<(image.height * 3 / 4) {
                    for x in (image.width / 5)..<(image.width * 4 / 5) {
                        let offset = y * image.bytesPerRow + x * 4
                        if min(bytes[offset], bytes[offset + 1], bytes[offset + 2]) > 153 { bright += 1 }
                        sampled += 1
                    }
                }
                if let directory {
                    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try png.write(to: directory.appendingPathComponent("visit-\(visit)-frame-\(index).png"))
                }
                #expect(Double(bright) / Double(sampled) < 0.5,
                        "Tag entry exposed an opaque light surface before its first frame")
            }
            if let directory {
                let times = samples.map { ["receivedAt": $0.receivedAt, "presentationTime": $0.presentationTime] }
                try JSONSerialization.data(withJSONObject: times, options: .prettyPrinted)
                    .write(to: directory.appendingPathComponent("visit-\(visit)-times.json"))
            }
        }
        if let captureFailure { throw captureFailure }
        print("TAG_ONBOARDING_FIRST_FRAME_CONFIRMED")
    }

    private func surface(in view: NSView) -> SKView? {
        if let surface = view as? SKView { return surface }
        return view.subviews.lazy.compactMap { surface(in: $0) }.first
    }

    private func expectTransparent(_ view: SKView) {
        #expect(view.allowsTransparency && !view.isOpaque)
        #expect(view.layer?.isOpaque == false)
        #expect(view.layer?.backgroundColor?.alpha == 0)
    }
}

@MainActor @Observable private final class TagSurfaceFixture {
    var scene = TagSurfaceScene()
    var paused = false
    var mounted = true
}

private struct TagSurfaceReplay: View {
    let fixture: TagSurfaceFixture
    var body: some View {
        ZStack {
            Color.gray
            if fixture.mounted {
                NativeOnboardingTagSurface(scene: fixture.scene, isPaused: fixture.paused)
            }
        }
    }
}

@MainActor private final class TagSurfaceScene: SKScene {
    private(set) var updates = 0
    private(set) var presentations = 0

    override init() {
        super.init(size: CGSize(width: 320, height: 180))
        backgroundColor = .clear
        scaleMode = .resizeFill
    }

    required init?(coder: NSCoder) { fatalError("Test scenes are created in code") }
    override func update(_ currentTime: TimeInterval) { updates += 1 }
    override func didMove(to view: SKView) { presentations += 1 }
}

@MainActor @Observable private final class TagAnimationFixture {
    var mounted = false
    var started = false
    @ObservationIgnored var appearedAt: TimeInterval?
}

private struct TagAnimationReplay: View {
    @Bindable var fixture: TagAnimationFixture
    var body: some View {
        ZStack {
            Color(white: 0.2)
            if fixture.mounted {
                NativeOnboardingTagAnimation(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], locale: .chinese,
                                             visitPlaybackStarted: $fixture.started)
                    .frame(width: 560, height: 250)
                    .onAppear { fixture.appearedAt = ProcessInfo.processInfo.systemUptime }
            }
        }
        .overlay(alignment: .bottomLeading) {
            // A clock outside the sampled animation region keeps WindowServer
            // delivering complete frames even when Tag's final scene is paused.
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                Color(white: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1))
                    .frame(width: 8, height: 8)
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.scenePhase, .active)
    }
}
