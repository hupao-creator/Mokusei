import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativeOverviewCameraReadabilityTests {
    private let viewport = NativeOverviewViewport(width: 1180, height: 780, toolbarBottom: 58)
    private let largeContent = NativeOverviewContentRect(left: -376, top: -216, width: 376 * 6 - 16, height: 216 * 6 - 16)

    @Test func minimumKeepsAboutSixteenReadableStandardCellsAcrossWindowSizes() {
        for size in [CGSize(width: 500, height: 600), CGSize(width: 1180, height: 780), CGSize(width: 2560, height: 1440)] {
            let view = NativeOverviewViewport(width: size.width, height: size.height, toolbarBottom: 58)
            let region = NativeOverviewCameraGeometry.framingRegion(view)
            let minimum = NativeOverviewCameraGeometry.minimumScale(in: view)
            let visibleCells = region.width * region.height / (376 * 216 * minimum * minimum)
            #expect(minimum >= 0.85)
            #expect(visibleCells <= 16 + 1e-6)
            #expect(NativeOverviewCameraGeometry.maximumScale(minimumScale: minimum) >= minimum * 2)
        }
        #expect(NativeOverviewCameraGeometry.minimumScale(in: viewport) == 0.85)
    }

    @Test func cameraFramingLeavesSpaceOnEverySideOfTheWindow() {
        for width in [500.0, 1180.0, 2560.0] {
            let view = NativeOverviewViewport(width: width, height: 900, toolbarBottom: 58)
            let region = NativeOverviewCameraGeometry.framingRegion(view)
            let inset = width <= 620 ? 32.0 : 64.0
            #expect(region.left == inset)
            #expect(region.top - view.toolbarBottom == inset)
            #expect(view.width - region.left - region.width == inset)
            #expect(view.height - region.top - region.height == inset)
        }
    }

    @Test func oversizedScenesKeepTheirHistoricalCenterAtReadableScale() {
        let fitted = NativeOverviewCameraGeometry.fit(largeContent, viewport: viewport)
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        #expect(fitted.scale == NativeOverviewCameraGeometry.minimumScale(in: viewport))
        #expect(abs(fitted.x + (largeContent.left + largeContent.width / 2) * fitted.scale - (region.left + region.width / 2)) < 1e-6)
        #expect(abs(fitted.y + (largeContent.top + largeContent.height / 2) * fitted.scale - (region.top + region.height / 2)) < 1e-6)
        #expect(!NativeOverviewCameraGeometry.fitsAtReadingScale(largeContent, viewport: viewport))
    }

    @Test func smallScenesRemainCenteredAtNaturalReadableSize() {
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        // A single card and a compact three-card collection both retain their
        // surrounding space instead of being forced against the browsing edge.
        for content in [NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 200),
                        NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 416)] {
            let fitted = NativeOverviewCameraGeometry.fit(content, viewport: viewport)
            #expect(fitted.scale == max(1, NativeOverviewCameraGeometry.minimumScale(in: viewport)))
            #expect(abs(fitted.x - (region.left + (region.width - content.width * fitted.scale) / 2)) < 1e-6)
            #expect(abs(fitted.y - (region.top + (region.height - content.height * fitted.scale) * 0.5)) < 1e-6)
            #expect(NativeOverviewCameraGeometry.fitsAtReadingScale(content, viewport: viewport))
        }
    }

    @Test func clampAndWheelZoomKeepTheCursorAnchorAtBothLimits() {
        let camera = NativeOverviewCamera()
        camera.cutTo(content: largeContent, viewport: viewport)
        camera.setManualTransform(.init(scale: (camera.minimumScale + camera.maximumScale) / 2, x: -100, y: 80))
        let cursor = CGPoint(x: 837, y: 326)
        for delta in [100_000.0, -100_000.0] {
            let before = camera.liveTransform
            let point = worldPoint(cursor, in: before)
            camera.zoom(deltaY: delta, cursor: cursor)
            let after = camera.liveTransform
            #expect(after.scale >= camera.minimumScale && after.scale <= camera.maximumScale)
            expectSame(point, worldPoint(cursor, in: after))
        }
        #expect(camera.transform.scale == camera.maximumScale)
        camera.dispose()
    }

    @Test func restoringAnOldZoomAndResizingPreserveTheReadingAnchor() {
        let camera = NativeOverviewCamera()
        let old = NativeOverviewTransform(scale: 0.6, x: -450, y: -200)
        let center = viewportCenter(viewport)
        camera.restore(view: .init(transform: old, manual: true), content: largeContent, viewport: viewport)
        #expect(camera.manual && camera.transform.scale == camera.minimumScale)
        expectSame(worldPoint(center, in: old), worldPoint(center, in: camera.transform))
        let expanded = NativeOverviewViewport(width: 2560, height: 1440, toolbarBottom: 58)
        let resizeCenter = viewportCenter(expanded)
        let before = camera.transform
        camera.requestRefit(content: largeContent, viewport: expanded)
        #expect(camera.manual && camera.transform.scale == camera.minimumScale)
        #expect(camera.maximumScale > camera.minimumScale && camera.minimumScale > 1)
        expectSame(worldPoint(resizeCenter, in: before), worldPoint(resizeCenter, in: camera.transform))
        camera.dispose()
    }

    @Test func panDoesNotChangeTheClampedScaleOrLoseItsOffset() {
        let camera = NativeOverviewCamera()
        camera.cutTo(content: largeContent, viewport: viewport)
        camera.setManualTransform(.init(scale: 0.3, x: -100, y: 70))
        let before = camera.transform
        camera.pan(deltaX: 61, deltaY: -39)
        #expect(camera.transform.scale == before.scale)
        #expect(camera.transform.x == before.x + 61)
        #expect(camera.transform.y == before.y - 39)
        camera.dispose()
    }

    @Test func retainedFilterFramingRecentersChangedContentAtTheReadingScale() {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let original = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 416)
        let taller = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 632)
        let smaller = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 200)
        camera.cutTo(content: original, viewport: viewport)
        let scale = camera.liveTransform.scale
        for content in [taller, smaller, original] {
            camera.retainFraming(content: content, viewport: viewport)
            let transform = camera.liveTransform
            #expect(transform.scale == scale)
            #expect(!camera.manual)
            expectCameraAnchored(content, in: transform, viewport: viewport)
        }
        // A filter switch that lands with a resized viewport must also follow
        // the new usable region rather than the previous window's center. This
        // window's fresh fit (the 0.85 floor) differs from the retained scale,
        // so the assertion distinguishes retention from a plain refit.
        let wide = NativeOverviewContentRect(left: 0, top: 0, width: 1107, height: 625)
        let small = NativeOverviewViewport(width: 860, height: 600, toolbarBottom: 58)
        camera.cutTo(content: wide, viewport: viewport)
        let wideScale = camera.liveTransform.scale
        #expect(abs(wideScale - 0.9503) < 0.001)
        #expect(abs(NativeOverviewCameraGeometry.fit(wide, viewport: small).scale - wideScale) > 0.05)
        camera.retainFraming(content: wide, viewport: small)
        #expect(camera.liveTransform.scale == wideScale)
        expectCameraAnchored(wide, in: camera.liveTransform, viewport: small)
    }

    @Test func retainedFilterFramingKeepsANonUnitScaleAtAnyContentOrigin() {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.cutTo(content: largeContent, viewport: viewport)
        let retainedScale = camera.liveTransform.scale
        #expect(retainedScale == NativeOverviewCameraGeometry.minimumScale(in: viewport))
        #expect(retainedScale < 1)
        for origin in [CGPoint.zero, CGPoint(x: 3760, y: 648)] {
            let oneCard = NativeOverviewContentRect(left: origin.x, top: origin.y, width: 360, height: 200)
            // A fresh fit would pick scale 1, so this asserts retention rather
            // than a coincidental refit.
            #expect(NativeOverviewCameraGeometry.fit(oneCard, viewport: viewport).scale == 1)
            camera.cutTo(content: largeContent, viewport: viewport)
            camera.retainFraming(content: oneCard, viewport: viewport)
            let transform = camera.liveTransform
            #expect(transform.scale == retainedScale)
            #expect(!camera.manual)
            expectCameraAnchored(oneCard, in: transform, viewport: viewport)
        }
    }

    @Test func retainedFilterFramingRaisesTheScaleToAResizedViewportsReadableFloor() {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.cutTo(content: largeContent, viewport: viewport)
        #expect(camera.liveTransform.scale == NativeOverviewCameraGeometry.minimumScale(in: viewport))
        // Same-frame resize and filter switch: the retained scale is below the
        // new floor, and a retained view suppresses the refit that would
        // otherwise correct it.
        let expanded = NativeOverviewViewport(width: 3840, height: 2160, toolbarBottom: 58)
        let floor = NativeOverviewCameraGeometry.minimumScale(in: expanded)
        #expect(abs(floor - 2.375) < 0.001)
        let card = NativeOverviewContentRect(left: 752, top: 432, width: 360, height: 200)
        camera.retainFraming(content: card, viewport: expanded)
        #expect(camera.liveTransform.scale == floor)
        #expect(camera.liveTransform.scale >= camera.minimumScale)
        expectCameraAnchored(card, in: camera.liveTransform, viewport: expanded)
        // Later tag switches keep the corrected floor rather than a stale scale.
        let next = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 416)
        camera.retainFraming(content: next, viewport: expanded)
        #expect(camera.liveTransform.scale == floor)
        expectCameraAnchored(next, in: camera.liveTransform, viewport: expanded)
    }

    @Test func retainedFilterFramingKeepsSameFootprintAndManualViewsUntouched() {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let content = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 416)
        let changed = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 632)
        camera.cutTo(content: content, viewport: viewport)
        let fitted = camera.liveTransform
        // An unchanged footprint is already framed; recentering must not add a
        // gratuitous camera move to a same-shape repack.
        camera.retainFraming(content: content, viewport: viewport)
        #expect(camera.liveTransform == fitted)
        let manual = NativeOverviewTransform(scale: 1.1, x: 50, y: 100)
        camera.setManualTransform(manual)
        camera.retainFraming(content: changed, viewport: viewport)
        #expect(camera.liveTransform == manual)
        #expect(camera.manual)
    }

    @Test(arguments: ["resize", "layout", "explicit"])
    func retainedFilterFramingResumesOrdinaryCameraPolicy(trigger: String) async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let original = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 416)
        let subset = NativeOverviewContentRect(left: 376, top: 216, width: 360, height: 200)
        camera.cutTo(content: original, viewport: viewport)
        camera.retainFraming(content: subset, viewport: viewport)
        let retained = camera.liveTransform
        camera.requestRefit(content: subset, viewport: viewport, layoutChanged: true, preserveFraming: true)
        // A no-op reconciliation must not silently release the retained view.
        camera.requestRefit(content: subset, viewport: viewport)
        try await Task.sleep(for: .milliseconds(750))
        #expect(camera.liveTransform == retained)
        var nextViewport = viewport
        if trigger == "resize" {
            nextViewport.width += 200
            camera.requestRefit(content: subset, viewport: nextViewport)
        } else if trigger == "layout" {
            camera.requestRefit(content: subset, viewport: viewport, layoutChanged: true)
        } else {
            camera.returnToAuto()
        }
        let target = NativeOverviewCameraGeometry.fit(subset, viewport: nextViewport)
        for _ in 0..<150 where !NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, target) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, target))
    }

    @Test func readableFloorDoesNotDisableAutomaticAttention() async throws {
        let camera = NativeOverviewCamera()
        camera.cutTo(content: largeContent, viewport: viewport)
        #expect(camera.minimumScale > 0.7)
        let target = NativeOverviewContentRect(left: 376 * 4, top: 216 * 4, width: 736, height: 848)
        camera.setCarouselCards([.init(id: "attention", rect: target, eligible: true)])
        #expect(camera.carouselTargetID == "attention")
        for _ in 0..<100 where !NativeOverviewCameraGeometry.isVisible(target, transform: camera.liveTransform, viewport: viewport) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(camera.transform.scale >= camera.minimumScale)
        #expect(NativeOverviewCameraGeometry.isVisible(target, transform: camera.liveTransform, viewport: viewport))
        camera.setInteractionPaused(true)
        #expect(camera.carouselPaused)
        camera.dispose()
    }

    private func viewportCenter(_ viewport: NativeOverviewViewport) -> CGPoint {
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        return CGPoint(x: region.left + region.width / 2, y: region.top + region.height / 2)
    }
    private func worldPoint(_ point: CGPoint, in transform: NativeOverviewTransform) -> CGPoint {
        CGPoint(x: (point.x - transform.x) / transform.scale, y: (point.y - transform.y) / transform.scale)
    }
    private func expectSame(_ lhs: CGPoint, _ rhs: CGPoint) {
        #expect(abs(lhs.x - rhs.x) < 1e-6)
        #expect(abs(lhs.y - rhs.y) < 1e-6)
    }
}
