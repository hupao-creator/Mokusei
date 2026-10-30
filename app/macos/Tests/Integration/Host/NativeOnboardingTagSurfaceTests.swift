import AppKit
import Observation
import SpriteKit
import SwiftUI
import Testing
import MokuseiTestSupport
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
        #expect(firstView.isPaused && replacement.view == nil)
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

    private func surface(in view: NSView) -> SKView? {
        if let surface = view as? SKView { return surface }
        return view.subviews.lazy.compactMap { surface(in: $0) }.first
    }

    private func expectTransparent(_ view: SKView) {
        #expect(view.allowsTransparency && !view.isOpaque)
        #expect(!view.isAsynchronous)
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
