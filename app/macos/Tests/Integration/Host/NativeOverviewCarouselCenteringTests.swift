import Foundation
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativeOverviewCarouselCenteringTests {
    @Test func restoredOffscreenCollectionUsesCapacityInsteadOfMarginsOrCurrentVisibility() async throws {
        let view = NativeOverviewViewport(width: 1292, height: 858, toolbarBottom: 60)
        let scene = NativeOverviewContentRect(left: 376, top: 216, width: 1112, height: 848)
        #expect(!NativeOverviewCameraGeometry.fitsAtReadingScale(scene, viewport: view))
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        var destinations: [NativeOverviewTransform] = []
        camera.onSubmission = { if $0.duration > 0 { destinations.append($0.to) } }
        camera.restore(view: .init(transform: .init(scale: 0.85, x: -900, y: 400), manual: false),
                       content: scene, viewport: view)
        camera.setCarouselCards([.init(id: "running", rect: .init(left: 376, top: 216, width: 736, height: 416), eligible: true)])
        try await wait { !camera.hasScheduledMotion && !camera.isAnimating }
        #expect(camera.carouselTargetID == nil)
        #expect(camera.transform == NativeOverviewCameraGeometry.fit(scene, viewport: view))
        #expect(!destinations.isEmpty)
        #expect(destinations.allSatisfy { $0 == camera.transform })
        let fitted = camera.transform
        #expect(fitted.y + scene.top * fitted.scale >= view.toolbarBottom)
        #expect(fitted.y + (scene.top + scene.height) * fitted.scale <= view.height)
    }

    @Test func actualViewportCapacityControlsEntryAndExitOnBothAxes() async throws {
        let view = NativeOverviewViewport(width: 1000, height: 700, toolbarBottom: 60)
        // Include translated world origins and both sides of the hard edge;
        // toolbar occlusion must not count as usable vertical capacity.
        for scene in [NativeOverviewContentRect(left: 376, top: 216, width: 1000 / 0.85, height: 200),
                      NativeOverviewContentRect(left: 376, top: 216, width: 360, height: 640 / 0.85)] {
            let camera = NativeOverviewCamera()
            defer { camera.dispose() }
            camera.cutTo(content: scene, viewport: view)
            camera.setCarouselCards([.init(id: "running", rect: scene, eligible: true)])
            #expect(camera.carouselTargetID == nil)
            var larger = scene
            if scene.width > 1000 { larger.width += 2 } else { larger.height += 2 }
            camera.requestRefit(content: larger, viewport: view, layoutChanged: true)
            try await wait { camera.carouselTargetID != nil && !camera.hasScheduledMotion }
            camera.requestRefit(content: scene, viewport: view, layoutChanged: true)
            try await wait { camera.carouselTargetID == nil && !camera.hasScheduledMotion }
            #expect(camera.transform == NativeOverviewCameraGeometry.fit(scene, viewport: view))
        }
    }

    private let viewport = NativeOverviewViewport(width: 1180, height: 780, toolbarBottom: 58)
    private let content = NativeOverviewContentRect(left: 0, top: 0, width: 2256, height: 2160)
    private let cards: [NativeOverviewCarouselCard] = [
        .init(id: "A", rect: .init(left: 0, top: 0, width: 360, height: 200), eligible: true),
        .init(id: "B", rect: .init(left: 1504, top: 216, width: 360, height: 200), eligible: true),
        .init(id: "C", rect: .init(left: 752, top: 1296, width: 360, height: 200), eligible: true),
    ]

    @Test func centeredTransformPutsCardsAtTheUsableViewportCenterWithoutChangingScale() throws {
        let rects = [
            NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 200),
            NativeOverviewContentRect(left: 1896, top: 1960, width: 360, height: 200),
            NativeOverviewContentRect(left: 752, top: 864, width: 736, height: 416),
            NativeOverviewContentRect(left: -376, top: -216, width: 1400, height: 900),
        ]
        for scale in [0.85, 1.0, 1.37] {
            for rect in rects {
                let transform = try #require(NativeOverviewCameraGeometry.centeredTransform(
                    for: rect, viewport: viewport, scale: scale))
                #expect(transform.scale == scale)
                expectCentered(rect, in: transform)
            }
        }
    }

    @Test func smallViewportStillCentersAndUnusableRegionHasNoTarget() throws {
        let card = NativeOverviewContentRect(left: 1080, top: 648, width: 360, height: 200)
        let small = NativeOverviewViewport(width: 320, height: 240, toolbarBottom: 58)
        let transform = try #require(NativeOverviewCameraGeometry.centeredTransform(
            for: card, viewport: small, scale: 0.9))
        expectCentered(card, in: transform, viewport: small)

        // The compact framing margin consumes this region completely.
        let unusable = NativeOverviewViewport(width: 20, height: 20, toolbarBottom: 19)
        #expect(NativeOverviewCameraGeometry.centeredTransform(for: card, viewport: unusable, scale: 0.9) == nil)
    }

    @Test func emptyAndSingleCardCarouselsAreStable() async throws {
        let camera = preparedCamera()
        defer { camera.dispose() }
        let initial = camera.liveTransform
        camera.setCarouselCards([])
        try await Task.sleep(for: .milliseconds(100))
        #expect(camera.carouselTargetID == nil)
        #expect(!camera.isAnimating)
        #expect(camera.transform == initial)

        let card = cards[0]
        camera.setCarouselCards([card])
        try await waitForCenter(card, camera)
        #expect(camera.carouselTargetID == card.id)
        #expect(camera.transform.scale == initial.scale)
    }

    @Test func carouselStepsAThroughCAndWrapsBackToAWithEveryCardCentered() async throws {
        let camera = preparedCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.carouselDwell = 0.05
        camera.setCarouselCards(cards)
        let scale = camera.liveTransform.scale
        for id in ["A", "B", "C", "A"] {
            let card = try #require(cards.first { $0.id == id })
            try await waitForCenter(card, camera)
            #expect(camera.carouselTargetID == id)
            #expect(camera.transform.scale == scale)
        }
    }

    @Test func oversizedAttentionCardCentersWithoutShrinkingToFit() async throws {
        let camera = preparedCamera()
        defer { camera.dispose() }
        let scale = camera.liveTransform.scale
        let card = NativeOverviewCarouselCard(
            id: "oversized", rect: .init(left: 376, top: 432, width: 1400, height: 900), eligible: true)
        camera.setCarouselCards([card])
        try await waitForCenter(card, camera)
        #expect(camera.transform.scale == scale)
    }

    @Test func repeatedStepToTheSameCardDoesNotMoveOrResubmit() async throws {
        let camera = preparedCamera()
        defer { camera.dispose() }
        camera.carouselDwell = 5
        camera.setCarouselCards(cards)
        try await waitForCenter(cards[0], camera)
        var destinations: [NativeOverviewTransform] = []
        camera.onSubmission = { if $0.duration > 0 { destinations.append($0.to) } }
        let resting = camera.liveTransform
        for _ in 0..<3 { camera.setCarouselCards(cards) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(destinations.isEmpty)
        #expect(camera.liveTransform == resting)
        #expect(camera.carouselTargetID == "A")
        #expect(!camera.isAnimating)
    }

    @Test func carouselNeverStartsOverAnExplicitManualView() async throws {
        let camera = preparedCamera()
        defer { camera.dispose() }
        let manual = NativeOverviewTransform(scale: 1.1, x: 240, y: 150)
        camera.setManualTransform(manual)
        camera.setCarouselCards(cards)
        try await Task.sleep(for: .milliseconds(150))
        #expect(camera.manual)
        #expect(camera.transform == manual)
        #expect(camera.carouselTargetID == nil)
        #expect(!camera.isAnimating)
    }

    @Test func manualInteractionStopsCarouselAndKeepsTheCameraAfterwards() async throws {
        let camera = preparedCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.carouselDwell = 0.05
        camera.setCarouselCards(cards)
        try await wait { camera.isAnimating && camera.carouselTargetID != nil }
        let manual = NativeOverviewTransform(scale: 1.1, x: 250, y: 150)
        camera.setManualTransform(manual)
        #expect(camera.manual)
        #expect(camera.transform == manual)
        #expect(camera.carouselTargetID == nil)
        #expect(!camera.isAnimating)
        try await Task.sleep(for: .milliseconds(500))
        #expect(camera.transform == manual)
        #expect(camera.carouselTargetID == nil)
        #expect(!camera.isAnimating)
    }

    @Test func tagSwitchDuringCarouselTakesTheRetainedFramingPathWithoutANewTarget() async throws {
        let camera = preparedCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.carouselDwell = 0.05
        camera.setCarouselCards(cards)
        try await wait { camera.isAnimating && camera.carouselTargetID != nil }

        let filtered = NativeOverviewContentRect(left: 376, top: 216, width: 1504, height: 1296)
        let scale = camera.liveTransform.scale
        camera.retainFraming(content: filtered, viewport: viewport)
        #expect(camera.carouselTargetID == nil)
        #expect(!camera.isAnimating)
        #expect(!camera.manual)
        #expect(camera.transform.scale == scale)
        expectAnchored(filtered, in: camera.transform)

        camera.requestRefit(content: filtered, viewport: viewport, layoutChanged: true, preserveFraming: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(camera.carouselTargetID == nil)
        #expect(!camera.isAnimating)
        expectAnchored(filtered, in: camera.transform)
    }

    @Test(.requiresDisplay) func productionCanvasCentersTheRenderedCarouselCardAcrossSteps() async throws {
        let fixture = CarouselCanvasFixture(count: 40)
        fixture.state.camera.carouselDwell = 5
        let window = SwiftUIReplay.window(CarouselCenteringCanvas(fixture: fixture))
        defer { window.close(); fixture.state.camera.dispose() }
        try await settle(fixture)

        let camera = fixture.state.camera
        let ids = ["carousel-00", "carousel-01", "carousel-20", "carousel-00"]
        let initialScale = camera.transform.scale
        for id in ids {
            let card = try #require(carouselCard(id, in: fixture))
            camera.setCarouselCards([card])
            try await SwiftUIReplay.wait(timeout: .seconds(5)) {
                camera.carouselTargetID == id && !camera.isAnimating && renderedCenterError(id, fixture) <= 1
            }
            let frame = try #require(fixture.frames[id])
            let center = usableCenter(fixture)
            print("CAROUSEL-CENTER id=\(id) frame=\(frame) center=(\(frame.midX),\(frame.midY)) " +
                  "expected=(\(center.x),\(center.y)) scale=\(camera.transform.scale)")
            #expect(abs(frame.midX - center.x) <= 1)
            #expect(abs(frame.midY - center.y) <= 1)
            #expect(camera.transform.scale == initialScale)
        }
    }

    @Test(.requiresDisplay) func productionCanvasSeparatesContentUpdatesFromCarouselNavigation() async throws {
        let fixture = CarouselCanvasFixture(count: 40)
        let camera = fixture.state.camera
        camera.carouselDwell = 0.05
        let window = SwiftUIReplay.window(CarouselCenteringCanvas(fixture: fixture))
        defer { window.close(); camera.dispose() }
        try await settle(fixture)
        let firstID = fixture.items[0].id
        try await SwiftUIReplay.wait {
            camera.carouselTargetID == firstID && !camera.isAnimating && renderedCenterError(firstID, fixture) <= 1
        }
        let resting = camera.transform
        let solves = fixture.state.layoutSolveCount
        var destinations: [NativeOverviewTransform] = []
        camera.onSubmission = { destinations.append($0.to) }

        // Observe each new semantic projection through the mounted production
        // card, without making diagnostics invalidate the canvas themselves.
        for revision in 0..<6 {
            let presentation = "content-\(revision)"
            fixture.items[0].presentationID = presentation
            fixture.items[0].completed.toggle()
            fixture.items[0].needsAttention.toggle()
            try await SwiftUIReplay.wait { fixture.presentations[firstID] == presentation }
            #expect(camera.transform == resting)
            #expect(camera.carouselTargetID == firstID)
        }
        #expect(destinations.isEmpty)
        #expect(fixture.state.layoutSolveCount == solves)

        let nextID = fixture.items[1].id
        fixture.items[0].carouselEligible = false
        fixture.items[1].carouselEligible = true
        try await SwiftUIReplay.wait {
            camera.carouselTargetID == nextID && !camera.isAnimating && renderedCenterError(nextID, fixture) <= 1
        }
        #expect(!destinations.isEmpty)
        #expect(fixture.state.layoutSolveCount == solves)

        camera.pan(deltaX: 37, deltaY: -23)
        let manual = camera.transform
        destinations.removeAll()
        fixture.items[1].presentationID = "manual-content"
        fixture.items[1].carouselEligible = false
        fixture.items[0].carouselEligible = true
        try await SwiftUIReplay.wait { fixture.presentations[nextID] == "manual-content" }
        #expect(camera.manual)
        #expect(camera.transform == manual)
        #expect(camera.carouselTargetID == nil)
        #expect(destinations.isEmpty)
        #expect(fixture.state.layoutSolveCount == solves)
    }

    private func preparedCamera() -> NativeOverviewCamera {
        let camera = NativeOverviewCamera()
        camera.cutTo(content: content, viewport: viewport)
        return camera
    }

    private func usableCenter(_ fixture: CarouselCanvasFixture) -> CGPoint {
        let viewport = NativeOverviewViewport(width: fixture.viewport.width, height: fixture.viewport.height,
                                              toolbarBottom: 58)
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        return CGPoint(x: region.left + region.width / 2, y: region.top + region.height / 2)
    }

    private func renderedCenterError(_ id: String, _ fixture: CarouselCanvasFixture) -> Double {
        guard let frame = fixture.frames[id] else { return .infinity }
        let center = usableCenter(fixture)
        return max(abs(frame.midX - center.x), abs(frame.midY - center.y))
    }

    private func carouselCard(_ id: String, in fixture: CarouselCanvasFixture) -> NativeOverviewCarouselCard? {
        guard let placement = fixture.state.presentedPlacements.first(where: { $0.id == id }) else { return nil }
        return .init(id: id,
                     rect: .init(left: Double(placement.column) * 376, top: Double(placement.row) * 216,
                                 width: Double(placement.columns) * 376 - 16,
                                 height: Double(placement.rows) * 216 - 16),
                     eligible: true)
    }

    private func settle(_ fixture: CarouselCanvasFixture) async throws {
        try await SwiftUIReplay.wait(timeout: .seconds(10)) {
            !fixture.state.isLayingOut && !fixture.state.camera.isAnimating
                && fixture.state.presentedPlacements.count == fixture.items.count
                && fixture.frames.count == fixture.items.count
                && fixture.viewport.width > 0 && fixture.viewport.height > 0
                && fixture.state.layoutError == nil
        }
    }

    private func waitForCenter(_ card: NativeOverviewCarouselCard, _ camera: NativeOverviewCamera) async throws {
        try await wait(timeout: .seconds(4)) {
            camera.carouselTargetID == card.id && !camera.isAnimating
                && centerError(card, camera) <= 1
        }
    }

    private func centerError(_ card: NativeOverviewCarouselCard, _ camera: NativeOverviewCamera,
                             viewport target: NativeOverviewViewport? = nil) -> Double {
        let region = NativeOverviewCameraGeometry.framingRegion(target ?? viewport)
        let transform = camera.liveTransform
        let centerX = transform.x + (card.rect.left + card.rect.width / 2) * transform.scale
        let centerY = transform.y + (card.rect.top + card.rect.height / 2) * transform.scale
        return max(abs(centerX - (region.left + region.width / 2)),
                   abs(centerY - (region.top + region.height / 2)))
    }

    private func expectCentered(_ rect: NativeOverviewContentRect, in transform: NativeOverviewTransform,
                                viewport target: NativeOverviewViewport? = nil) {
        let region = NativeOverviewCameraGeometry.framingRegion(target ?? viewport)
        let centerX = transform.x + (rect.left + rect.width / 2) * transform.scale
        let centerY = transform.y + (rect.top + rect.height / 2) * transform.scale
        #expect(abs(centerX - (region.left + region.width / 2)) <= 1)
        #expect(abs(centerY - (region.top + region.height / 2)) <= 1)
    }

    private func expectAnchored(_ content: NativeOverviewContentRect, in transform: NativeOverviewTransform) {
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        let expectedY = region.top + region.height / 2
        #expect(abs(transform.x + (content.left + content.width / 2) * transform.scale
            - (region.left + region.width / 2)) < 1)
        #expect(abs(transform.y + (content.top + content.height / 2) * transform.scale - expectedY) < 1)
    }

    private func wait(timeout: Duration = .seconds(4), _ predicate: () -> Bool,
                      sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Carousel did not reach the expected centered frame", sourceLocation: sourceLocation)
        throw CancellationError()
    }
}

@MainActor @Observable private final class CarouselCanvasFixture {
    let state = NativeOverviewCanvasState()
    var items: [NativeOverviewItem]
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var presentations: [String: String] = [:]
    @ObservationIgnored var viewport = CGSize.zero

    init(count: Int) {
        items = (0..<count).map {
            .init(id: String(format: "carousel-%02d", $0), carouselEligible: $0 == 0)
        }
    }
}

private struct CarouselCenteringCanvas: View {
    let fixture: CarouselCanvasFixture
    var body: some View {
        NativeOverviewCanvas(items: fixture.items, sceneKey: "carousel-centering", state: fixture.state,
                             toolbarBottom: 58, cloudAnimationsEnabled: false) { item in
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("carousel-centering")) } action: {
                    fixture.frames[item.id] = $0
                }
                .onChange(of: item.presentationID, initial: true) { _, value in fixture.presentations[item.id] = value }
        }
        .coordinateSpace(name: "carousel-centering")
        .onGeometryChange(for: CGSize.self) { $0.size } action: { fixture.viewport = $0 }
    }
}
