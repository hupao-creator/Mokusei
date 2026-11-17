import CoreGraphics
import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor
@Suite(.serializedNative, .serialized)
struct NativeOverviewCameraTests {
    private let metrics = NativeOverviewGridMetrics.standard
    private let viewport = NativeOverviewViewport(width: 1180, height: 780, toolbarBottom: NativeOverviewViewportDefaults.toolbarBottom)
    private let content = NativeOverviewContentRect(left: 0, top: 0, width: NativeOverviewGridMetrics.standard.width(columns: 2),
                                                     height: NativeOverviewGridMetrics.standard.height(rows: 2))
    private let large = NativeOverviewContentRect(left: 0, top: 0, width: NativeOverviewGridMetrics.standard.width(columns: 6),
                                                   height: NativeOverviewGridMetrics.standard.height(rows: 6))

    @Test func fitAllIsCappedAndCentered() throws {
        let fitted = try #require(NativeOverviewCameraGeometry.fit(content, viewport: viewport))
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        let raw = min(region.width / content.width, region.height / content.height)
        let expectedScale = max(1, min(NativeOverviewCameraGeometry.scaleCap, raw))
        #expect(abs(fitted.scale - expectedScale) < 1e-9)
        let center = CGPoint(x: region.left + region.width / 2, y: region.top + region.height / 2)
        #expect(abs(fitted.x + content.width * fitted.scale / 2 - center.x) < 1e-6)
        #expect(abs(fitted.y + content.height * fitted.scale / 2 - center.y) < 1e-6)
        let uncapped = try #require(NativeOverviewCameraGeometry.fit(content, viewport: viewport, scaleCap: nil))
        #expect(abs(uncapped.scale - max(1, raw)) < 1e-9)
        #expect(uncapped.scale >= fitted.scale)
    }

    @Test func oversizedCollectionKeepsLogicalSizeAndCentersForPanning() throws {
        let fitted = try #require(NativeOverviewCameraGeometry.fit(large, viewport: viewport))
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        #expect(fitted.scale == 1)
        #expect(abs(fitted.x + large.width / 2 - region.left - region.width / 2) < 1e-6)
        #expect(abs(fitted.y + large.height / 2 - region.top - region.height / 2) < 1e-6)
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.cutTo(content: large, viewport: viewport)
        camera.pan(deltaX: 5000, deltaY: -5000)
        #expect(camera.liveTransform == .init(scale: 1, x: fitted.x + 5000, y: fitted.y - 5000))
    }

    @Test func manualTransformIsNeverReplacedByAutomaticGeometry() {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.cutTo(content: content, viewport: viewport)
        let saved = NativeOverviewTransform(scale: 0.8, x: 120, y: 90)
        camera.restore(view: .init(transform: saved, manual: true), content: content, viewport: viewport)
        let manual = camera.liveTransform
        #expect(manual.scale == 1)
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        let center = CGPoint(x: region.left + region.width / 2, y: region.top + region.height / 2)
        #expect(abs((center.x - manual.x) / manual.scale - (center.x - saved.x) / saved.scale) < 1e-6)
        #expect(abs((center.y - manual.y) / manual.scale - (center.y - saved.y) / saved.scale) < 1e-6)
        let automatic = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        camera.applyGeometry(content: large, viewport: viewport, automatic: automatic)
        #expect(camera.manual)
        #expect(camera.liveTransform == manual)
        #expect(!camera.hasPendingAutomaticFit)
    }

    @Test func returnToAutoConvergesToTheLatestGeometry() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.cutTo(content: content, viewport: viewport)
        camera.setManualTransform(.init(scale: 1, x: 500, y: 300))
        let first = try #require(NativeOverviewCameraGeometry.fit(large, viewport: viewport))
        camera.applyGeometry(content: large, viewport: viewport, automatic: first)
        // Manual ownership keeps the explicit view.
        #expect(camera.manual)
        let second = try #require(NativeOverviewCameraGeometry.fit(content, viewport: viewport))
        camera.returnToAuto()
        camera.applyGeometry(content: content, viewport: viewport, automatic: second)
        try await wait { !camera.manual && !camera.isAnimating && !camera.hasPendingAutomaticFit
            && NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, second) }
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, second))
    }

    @Test(arguments: [false, true], [false, true])
    func returnToAutoKeepsOwnershipAcrossPauses(hidden: Bool, pauseBeforeReturn: Bool) async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.cutTo(content: content, viewport: viewport)
        camera.setManualTransform(.init(scale: 1, x: 500, y: 300))
        if pauseBeforeReturn {
            if hidden { camera.setVisible(false) } else { camera.setInteractionPaused(true) }
        }
        camera.returnToAuto()
        #expect(!camera.manual)
        #expect(camera.live?.manual == false)
        if !pauseBeforeReturn {
            #expect(camera.isAnimating)
            if hidden { camera.setVisible(false) } else { camera.setInteractionPaused(true) }
        }
        #expect(!camera.manual)
        #expect(camera.live?.manual == false)
        #expect(!camera.isAnimating)
        #expect(camera.hasPendingAutomaticFit)
        let latest = try #require(NativeOverviewCameraGeometry.fit(large, viewport: viewport))
        camera.applyGeometry(content: large, viewport: viewport, automatic: latest)
        if hidden { camera.setVisible(true) } else { camera.setInteractionPaused(false) }
        try await wait { !camera.manual && !camera.isAnimating && !camera.hasPendingAutomaticFit }
        #expect(camera.live?.manual == false)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, latest))
    }

    @Test func returnToAnAlreadyMatchingTargetPublishesAutomaticOwnership() {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        var published: NativeOverviewCameraState?
        camera.onChange = { [weak camera] in published = camera?.live }
        camera.cutTo(content: content, viewport: viewport)
        let target = camera.liveTransform
        let expected = NativeOverviewCameraState(transform: target, manual: false)
        camera.setManualTransform(target)
        camera.returnToAuto()
        #expect(!camera.manual)
        #expect(!camera.isAnimating)
        #expect(!camera.hasPendingAutomaticFit)
        #expect(camera.live == expected)
        #expect(published == expected)
        camera.setVisible(false)
        camera.setVisible(true)
        #expect(!camera.manual)
        #expect(camera.liveTransform == target)
    }

    @Test func latestTargetWinsWithoutQueueingHistoricalRevisions() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.cutTo(content: content, viewport: viewport)
        var destinations = [NativeOverviewTransform]()
        camera.onSubmission = { if $0.duration > 0 { destinations.append($0.to) } }
        let first = try #require(NativeOverviewCameraGeometry.fit(large, viewport: viewport))
        let second = try #require(NativeOverviewCameraGeometry.fit(
            .init(left: 0, top: 0, width: NativeOverviewGridMetrics.standard.width(columns: 1), height: NativeOverviewGridMetrics.standard.height(rows: 1)), viewport: viewport))
        camera.applyGeometry(content: large, viewport: viewport, automatic: first)
        camera.applyGeometry(content: .init(left: 0, top: 0, width: NativeOverviewGridMetrics.standard.width(columns: 1), height: NativeOverviewGridMetrics.standard.height(rows: 1)),
                             viewport: viewport, automatic: second)
        try await wait { !camera.isAnimating && !camera.hasPendingAutomaticFit }
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, second))
        #expect(destinations.last.map { NativeOverviewCameraGeometry.approximatelyEqual($0, second) } == true)
    }

    @Test func pausesDeferTheLatestTargetInsteadOfMarkingItSettled() async throws {
        for hidden in [false, true] {
            let camera = NativeOverviewCamera()
            defer { camera.dispose() }
            camera.onChange = {}
            camera.cutTo(content: content, viewport: viewport)
            let next = try #require(NativeOverviewCameraGeometry.fit(large, viewport: viewport))
            if hidden { camera.setVisible(false) } else { camera.setInteractionPaused(true) }
            camera.applyGeometry(content: large, viewport: viewport, automatic: next)
            #expect(camera.hasPendingAutomaticFit)
            #expect(!NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, next))
            if hidden { camera.setVisible(true) } else { camera.setInteractionPaused(false) }
            try await wait { !camera.isAnimating && !camera.hasPendingAutomaticFit
                && NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, next) }
        }
    }

    @Test func invalidGeometryDoesNotBlockLaterValidInput() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.cutTo(content: content, viewport: viewport)
        camera.applyGeometry(content: .zero, viewport: viewport, automatic: nil)
        #expect(!camera.isInitialized)
        #expect(!camera.hasPendingAutomaticFit)
        let next = try #require(NativeOverviewCameraGeometry.fit(content, viewport: viewport))
        camera.applyGeometry(content: content, viewport: viewport, automatic: next)
        try await wait { !camera.isAnimating && !camera.hasPendingAutomaticFit }
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, next))
        // A zero viewport defers without manufacturing NaN/Infinity.
        camera.applyGeometry(content: large, viewport: .init(width: 0, height: 0), automatic: nil)
        #expect(camera.hasPendingAutomaticFit)
        #expect(camera.liveTransform.scale.isFinite && camera.liveTransform.x.isFinite && camera.liveTransform.y.isFinite)
        let recovered = try #require(NativeOverviewCameraGeometry.fit(large, viewport: viewport))
        camera.applyGeometry(content: large, viewport: viewport, automatic: recovered)
        try await wait { !camera.isAnimating && !camera.hasPendingAutomaticFit }
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, recovered))
    }

    @Test func repeatedReturnDuringMotionDoesNotStrandTheOwner() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.cutTo(content: content, viewport: viewport)
        camera.setManualTransform(.init(scale: 1, x: 500, y: 150))
        let expected = try #require(NativeOverviewCameraGeometry.fit(content, viewport: viewport))
        camera.returnToAuto()
        try await wait { camera.isAnimating }
        camera.returnToAuto()
        camera.returnToAuto()
        try await wait { !camera.isAnimating && !camera.hasPendingAutomaticFit }
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, expected))
    }

    @Test func shrinkDuringPendingGrowResolvesToTheLatestSnapshot() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.cutTo(content: content, viewport: viewport)
        let grown = try #require(NativeOverviewCameraGeometry.fit(large, viewport: viewport))
        let shrunk = try #require(NativeOverviewCameraGeometry.fit(
            .init(left: 0, top: 0, width: NativeOverviewGridMetrics.standard.width(columns: 1), height: NativeOverviewGridMetrics.standard.height(rows: 1)), viewport: viewport))
        camera.applyGeometry(content: large, viewport: viewport, automatic: grown)
        camera.applyGeometry(content: .init(left: 0, top: 0, width: NativeOverviewGridMetrics.standard.width(columns: 1), height: NativeOverviewGridMetrics.standard.height(rows: 1)),
                             viewport: viewport, automatic: shrunk)
        try await wait { !camera.isAnimating && !camera.hasPendingAutomaticFit }
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, shrunk))
    }

    @Test func emptyCollectionClearsTheCamera() {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.cutTo(content: content, viewport: viewport)
        #expect(camera.isInitialized)
        camera.applyGeometry(content: .zero, viewport: viewport, automatic: nil)
        #expect(!camera.isInitialized)
        #expect(camera.automaticFitTarget == nil)
    }

    @Test func wheelZoomKeepsTheCursorWorldPointAndTheDeclaredCap() {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.cutTo(content: large, viewport: viewport)
        camera.setManualTransform(.init(scale: 1, x: -120, y: 80))
        let cursor = CGPoint(x: 837, y: 326)
        for delta in [100_000.0, -100_000.0] {
            let before = camera.liveTransform
            let world = CGPoint(x: (cursor.x - before.x) / before.scale,
                                y: (cursor.y - before.y) / before.scale)
            camera.zoom(deltaY: delta, cursor: cursor)
            let after = camera.liveTransform
            #expect(after.scale <= camera.maximumScale + 1e-9)
            #expect(after.scale >= camera.minimumScale - 1e-9)
            let projected = CGPoint(x: after.x + world.x * after.scale,
                                    y: after.y + world.y * after.scale)
            #expect(abs(projected.x - cursor.x) < 1e-6)
            #expect(abs(projected.y - cursor.y) < 1e-6)
        }
        #expect(abs(camera.liveTransform.scale - camera.maximumScale) < 1e-9)
    }

    private func wait(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Camera did not reach the expected state", sourceLocation: sourceLocation)
        throw CancellationError()
    }
}
