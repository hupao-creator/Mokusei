import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativeOverviewCameraReadabilityTests {
    private let viewport = NativeOverviewViewport(width: 1180, height: 780, toolbarBottom: 58)
    private let largeContent = NativeOverviewContentRect(left: -376, top: -236, width: 376 * 6 - 16, height: 236 * 6 - 16)

    @Test func minimumKeepsAboutSixteenReadableStandardCellsAcrossWindowSizes() {
        for size in [CGSize(width: 500, height: 600), CGSize(width: 1180, height: 780), CGSize(width: 2560, height: 1440)] {
            let view = NativeOverviewViewport(width: size.width, height: size.height, toolbarBottom: 58)
            let region = NativeOverviewCameraGeometry.framingRegion(view)
            let minimum = NativeOverviewCameraGeometry.minimumScale(in: view)
            let visibleCells = region.width * region.height / (376 * 236 * minimum * minimum)
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
        for content in [NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 220),
                        NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)] {
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
        let original = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        let taller = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 692)
        let smaller = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 220)
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
        // viewport cannot hold the previous scale, so ordinary readable fitting
        // must win over retention even though the collection still overflows.
        let wide = NativeOverviewContentRect(left: 0, top: 0, width: 1107, height: 625)
        let small = NativeOverviewViewport(width: 860, height: 600, toolbarBottom: 58)
        camera.cutTo(content: wide, viewport: viewport)
        let wideScale = camera.liveTransform.scale
        #expect(abs(wideScale - 0.9503) < 0.001)
        #expect(abs(NativeOverviewCameraGeometry.fit(wide, viewport: small).scale - wideScale) > 0.05)
        camera.retainFraming(content: wide, viewport: small)
        #expect(camera.liveTransform.scale == camera.minimumScale)
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
            let oneCard = NativeOverviewContentRect(left: origin.x, top: origin.y, width: 360, height: 220)
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
        #expect(abs(floor - 2.272) < 0.001)
        let card = NativeOverviewContentRect(left: 752, top: 472, width: 360, height: 220)
        camera.retainFraming(content: card, viewport: expanded)
        #expect(camera.liveTransform.scale == floor)
        #expect(camera.liveTransform.scale >= camera.minimumScale)
        expectCameraAnchored(card, in: camera.liveTransform, viewport: expanded)
        // Later tag switches keep the corrected floor rather than a stale scale.
        let next = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        camera.retainFraming(content: next, viewport: expanded)
        #expect(camera.liveTransform.scale == floor)
        expectCameraAnchored(next, in: camera.liveTransform, viewport: expanded)
    }

    @Test func retainedFilterFramingKeepsSameFootprintAndManualViewsUntouched() {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let content = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        let changed = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 692)
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
        let original = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        let subset = NativeOverviewContentRect(left: 376, top: 236, width: 360, height: 220)
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


    @Test func sameScaleAspectChangingShrinkRecentersBothAxes() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let wide = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 220)
        let tall = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 456)
        camera.cutTo(content: wide, viewport: viewport)
        camera.requestRefit(content: tall, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        let expected = NativeOverviewCameraGeometry.fit(tall, viewport: viewport)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, expected))
        try await waitForCamera(camera, expected)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, expected))
    }

    @Test func filteredEditKeepsRetainedTargetAfterVerticalSeat() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let vertical = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 456)
        let filtered = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        camera.cutTo(content: large, viewport: viewport)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        let seat = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        try await waitForCamera(camera, seat)
        camera.retainFraming(content: filtered, viewport: viewport)
        let retained = NativeOverviewCameraGeometry.fit(filtered, viewport: viewport)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, retained))
        camera.requestRefit(content: filtered, viewport: viewport,
                            layoutChanged: true, preserveFraming: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, retained))
        camera.requestRefit(content: filtered, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, retained))
        try await waitForCamera(camera, retained)
    }

    @Test func shrinkGrowShrinkRecentersAfterAutomaticClamp() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let small = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 692)
        camera.cutTo(content: large, viewport: viewport)
        let smallFit = NativeOverviewCameraGeometry.fit(small, viewport: viewport)
        camera.requestRefit(content: small, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, smallFit))
        try await waitForCamera(camera, smallFit)
        camera.requestRefit(content: large, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        let clamped = camera.automaticFitTarget ?? .identity
        #expect(abs(clamped.x - 165) < 1e-9)
        try await waitForCamera(camera, clamped)
        camera.requestRefit(content: small, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, smallFit))
        try await waitForCamera(camera, smallFit)
    }

    @Test func verticalSeatSurvivesFollowingWidthShrink() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let vertical = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 456)
        let narrower = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        camera.cutTo(content: large, viewport: viewport)
        let seat = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, seat))
        try await waitForCamera(camera, seat)
        let narrowerFit = NativeOverviewCameraGeometry.fit(narrower, viewport: viewport)
        let expected = NativeOverviewTransform(scale: narrowerFit.scale,
                                               x: narrowerFit.x, y: seat.y)
        camera.requestRefit(content: narrower, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, expected))
        try await waitForCamera(camera, expected)
        #expect(camera.liveTransform.y == seat.y)
    }

    @Test func heightGrowthThenWidthShrinkUsesCompleteNarrowFit() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let wide = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 220)
        let tall = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 456)
        let narrow = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        camera.cutTo(content: wide, viewport: viewport)
        let wideFit = NativeOverviewCameraGeometry.fit(wide, viewport: viewport)
        camera.requestRefit(content: tall, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        let grown = camera.automaticFitTarget ?? .identity
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(grown, wideFit))
        try await waitForCamera(camera, grown)
        let narrowFit = NativeOverviewCameraGeometry.fit(narrow, viewport: viewport)
        camera.requestRefit(content: narrow, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, narrowFit))
        try await waitForCamera(camera, narrowFit)
        #expect(abs(camera.liveTransform.y - narrowFit.y) < 1e-9)
    }

    @Test func cardHeightShrinkCreatesPersistentVerticalSeat() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let tallCard = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        let shortCard = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 220)
        let narrowCard = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 220)
        camera.cutTo(content: tallCard, viewport: viewport)
        let tallFit = NativeOverviewCameraGeometry.fit(tallCard, viewport: viewport)
        camera.requestRefit(content: shortCard, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, tallFit))
        try await waitForCamera(camera, tallFit)
        let narrowFit = NativeOverviewCameraGeometry.fit(narrowCard, viewport: viewport)
        let expected = NativeOverviewTransform(scale: narrowFit.scale,
                                               x: narrowFit.x, y: tallFit.y)
        camera.requestRefit(content: narrowCard, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, expected))
        try await waitForCamera(camera, expected)
    }

    @Test func widthAndHeightShrinkInSameRevisionKeepsNewXAndOldY() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let narrowAndShort = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        camera.cutTo(content: large, viewport: viewport)
        let largeFit = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        let narrowFit = NativeOverviewCameraGeometry.fit(narrowAndShort, viewport: viewport)
        let expected = NativeOverviewTransform(scale: narrowFit.scale,
                                               x: narrowFit.x, y: largeFit.y)
        camera.requestRefit(content: narrowAndShort, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, expected))
        try await waitForCamera(camera, expected)
    }

    @Test func consecutiveHeightShrinksKeepTheFirstVerticalSeat() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let middle = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 456)
        let short = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 220)
        camera.cutTo(content: large, viewport: viewport)
        let seat = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        camera.requestRefit(content: middle, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await waitForCamera(camera, seat)
        camera.requestRefit(content: short, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, seat))
        try await waitForCamera(camera, seat)
    }

    @Test func heightSeatPersistsAcrossGrowthAndClampsAtExtremeTallAspect() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let tall = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 700)
        let short = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 220)
        let medium = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 600)
        let extreme = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 760)
        camera.cutTo(content: tall, viewport: viewport)
        let seat = NativeOverviewCameraGeometry.fit(tall, viewport: viewport)
        camera.requestRefit(content: short, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await waitForCamera(camera, seat)
        camera.requestRefit(content: medium, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        let persisted = NativeOverviewTransform(scale: seat.scale, x: seat.x, y: seat.y)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, persisted))
        try await waitForCamera(camera, persisted)
        camera.requestRefit(content: extreme, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        let clamped = camera.automaticFitTarget ?? .identity
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        #expect(abs(clamped.y - (region.top + region.height - extreme.height * clamped.scale)) < 0.001)
        try await waitForCamera(camera, clamped)
        #expect(clamped.y >= region.top - 0.001)
        #expect(clamped.y <= region.top + region.height - extreme.height * clamped.scale + 0.001)
        #expect(clamped.y + extreme.height * clamped.scale <= region.top + region.height + 0.001)
        #expect(clamped.x >= region.left - 0.001)
        #expect(clamped.x + extreme.width * clamped.scale <= region.left + region.width + 0.001)
    }

    @Test func extremeWideRetainedSeatStaysVisible() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let wideTall = NativeOverviewContentRect(left: 0, top: 0, width: 1200, height: 692)
        let wideShort = NativeOverviewContentRect(left: 0, top: 0, width: 1200, height: 100)
        let narrowShort = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 100)
        camera.cutTo(content: wideTall, viewport: viewport)
        let seat = NativeOverviewCameraGeometry.fit(wideTall, viewport: viewport)
        camera.requestRefit(content: wideShort, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await waitForCamera(camera, seat)
        let narrowFit = NativeOverviewCameraGeometry.fit(narrowShort, viewport: viewport)
        let expected = NativeOverviewTransform(scale: narrowFit.scale,
                                               x: narrowFit.x, y: seat.y)
        camera.requestRefit(content: narrowShort, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, expected))
        try await waitForCamera(camera, expected)
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        #expect(expected.x >= region.left - 0.001)
        #expect(expected.y >= region.top - 0.001)
        #expect(expected.x + narrowShort.width * expected.scale <= region.left + region.width + 0.001)
        #expect(expected.y + narrowShort.height * expected.scale <= region.top + region.height + 0.001)
    }

    @Test func returnToAutoClearsPersistentVerticalSeat() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let vertical = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 456)
        camera.cutTo(content: large, viewport: viewport)
        let seat = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await waitForCamera(camera, seat)
        let ordinary = NativeOverviewCameraGeometry.fit(vertical, viewport: viewport)
        camera.returnToAuto()
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
        try await waitForCamera(camera, ordinary)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
        try await waitForCamera(camera, ordinary)
    }

    @Test func retainFramingClearsPersistentVerticalSeat() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let vertical = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 456)
        let filtered = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        camera.cutTo(content: large, viewport: viewport)
        let seat = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await waitForCamera(camera, seat)
        camera.retainFraming(content: filtered, viewport: viewport)
        let ordinary = NativeOverviewCameraGeometry.fit(filtered, viewport: viewport)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, ordinary))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
        camera.requestRefit(content: filtered, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
        try await waitForCamera(camera, ordinary)
    }

    @Test func retainFramingSameContentKeepsCurrentViewAsBaseline() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let vertical = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 456)
        camera.cutTo(content: large, viewport: viewport)
        let seat = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await waitForCamera(camera, seat)
        camera.retainFraming(content: vertical, viewport: viewport)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, seat))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, seat))
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, seat))
        try await waitForCamera(camera, seat)
        let ordinary = NativeOverviewCameraGeometry.fit(vertical, viewport: viewport)
        camera.returnToAuto()
        try await waitForCamera(camera, ordinary)
    }

    @Test func retainFramingPublishesBaselineAtomically() {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 900, height: 700)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let filtered = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 220)
        camera.cutTo(content: large, viewport: viewport)
        var observed: [NativeOverviewTransform] = []
        camera.onChange = { [weak camera] in
            guard let camera else { return }
            observed.append(camera.automaticFitTarget ?? .identity)
        }
        camera.retainFraming(content: filtered, viewport: viewport)
        let retained = camera.liveTransform
        #expect(!observed.isEmpty)
        #expect(observed.allSatisfy { NativeOverviewCameraGeometry.approximatelyEqual($0, retained) })
    }

    @Test func preserveFramingKeepsCurrentViewAsRetainedBaseline() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let vertical = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 456)
        camera.cutTo(content: large, viewport: viewport)
        let seat = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await waitForCamera(camera, seat)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveFraming: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, seat))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, seat))
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, seat))
        try await waitForCamera(camera, seat)
        let ordinary = NativeOverviewCameraGeometry.fit(vertical, viewport: viewport)
        camera.returnToAuto()
        try await waitForCamera(camera, ordinary)
    }

    @Test func preserveFramingDuringRefitCancelsThePendingTarget() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let small = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 692)
        camera.onChange = {}
        camera.cutTo(content: large, viewport: viewport)
        camera.requestRefit(content: small, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        for _ in 0..<100 {
            if camera.isAnimating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(camera.isAnimating)
        camera.requestRefit(content: small, viewport: viewport,
                            layoutChanged: true, preserveFraming: true)
        let baseline = camera.liveTransform
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, baseline))
        #expect(!camera.isAnimating)
        #expect(!camera.hasScheduledMotion)
        try await Task.sleep(for: .milliseconds(500))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, baseline))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, baseline))
    }

    @Test func preserveFramingDuringAutomaticReturnDoesNotCreateBaseline() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let content = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        let displaced = NativeOverviewTransform(scale: 1, x: 50, y: 100)
        camera.onChange = {}
        camera.restore(view: .init(transform: displaced, manual: false),
                       content: content, viewport: viewport)
        for _ in 0..<200 {
            if camera.isAnimating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(camera.isAnimating)
        #expect(camera.returning)
        camera.requestRefit(content: content, viewport: viewport,
                            layoutChanged: true, preserveFraming: true)
        let ordinary = NativeOverviewCameraGeometry.fit(content, viewport: viewport)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
        for _ in 0..<200 {
            if !camera.isAnimating, !camera.hasScheduledMotion { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, ordinary))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
    }

    @Test func preserveFramingWhileRefitWaitsForStageKeepsLiveBaseline() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let small = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 692)
        let coordinator = NativeOverviewStageCoordinator()
        camera.onChange = {}
        camera.stageCoordinator = coordinator
        camera.cutTo(content: large, viewport: viewport)
        let lease = try await coordinator.acquire(owner: "test")
        defer { lease.release() }
        camera.requestRefit(content: small, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!camera.isAnimating)
        #expect(camera.hasScheduledMotion)
        let baseline = camera.liveTransform
        camera.requestRefit(content: small, viewport: viewport,
                            layoutChanged: true, preserveFraming: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, baseline))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, baseline))
        #expect(!camera.hasScheduledMotion)
        lease.release()
        try await Task.sleep(for: .milliseconds(500))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, baseline))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, baseline))
    }

    @Test func preserveFramingWhileRefitWaitsForStageCommitsClampedBaseline() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let small = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 692)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let coordinator = NativeOverviewStageCoordinator()
        camera.onChange = {}
        camera.stageCoordinator = coordinator
        camera.cutTo(content: small, viewport: viewport)
        let lease = try await coordinator.acquire(owner: "test")
        defer { lease.release() }
        camera.requestRefit(content: large, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!camera.isAnimating)
        #expect(camera.hasScheduledMotion)
        camera.requestRefit(content: large, viewport: viewport,
                            layoutChanged: true, preserveFraming: true)
        let expected = NativeOverviewTransform(scale: 1, x: 165, y: 107)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, expected))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, expected))
        #expect(!camera.hasScheduledMotion)
        lease.release()
        try await Task.sleep(for: .milliseconds(500))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, expected))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, expected))
    }

    @Test func preserveFramingDuringReturnAutoDoesNotCreateBaseline() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let content = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        camera.onChange = {}
        camera.cutTo(content: content, viewport: viewport)
        camera.setManualTransform(.init(scale: 1, x: 50, y: 100))
        camera.returnToAuto()
        for _ in 0..<200 {
            if camera.isAnimating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(camera.isAnimating)
        #expect(camera.hasPendingAutomaticFit)
        camera.requestRefit(content: content, viewport: viewport,
                            layoutChanged: true, preserveFraming: true)
        let ordinary = NativeOverviewCameraGeometry.fit(content, viewport: viewport)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
        for _ in 0..<200 {
            if !camera.isAnimating, !camera.hasScheduledMotion { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, ordinary))
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
        #expect(!camera.hasPendingAutomaticFit)
    }

    @Test func setManualTransformClearsPersistentVerticalSeat() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let vertical = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 456)
        camera.cutTo(content: large, viewport: viewport)
        let seat = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await waitForCamera(camera, seat)
        let manual = NativeOverviewTransform(scale: 1, x: 50, y: 100)
        camera.setManualTransform(manual)
        #expect(camera.manual)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, manual))
        let ordinary = NativeOverviewCameraGeometry.fit(vertical, viewport: viewport)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
        camera.returnToAuto()
        try await waitForCamera(camera, ordinary)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
        try await waitForCamera(camera, ordinary)
    }

    @Test func viewportChangeClearsPersistentVerticalSeat() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let expanded = NativeOverviewViewport(width: 1341, height: 1000)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let vertical = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 456)
        camera.cutTo(content: large, viewport: viewport)
        let seat = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await waitForCamera(camera, seat)
        let ordinary = NativeOverviewCameraGeometry.fit(vertical, viewport: expanded)
        camera.requestRefit(content: vertical, viewport: expanded)
        try await waitForCamera(camera, ordinary)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
        camera.requestRefit(content: vertical, viewport: expanded,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
        try await waitForCamera(camera, ordinary)
    }

    @Test func resetClearsPersistentVerticalSeat() async throws {
        let camera = NativeOverviewCamera()
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let vertical = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 456)
        let filtered = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        camera.cutTo(content: large, viewport: viewport)
        let seat = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await waitForCamera(camera, seat)
        camera.dispose()
        #expect(camera.automaticFitTarget == nil)
        camera.cutTo(content: filtered, viewport: viewport)
        let ordinary = NativeOverviewCameraGeometry.fit(filtered, viewport: viewport)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, ordinary))
        camera.requestRefit(content: filtered, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, ordinary))
        try await waitForCamera(camera, ordinary)
        camera.dispose()
    }

    @Test func persistentSeatSurvivesMixedWidthAndHeightSequence() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let large = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 692)
        let vertical = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 456)
        let narrow = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 456)
        let grown = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 600)
        let narrowTall = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 600)
        let short = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 220)
        camera.cutTo(content: large, viewport: viewport)
        let seat = NativeOverviewCameraGeometry.fit(large, viewport: viewport)
        camera.requestRefit(content: vertical, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        try await waitForCamera(camera, seat)
        let firstWidthShrink = NativeOverviewTransform(
            scale: NativeOverviewCameraGeometry.fit(narrow, viewport: viewport).scale,
            x: NativeOverviewCameraGeometry.fit(narrow, viewport: viewport).x,
            y: seat.y)
        camera.requestRefit(content: narrow, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, firstWidthShrink))
        try await waitForCamera(camera, firstWidthShrink)
        camera.requestRefit(content: grown, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, firstWidthShrink))
        try await waitForCamera(camera, firstWidthShrink)
        let secondWidthShrink = NativeOverviewTransform(
            scale: NativeOverviewCameraGeometry.fit(narrowTall, viewport: viewport).scale,
            x: NativeOverviewCameraGeometry.fit(narrowTall, viewport: viewport).x,
            y: seat.y)
        camera.requestRefit(content: narrowTall, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, secondWidthShrink))
        try await waitForCamera(camera, secondWidthShrink)
        camera.requestRefit(content: short, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, secondWidthShrink))
        try await waitForCamera(camera, secondWidthShrink)
    }

    @Test func pendingGrowKeepsItsSeatUntilANewRevision() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let viewport = NativeOverviewViewport(width: 1341, height: 906)
        let one = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 220)
        let grown = NativeOverviewContentRect(left: 0, top: 0, width: 1112, height: 220)
        let shrunk = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 220)
        camera.cutTo(content: one, viewport: viewport)
        camera.requestRefit(content: grown, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        let pending = camera.automaticFitTarget ?? .identity
        #expect(abs(pending.x - 165) < 1e-9)
        camera.requestRefit(content: shrunk, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, pending))
        try await waitForCamera(camera, pending)
        let shrunkFit = NativeOverviewCameraGeometry.fit(shrunk, viewport: viewport)
        camera.requestRefit(content: shrunk, viewport: viewport,
                            layoutChanged: true, preserveReadingPosition: true)
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.automaticFitTarget ?? .identity, shrunkFit))
        try await waitForCamera(camera, shrunkFit)
    }

    private func waitForCamera(_ camera: NativeOverviewCamera,
                               _ expected: NativeOverviewTransform) async throws {
        for _ in 0..<300 {
            if NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, expected),
               !camera.isAnimating, !camera.hasScheduledMotion {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(NativeOverviewCameraGeometry.approximatelyEqual(camera.liveTransform, expected))
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
