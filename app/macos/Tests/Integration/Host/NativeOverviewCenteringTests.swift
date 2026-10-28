import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Observable private final class CenteringFixture {
    let state: NativeOverviewCanvasState
    var size: CGSize
    var visible = true
    var items: [NativeOverviewItem]
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var appearances: [String: Int] = [:]
    @ObservationIgnored var viewport = CGSize.zero

    init(size: CGSize, count: Int, memory: NativeOverviewCameraMemory = .init()) {
        state = NativeOverviewCanvasState(memory: memory)
        self.size = size
        items = (0..<count).map { .init(id: "center-\($0)") }
    }
    func cameraViewport(_ size: CGSize) -> NativeOverviewViewport {
        NativeOverviewWorkspaceView.viewport(in: size, hasFilters: true, hasDock: true)
    }
}

private struct CenteringCanvas: View {
    let fixture: CenteringFixture
    var constrained = true
    var body: some View {
        GeometryReader { geometry in
            let viewport = fixture.cameraViewport(geometry.size)
            NativeOverviewCanvas(items: fixture.items, sceneKey: "centering", state: fixture.state,
                toolbarBottom: viewport.toolbarBottom, bottomReservedHeight: viewport.bottomReservedHeight,
                visible: fixture.visible) { item in
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("centering")) } action: {
                        fixture.frames[item.id] = $0
                    }
                    .onAppear { fixture.appearances[item.id, default: 0] += 1 }
            }
        }
        .coordinateSpace(name: "centering")
        .onGeometryChange(for: CGSize.self) { $0.size } action: { fixture.viewport = $0 }
        .frame(width: constrained ? fixture.size.width : nil, height: constrained ? fixture.size.height : nil)
    }
}

/// Assert the rendered collection, not just the camera's target transform.
/// Whole collections share the usable center, including symmetric overflow.
@MainActor @Suite(.serializedNative, .serialized)
struct NativeOverviewCenteringTests {
    @Test(.requiresDisplay) func screenshotMixedFootprintsBalanceBothControlsAndRestoreAfterExtensionChanges() async throws {
        let fixture = CenteringFixture(size: .init(width: 1292, height: 858), count: 6)
        // Screenshot: one 2×2 execution/extension card, one ordinary thread,
        // and four standard report footprints fill a 3×3 envelope.
        fixture.items[0].columns = 2
        fixture.items[0].rows = 2
        fixture.items[0].carouselEligible = true
        let window = SwiftUIReplay.window(CenteringCanvas(fixture: fixture), width: 1400, height: 950)
        defer { window.close() }
        try await settle(fixture, in: window)
        try verifyClearance(fixture, in: window)
        let envelope = fixture.frames.values.reduce(CGRect.null) { $0.union($1) }
        #expect(abs(envelope.minY - 103) < 1 / window.backingScaleFactor)
        #expect(abs(envelope.maxY - 735) < 1 / window.backingScaleFactor)
        #expect(fixture.state.camera.transform.scale == 1)
        let appearances = fixture.appearances
        for extent in [(2, 2), (2, 1), (1, 1)] {
            fixture.items[1].columns = extent.0
            fixture.items[1].rows = extent.1
            try await settle(fixture, in: window)
            fixture.state.camera.pan(deltaX: -170, deltaY: 230)
            fixture.state.camera.returnToAuto()
            try await settle(fixture, in: window)
            try verifyClearance(fixture, in: window)
        }
        #expect(fixture.appearances == appearances)
    }

    @Test(.requiresDisplay) func dockReservationRePacksThePreviousFiveCardCaseWithoutFalseCarousel() async throws {
        let fixture = CenteringFixture(size: .init(width: 1292, height: 858), count: 5)
        for index in 0..<2 {
            fixture.items[index].columns = 2
            fixture.items[index].rows = 2
            fixture.items[index].carouselEligible = true
        }
        let window = SwiftUIReplay.window(CenteringCanvas(fixture: fixture), width: 1400, height: 950)
        defer { window.close() }
        try await settle(fixture, in: window)
        try verifyClearance(fixture, in: window)
        // The old 3×4 envelope misses the Dock by 2.8pt at readable scale.
        // A 4×3 packing is a real fitting witness; inset preference must yield.
        #expect(fixture.state.presentedPlacements.map { $0.column + $0.columns }.max() == 4)
        #expect(fixture.state.presentedPlacements.map { $0.row + $0.rows }.max() == 3)
        fixture.size = .init(width: 860, height: 600)
        try await settle(fixture, in: window)
        #expect(fixture.state.camera.carouselTargetID != nil)
        fixture.size = .init(width: 1292, height: 858)
        try await settle(fixture, in: window)
        try verifyClearance(fixture, in: window)
    }

    @Test(.requiresDisplay, arguments: [CGSize(width: 500, height: 600), CGSize(width: 620, height: 600),
                      CGSize(width: 621, height: 600), CGSize(width: 860, height: 600), CGSize(width: 1180, height: 780),
                      CGSize(width: 2560, height: 1440)])
    func renderedCollectionCentersInAvailableRegion(size: CGSize) async throws {
        for count in [1, 3, 16] {
            let fixture = CenteringFixture(size: size, count: count)
            let window = SwiftUIReplay.window(CenteringCanvas(fixture: fixture), width: size.width, height: size.height)
            defer { window.close() }
            try await settle(fixture, in: window)
            try verify(fixture, in: window)
        }
    }

    @Test(.requiresDisplay) func explicitReturnAndDeferredRecoveryRestoreRenderedComposition() async throws {
        let fixture = CenteringFixture(size: .init(width: 1180, height: 780), count: 16)
        let window = SwiftUIReplay.window(CenteringCanvas(fixture: fixture))
        defer { window.close() }
        try await settle(fixture, in: window)
        for suspension in ["none", "interaction", "hidden"] {
            fixture.state.camera.setManualTransform(.init(scale: 1.2, x: -500, y: 350))
            if suspension == "interaction" {
                fixture.state.beginInteraction(cardID: "center-0")
            } else if suspension == "hidden" {
                fixture.visible = false
                fixture.state.camera.setVisible(false)
            }
            fixture.state.camera.returnToAuto()
            fixture.state.endInteraction(cardID: "center-0")
            fixture.visible = true
            fixture.state.camera.setVisible(true)
            try await SwiftUIReplay.wait { fixture.state.camera.isAnimating }
            try await settle(fixture, in: window)
            #expect(!fixture.state.camera.manual)
            try verify(fixture, in: window)
        }
    }

    @Test(.requiresDisplay) func resizingReframesActualCardsWithoutReplacingThem() async throws {
        _ = NSApplication.shared
        let fixture = CenteringFixture(size: .init(width: 1180, height: 780), count: 16)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: fixture.size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CenteringCanvas(fixture: fixture, constrained: false))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle(fixture, in: window)
        let appearances = fixture.appearances
        let screen = try #require(window.screen)
        let frameInset = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let tallHeight = min(1000, floor(screen.visibleFrame.height - frameInset) - 1)
        // Production minimum, a tall window, and the default size. Unlike the
        // compact component cases, this changes the actual native content area.
        // AppKit constrains real window height to the current screen's work area.
        for size in [CGSize(width: 860, height: 600), CGSize(width: 860, height: tallHeight), CGSize(width: 1180, height: 780)] {
            fixture.size = size
            window.setContentSize(size)
            try await SwiftUIReplay.wait { fixture.viewport == size }
            // Refit is deliberately coalesced; settle must include the actual
            // submitted motion, rather than accepting the previous idle frame.
            try await SwiftUIReplay.wait { fixture.state.camera.isAnimating }
            try await settle(fixture, in: window)
            try verify(fixture, in: window)
            #expect(fixture.appearances == appearances)
        }
    }

    @Test(.requiresDisplay, arguments: [false, true])
    func bookmarkRestoresAutomaticCompositionOrKeepsManualView(manual: Bool) async throws {
        let saved = NativeOverviewTransform(scale: 1.2, x: -500, y: 350)
        let fixture = CenteringFixture(size: .init(width: 1180, height: 780), count: 16,
            memory: .init(current: (sceneKey: "centering", view: .init(transform: saved, manual: manual))))
        let window = SwiftUIReplay.window(CenteringCanvas(fixture: fixture))
        defer { window.close() }
        try await settle(fixture, in: window)
        #expect(fixture.state.camera.manual == manual)
        if manual { #expect(fixture.state.camera.transform == saved) }
        else { try verify(fixture, in: window) }
    }

    @Test func translatedContentKeepsTheSameAvailableRegionCenter() {
        for size in [CGSize(width: 500, height: 600), CGSize(width: 1180, height: 780), CGSize(width: 2560, height: 1440)] {
            let viewport = NativeOverviewViewport(width: size.width, height: size.height, toolbarBottom: 58)
            for origin in [CGPoint.zero, CGPoint(x: -752, y: -432), CGPoint(x: 1128, y: 648)] {
                for extent in [CGSize(width: 360, height: 200), CGSize(width: 2240, height: 1280),
                               CGSize(width: 360, height: 1280), CGSize(width: 2240, height: 200)] {
                    let content = NativeOverviewContentRect(left: origin.x, top: origin.y, width: extent.width, height: extent.height)
                    let fitted = NativeOverviewCameraGeometry.fit(content, viewport: viewport)
                    let region = NativeOverviewCameraGeometry.framingRegion(viewport)
                    #expect(abs(fitted.x + (content.left + content.width / 2) * fitted.scale - size.width / 2) < 1e-6)
                    let expectedY = region.top + region.height / 2
                    #expect(abs(fitted.y + (content.top + content.height / 2) * fitted.scale - expectedY) < 1e-6)
                }
            }
        }
    }

    private func settle(_ fixture: CenteringFixture, in window: NSWindow) async throws {
        try await SwiftUIReplay.wait {
            fixture.viewport == fixture.size && fixture.state.camera.viewport == fixture.cameraViewport(fixture.viewport) &&
            fixture.state.presentedPlacements.count == fixture.items.count && !fixture.state.isLayingOut &&
            !fixture.state.camera.isAnimating && !fixture.state.camera.returning &&
            !fixture.state.camera.hasScheduledMotion &&
            Set(fixture.state.presentedPlacements.map(\.member)) == Set(fixture.items.map(\.member)) &&
            fixture.frames.count == fixture.items.count && projectionError(fixture) < 1 / window.backingScaleFactor
        }
    }

    private func projectionError(_ fixture: CenteringFixture) -> Double {
        let camera = fixture.state.camera.liveTransform
        return fixture.state.presentedPlacements.map { placement in
            guard let frame = fixture.frames[placement.id] else { return Double.infinity }
            let world = placement.cardFrame
            return max(abs(frame.minX - (camera.x + world.minX * camera.scale)),
                       abs(frame.minY - (camera.y + world.minY * camera.scale)),
                       abs(frame.width - world.width * camera.scale), abs(frame.height - world.height * camera.scale))
        }.max() ?? .infinity
    }

    private func verify(_ fixture: CenteringFixture, in window: NSWindow) throws {
        let measured = fixture.frames.values.reduce(CGRect.null) { $0.union($1) }
        let viewport = fixture.cameraViewport(fixture.viewport)
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        let expectedX = viewport.width / 2
        let expectedY = region.top + region.height / 2
        print("CENTERING viewport=\(fixture.viewport) toolbar=\(viewport.toolbarBottom) count=\(fixture.items.count) " +
              "scale=\(fixture.state.camera.transform.scale) measured=\(measured) " +
              "centerError=(\(measured.midX - expectedX),\(measured.midY - expectedY)) projectionError=\(projectionError(fixture))")
        #expect(abs(measured.midX - expectedX) < 1 / window.backingScaleFactor)
        #expect(abs(measured.midY - expectedY) < 1 / window.backingScaleFactor)
    }

    private func verifyClearance(_ fixture: CenteringFixture, in window: NSWindow) throws {
        try verify(fixture, in: window)
        let envelope = fixture.frames.values.reduce(CGRect.null) { $0.union($1) }
        let viewport = fixture.cameraViewport(fixture.viewport)
        let dock = NativeMokuCapsuleLayout.idleSurface(in: CGRect(origin: .zero, size: fixture.viewport))
        let above = envelope.minY - viewport.toolbarBottom
        let below = dock.minY - envelope.maxY
        print("CONTROL-GAPS viewport=\(fixture.viewport) above=\(above) below=\(below) bounds=\(envelope)")
        #expect(above >= -1 / window.backingScaleFactor && below >= -1 / window.backingScaleFactor)
        // Preserve the original one-physical-pixel Retina tolerance on 1x CI displays.
        #expect(abs(above - below) < 1 / window.backingScaleFactor)
        #expect(envelope.minX >= -1 / window.backingScaleFactor && envelope.maxX <= fixture.viewport.width + 1 / window.backingScaleFactor)
        #expect(fixture.state.camera.carouselTargetID == nil)
        #expect(fixture.state.camera.transform.scale >= fixture.state.camera.minimumScale)
    }
}
