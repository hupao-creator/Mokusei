import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

/// Shared mounted replay for Overview geometry tests. Cards report their actual
/// rendered frames, so assertions read the presented result rather than a
/// planner target.
@MainActor @Observable
final class OverviewReplayFixture {
    let state: NativeOverviewCanvasState
    let content = NativeOverviewContentStore()
    var scene: String
    var selection: String?
    var size: CGSize
    var visible = true
    var layoutPaused = false
    var reduceMotion = false
    var toolbarBottom: Double
    var hasFilters: Bool
    var bottomReservedHeight: Double = 0
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var appearances: [String: Int] = [:]
    @ObservationIgnored var viewport = CGSize.zero

    init(items: [NativeOverviewItem] = [], scene: String = "replay", selection: String? = "all",
         size: CGSize = .init(width: 1180, height: 780),
         memory: NativeOverviewCameraMemory = .init(), hasFilters: Bool = true,
         toolbarBottom: Double? = nil) {
        self.scene = scene
        self.selection = selection
        self.size = size
        self.hasFilters = hasFilters
        self.toolbarBottom = toolbarBottom
            ?? NativeOverviewWorkspaceView.viewport(in: size, hasFilters: hasFilters, hasDock: false).toolbarBottom
        state = .init(memory: memory)
        content.install(items)
    }

    var items: [NativeOverviewItem] { content.items }
    func install(_ items: [NativeOverviewItem]) { content.install(items) }
    var cameraViewport: NativeOverviewViewport {
        .init(width: size.width, height: size.height,
              toolbarBottom: toolbarBottom, bottomReservedHeight: bottomReservedHeight)
    }
    var usable: NativeOverviewContentRect { NativeOverviewCameraGeometry.framingRegion(cameraViewport) }
    var renderedEnvelope: CGRect { frames.values.reduce(CGRect.null) { $0.union($1) } }
    var worldBounds: CGRect {
        state.presentedPlacements.map(\.cardFrame).reduce(CGRect.null) { $0.union($1) }
    }
    var projectionError: Double {
        guard !state.presentedPlacements.isEmpty else { return 0 }
        let camera = state.camera.liveTransform
        return state.presentedPlacements.map { placement in
            guard let frame = frames[placement.id] else { return Double.infinity }
            let world = placement.cardFrame
            return max(abs(frame.minX - (camera.x + world.minX * camera.scale)),
                       abs(frame.minY - (camera.y + world.minY * camera.scale)),
                       abs(frame.width - world.width * camera.scale),
                       abs(frame.height - world.height * camera.scale))
        }.max() ?? 0
    }
}

struct OverviewReplayCanvas: View {
    let fixture: OverviewReplayFixture
    var body: some View {
        var canvas = NativeOverviewCanvas(
            contentSource: fixture.content, sceneKey: fixture.scene, state: fixture.state,
            selectionID: fixture.selection, toolbarBottom: fixture.toolbarBottom,
            bottomReservedHeight: fixture.bottomReservedHeight,
            visible: fixture.visible, layoutPaused: fixture.layoutPaused,
            cloudAnimationsEnabled: false, interactionPaused: false, resetEpoch: 0,
            revisions: []) { item in
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("overview-replay")) } action: {
                    fixture.frames[item.id] = $0
                }
                .onAppear { fixture.appearances[item.id, default: 0] += 1 }
                .onDisappear { fixture.frames.removeValue(forKey: item.id) }
        }
        canvas.reduceMotionOverride = fixture.reduceMotion
        return canvas
            .coordinateSpace(name: "overview-replay")
            .onGeometryChange(for: CGSize.self) { $0.size } action: { fixture.viewport = $0 }
            .frame(width: fixture.size.width, height: fixture.size.height)
    }
}

@MainActor
enum OverviewReplay {
    static func settle(_ fixture: OverviewReplayFixture, in window: NSWindow,
                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let ids = Set(fixture.items.map(\.id))
        try await SwiftUIReplay.wait {
            fixture.viewport == fixture.size
                && fixture.state.camera.viewport == fixture.cameraViewport
                && !fixture.state.isLayingOut
                && fixture.state.presentedPlacements.map(\.id).sorted() == ids.sorted()
                && fixture.frames.keys.sorted() == ids.sorted()
                && !fixture.state.camera.isAnimating
                && !fixture.state.camera.hasPendingAutomaticFit
                && !fixture.state.camera.hasScheduledMotion
                && fixture.projectionError < 1 / window.backingScaleFactor
        }
    }

    /// FitAll is checked against an independently computed scale from the actual
    /// rendered world envelope, not from the camera's own fit helper.
    static func verifyFitAll(_ fixture: OverviewReplayFixture, in window: NSWindow,
                             sourceLocation: SourceLocation = #_sourceLocation) throws {
        let usable = fixture.usable
        let envelope = fixture.renderedEnvelope
        let world = fixture.worldBounds
        guard !fixture.items.isEmpty, world.width > 0, world.height > 0 else {
            Issue.record("No nonempty geometry to verify", sourceLocation: sourceLocation)
            return
        }
        let tolerance = 1 / window.backingScaleFactor
        let raw = min(usable.width / world.width, usable.height / world.height)
        let expected = max(1, min(NativeOverviewCameraGeometry.scaleCap, raw))
        let transform = fixture.state.camera.liveTransform
        if abs(transform.scale - expected) > 1e-6 {
            Issue.record("scale \(transform.scale) != FitAll \(expected)", sourceLocation: sourceLocation)
        }
        if abs(envelope.midX - (usable.left + usable.width / 2)) > tolerance
            || abs(envelope.midY - (usable.top + usable.height / 2)) > tolerance {
            Issue.record("rendered collection is not centered in the usable viewport", sourceLocation: sourceLocation)
        }
        let allowed = CGRect(x: usable.left, y: usable.top, width: usable.width, height: usable.height)
            .insetBy(dx: -tolerance, dy: -tolerance)
        for (id, frame) in fixture.frames where raw >= 1 && !allowed.contains(frame) {
            Issue.record("card \(id) is outside the usable viewport: \(frame)", sourceLocation: sourceLocation)
        }
        if fixture.projectionError > tolerance {
            Issue.record("rendered cards do not match the camera snapshot", sourceLocation: sourceLocation)
        }
    }

    static func verifyControlsClear(_ fixture: OverviewReplayFixture, in window: NSWindow,
                                   sourceLocation: SourceLocation = #_sourceLocation) throws {
        let content = NativeOverviewCameraGeometry.contentRegion(fixture.cameraViewport)
        let envelope = fixture.renderedEnvelope
        let tolerance = 1 / window.backingScaleFactor
        if (envelope.height <= content.height && (envelope.minY < content.top - tolerance
            || envelope.maxY > content.top + content.height + tolerance))
            || (envelope.width <= content.width && (envelope.minX < content.left - tolerance
            || envelope.maxX > content.left + content.width + tolerance)) {
            Issue.record("rendered collection overlaps persistent controls: \(envelope)", sourceLocation: sourceLocation)
        }
    }
}
