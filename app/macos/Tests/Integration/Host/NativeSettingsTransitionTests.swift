import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiPluginUI
import MokuseiUI

@MainActor @Observable private final class SettingsTransitionFixture {
    let scene = NativeMokuSceneState()
    var phase: ScenePhase = .active
    var size = CGSize(width: 800, height: 600)
    var pageSize = CGSize.zero
    var backRect = CGRect.zero
    var appearances = 0
    var disappearances = 0
    var outsideAppearances = 0
}

private struct SettingsTransitionReplay: View {
    let fixture: SettingsTransitionFixture
    var scale = 1.0
    var body: some View {
        GeometryReader { _ in replay }
    }
    private var replay: some View {
        NativeMokuScene(state: fixture.scene) {
            Color(.sRGB, red: 1, green: 0, blue: 0).onAppear { fixture.outsideAppearances += 1 }
        } thread: { Color.green } dock: { EmptyView() } settings: {
            if fixture.scene.settingsOpen {
                Color(.sRGB, red: 0, green: 0, blue: 1)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { fixture.pageSize = $0 }
                    .onAppear { fixture.appearances += 1 }
                    .onDisappear { fixture.disappearances += 1 }
                    .overlay(alignment: .topLeading) {
                        NativeWindowNavigationView(action: ThreadDetailBackAction(label: "Back", onBack: {}),
                            onBackFrameChange: { fixture.backRect = $0 })
                    }
            }
        }
        .frame(width: fixture.size.width / scale, height: fixture.size.height / scale)
        .coordinateSpace(name: "workspace")
        .environment(\.nativeWindowContentScale, scale)
        .scaleEffect(scale, anchor: .topLeading)
        .environment(\.scenePhase, fixture.phase)
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeSettingsTransitionTests {
    private func pixels(_ window: NSWindow) throws -> NSBitmapImageRep {
        let root = try #require(window.contentView)
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        return bitmap
    }
    private func color(_ bitmap: NSBitmapImageRep, x: Double, y: Double) throws -> NSColor {
        try #require(bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * x),
            y: Int(Double(bitmap.pixelsHigh) * y))?.usingColorSpace(.sRGB))
    }

    @Test func anchoredRevealUsesACircleWithoutScalingThePage() async throws {
        var physicalBackRect: CGRect?
        for scale in [1.0, 2.0] {
            let fixture = SettingsTransitionFixture()
            let window = SwiftUIReplay.window(SettingsTransitionReplay(fixture: fixture, scale: scale), width: 800, height: 600)
            defer { window.close() }
            try await SwiftUIReplay.wait { fixture.scene.windowVisible }
            fixture.scene.openSettings(origin: CGRect(x: 590 / scale, y: 90 / scale, width: 20 / scale, height: 20 / scale))
            #expect(fixture.scene.settingsTransitioning)
            var sawReveal = false
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline && fixture.scene.settingsTransitioning {
                let bitmap = try pixels(window)
                let center = try color(bitmap, x: 0.75, y: 1.0 / 6)
                let far = try color(bitmap, x: 0.05, y: 0.9)
                // Compare channel contrast rather than pure RGB endpoints:
                // the window's display color profile also transforms fixtures.
                if center.blueComponent > 0.9 && center.redComponent < 0.15
                    && far.redComponent - far.blueComponent > 0.65 {
                    sawReveal = true
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(sawReveal, "Expected an opaque Settings source and an unrevealed Overview corner")
            #expect(fixture.pageSize == CGSize(width: 800 / scale, height: 600 / scale))
            #expect(fixture.scene.settingsOpen && !fixture.scene.settingsTransitioning)
            let complete = try color(pixels(window), x: 0.05, y: 0.9)
            #expect(complete.blueComponent > 0.9)
            let backRect = fixture.backRect.applying(CGAffineTransform(scaleX: scale, y: scale))
            #expect(!backRect.isEmpty)
            if let physicalBackRect {
                #expect(abs(backRect.minX - physicalBackRect.minX) < 1)
                #expect(abs(backRect.minY - physicalBackRect.minY) < 1)
                #expect(abs(backRect.width - physicalBackRect.width) < 1)
            } else { physicalBackRect = backRect }
            fixture.scene.closeSettings(origin: fixture.backRect)
            #expect(fixture.scene.settingsOpen && fixture.scene.settingsClosing && fixture.scene.settingsTransitioning)
            try await Task.sleep(for: .milliseconds(100))
            #expect(fixture.scene.settingsOpen && fixture.disappearances == 0)
            try await SwiftUIReplay.wait { !fixture.scene.settingsOpen && fixture.disappearances == 1 }
            #expect(fixture.outsideAppearances == 1 && fixture.appearances == 1)
        }
    }

    @Test func reverseResizeAndInactiveSceneRetireObsoleteCompletions() async throws {
        let fixture = SettingsTransitionFixture()
        let window = SwiftUIReplay.window(SettingsTransitionReplay(fixture: fixture), width: 800, height: 600)
        defer { window.close() }
        try await SwiftUIReplay.wait { fixture.scene.windowVisible }
        let origin = CGRect(x: 680, y: 20, width: 30, height: 30)
        fixture.scene.openSettings(origin: origin)
        try await Task.sleep(for: .milliseconds(100))
        fixture.scene.closeSettings()
        try await Task.sleep(for: .milliseconds(100))
        fixture.scene.openSettings(origin: origin)
        try await SwiftUIReplay.wait { !fixture.scene.settingsTransitioning }
        try await Task.sleep(for: .milliseconds(500))
        #expect(fixture.scene.settingsOpen && fixture.disappearances == 0 && fixture.appearances == 1)
        fixture.scene.closeSettings()
        fixture.size = CGSize(width: 700, height: 500)
        try await SwiftUIReplay.wait { !fixture.scene.settingsOpen }
        fixture.scene.openSettings(origin: origin)
        fixture.phase = .inactive
        try await SwiftUIReplay.wait { !fixture.scene.settingsTransitioning }
        #expect(fixture.scene.settingsOpen)
        fixture.scene.closeSettings()
        try await SwiftUIReplay.wait { !fixture.scene.settingsOpen }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!fixture.scene.settingsOpen && !fixture.scene.settingsClosing)
    }

    @Test func unanchoredRouteAndExplicitSettleStillClose() async throws {
        let fixture = SettingsTransitionFixture()
        let window = SwiftUIReplay.window(SettingsTransitionReplay(fixture: fixture), width: 800, height: 600)
        defer { window.close() }
        try await SwiftUIReplay.wait { fixture.scene.windowVisible }
        fixture.scene.openSettings()
        try await SwiftUIReplay.wait { fixture.appearances == 1 && !fixture.scene.settingsTransitioning }
        let complete = try color(pixels(window), x: 0.05, y: 0.9)
        #expect(complete.blueComponent > 0.9)
        fixture.scene.closeSettings()
        try await SwiftUIReplay.wait { !fixture.scene.settingsOpen }
        fixture.scene.openSettings(origin: CGRect(x: 700, y: 20, width: 30, height: 30))
        try await SwiftUIReplay.wait { fixture.appearances == 2 }
        fixture.scene.settle()
        #expect(fixture.scene.settingsOpen && !fixture.scene.settingsTransitioning)
        fixture.scene.closeSettings()
        fixture.scene.settle()
        #expect(!fixture.scene.settingsOpen && !fixture.scene.settingsTransitioning)
        fixture.scene.openSettings()
        fixture.scene.closeSettings() // Both intents precede SwiftUI's next frame.
        try await SwiftUIReplay.wait { !fixture.scene.settingsOpen }
        #expect(!fixture.scene.settingsTransitioning)
    }
}
