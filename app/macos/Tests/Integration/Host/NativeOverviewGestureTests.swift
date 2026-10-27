import AppKit
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativeOverviewGestureTests {
    @Test func preciseDiagonalsAreScreenPointsIndependentOfCameraScale() throws {
        for windowZoom in [0.5, 1.0, 2.0] {
            let delta = try #require(NativeOverviewScrollGeometry.delta(x: 0.125, y: -3.75, precise: true,
                shift: true, canvasPerWindowPoint: .init(width: 1 / windowZoom, height: 1 / windowZoom)))
            for scale in [0.85, 1.7] {
                let before = NativeOverviewTransform(scale: scale, x: -50, y: 17)
                let after = NativeOverviewCameraGeometry.pan(before, deltaX: delta.width, deltaY: delta.height)
                #expect(abs((after.x - before.x) * windowZoom - 0.125) < 1e-9)
                #expect(abs((after.y - before.y) * windowZoom + 3.75) < 1e-9)
                #expect(after.scale == scale)
            }
        }
        #expect(NativeOverviewScrollGeometry.delta(x: .nan, y: 1, precise: true, shift: false,
            canvasPerWindowPoint: .init(width: 1, height: 1)) == nil)
        #expect(NativeOverviewScrollGeometry.delta(x: 0, y: 1, precise: true, shift: false,
            canvasPerWindowPoint: .zero) == nil)
        #expect(NativeOverviewScrollGeometry.delta(x: 0, y: 2, precise: false, shift: true,
            canvasPerWindowPoint: .init(width: 1, height: 1)) == CGSize(width: 80, height: 0))
        #expect(NativeOverviewScrollGeometry.delta(x: 1, y: 2, precise: false, shift: true,
            canvasPerWindowPoint: .init(width: 1, height: 1)) == CGSize(width: 40, height: 80))
    }

    @Test func invalidPanDoesNotTakeOverAndOverflowDoesNotCorruptCamera() {
        let camera = NativeOverviewCamera()
        camera.cutTo(content: .init(left: 0, top: 0, width: 360, height: 200),
                     viewport: .init(width: 1180, height: 780, toolbarBottom: 58))
        defer { camera.dispose() }
        let automatic = camera.liveTransform
        camera.pan(deltaX: .nan, deltaY: 1)
        #expect(!camera.manual && camera.liveTransform == automatic)
        camera.setManualTransform(.init(scale: 1, x: .greatestFiniteMagnitude, y: 1))
        let manual = camera.liveTransform
        camera.pan(deltaX: .greatestFiniteMagnitude, deltaY: 1)
        #expect(camera.liveTransform == manual)
    }

    @Test func panTakesOverTheVisibleAnimationRatherThanItsDestination() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.cutTo(content: .init(left: 0, top: 0, width: 4000, height: 3000),
                     viewport: .init(width: 1180, height: 780, toolbarBottom: 58))
        camera.setCarouselCards([.init(id: "far", rect: .init(left: 0, top: 0, width: 360, height: 200), eligible: true)])
        for _ in 0..<100 {
            if camera.isAnimating { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(camera.isAnimating)
        let destination = camera.transform
        // Sample immediately around the gesture: assertion diagnostics can
        // take milliseconds while this real-time animation keeps advancing.
        let visible = camera.liveTransform
        camera.pan(deltaX: 3, deltaY: -4)
        let taken = camera.liveTransform
        #expect(abs(destination.x - visible.x) > 100)
        #expect(abs(taken.x - visible.x - 3) < 2)
        #expect(abs(taken.y - visible.y + 4) < 2)
        #expect(camera.manual && !camera.isAnimating && camera.carouselTargetID == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(camera.liveTransform == taken)
    }

    @Test func sequenceRetainsCanvasOrNativeOwnerThroughMomentumAndPointerMovement() {
        for owner in [NativeOverviewScrollSequence.Owner.canvas, .native] {
            var sequence = NativeOverviewScrollSequence()
            #expect(sequence.route(phase: .mayBegin, momentum: [], hasDelta: false, candidate: owner, now: 1) == nil)
            #expect(sequence.owner == nil)
            #expect(sequence.route(phase: .changed, momentum: [], hasDelta: true, candidate: owner, now: 1.01) == owner)
            #expect(sequence.route(phase: .changed, momentum: [], hasDelta: true, candidate: .native, now: 1.02) == owner)
            #expect(sequence.route(phase: .ended, momentum: [], hasDelta: false, candidate: .native, now: 1.03) == owner)
            #expect(sequence.route(phase: [], momentum: .began, hasDelta: true, candidate: .native, now: 1.04) == owner)
            #expect(sequence.route(phase: [], momentum: .ended, hasDelta: false, candidate: .native, now: 1.05) == owner)
            #expect(sequence.owner == nil)
            #expect(sequence.route(phase: [], momentum: .changed, hasDelta: true, candidate: .canvas, now: 1.06) == nil)
        }
    }

    @Test func interruptionDiscardsOldMomentumAndWheelNeverLatches() {
        var sequence = NativeOverviewScrollSequence()
        _ = sequence.route(phase: .began, momentum: [], hasDelta: true, candidate: .canvas, now: 1)
        sequence.interrupt()
        #expect(sequence.route(phase: [], momentum: .changed, hasDelta: true, candidate: .canvas, now: 1.01) == .discarded)
        #expect(sequence.route(phase: .began, momentum: [], hasDelta: true, candidate: .native, now: 1.02) == .native)
        #expect(sequence.route(phase: [], momentum: [], hasDelta: true, candidate: .canvas, now: 1.03) == .canvas)
        #expect(sequence.owner == nil)
        #expect(sequence.route(phase: [], momentum: [], hasDelta: true, candidate: .native, now: 1.04) == .native)
        _ = sequence.route(phase: .began, momentum: [], hasDelta: true, candidate: .canvas, now: 2)
        _ = sequence.route(phase: .ended, momentum: [], hasDelta: false, candidate: .canvas, now: 2.01)
        #expect(sequence.route(phase: [], momentum: .began, hasDelta: true, candidate: .canvas, now: 3) == nil)
        #expect(sequence.owner == nil)
    }

    @Test func incrementalPinchPreservesOffCenterWorldAnchorAndImmediatelyReversesAtLimits() throws {
        let anchor = CGPoint(x: 837, y: 326)
        var transform = NativeOverviewTransform(scale: 1, x: -137, y: 81)
        let world = CGPoint(x: (anchor.x - transform.x) / transform.scale, y: (anchor.y - transform.y) / transform.scale)
        var samples = NativeOverviewPinchSamples()
        for cumulative in [1.1, 1.8, 4.0, 3.9, 0.5, 0.2, 0.21] {
            let before = transform
            let nextRatio = samples.ratio(cumulative)
            let ratio = try #require(nextRatio)
            transform = NativeOverviewCameraGeometry.zoom(transform, cursor: anchor,
                nextScale: min(1.7, transform.scale * ratio), minimumScale: 0.85)
            #expect(abs((anchor.x - transform.x) / transform.scale - world.x) < 1e-6)
            #expect(abs((anchor.y - transform.y) / transform.scale - world.y) < 1e-6)
            if cumulative == 3.9 { #expect(transform.scale < before.scale) }
            if cumulative == 0.21 { #expect(transform.scale > before.scale) }
        }
        #expect(samples.ratio(0) == nil)
        #expect(samples.ratio(.infinity) == nil)
        #expect(samples.previous == 0.21)
    }
}
