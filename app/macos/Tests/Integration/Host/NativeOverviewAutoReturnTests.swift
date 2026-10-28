import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativeOverviewAutoReturnTests {
    private let viewport = NativeOverviewViewport(width: 1180, height: 780, toolbarBottom: 58)
    private let content = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 1712)
    private let card = NativeOverviewContentRect(left: 0, top: 216, width: 360, height: 200)
    // The eligible card is entirely visible here, despite a displaced collection.
    private let displaced = NativeOverviewTransform(scale: 1, x: 500, y: 150)

    @Test func explicitReturnFitsBeforeResumingAttentionEvenWhenTargetIsVisible() async throws {
        let camera = preparedCamera()
        defer { camera.dispose() }
        // A fully visible but displaced attention card still moves to the
        // usable viewport center when automatic framing resumes.
        #expect(attentionFocus() != displaced)
        var destinations: [NativeOverviewTransform] = []
        camera.onSubmission = { if $0.duration > 0 { destinations.append($0.to) } }
        camera.returnToAuto()
        let fit = NativeOverviewCameraGeometry.fit(content, viewport: viewport)
        let expected = attentionFocus()
        try await wait { destinations.contains(fit) && !camera.isAnimating && camera.transform == expected }
        #expect(!camera.manual && camera.carouselTargetID == "running")
        #expect(camera.transform == expected)
        #expect(camera.transform != displaced)
    }

    @Test func repeatedReturnDuringCarouselMotionDoesNotStrandItsOwner() async throws {
        let camera = preparedCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.returnToAuto()
        try await wait { camera.isAnimating && camera.carouselTargetID == "running" }
        camera.returnToAuto()
        camera.returnToAuto()
        let expected = attentionFocus()
        try await wait { !camera.isAnimating && camera.transform == expected }
        #expect(!camera.manual && camera.carouselTargetID == "running")
    }

    @Test func pendingReturnSurvivesInteractionAndVisibilityPauses() async throws {
        for hidden in [false, true] {
            let camera = preparedCamera()
            defer { camera.dispose() }
            var destinations: [NativeOverviewTransform] = []
            camera.onSubmission = { if $0.duration > 0 { destinations.append($0.to) } }
            if hidden { camera.setVisible(false) } else { camera.setInteractionPaused(true) }
            camera.returnToAuto()
            #expect(camera.transform == displaced)
            if hidden { camera.setVisible(true) } else { camera.setInteractionPaused(false) }
            let fit = NativeOverviewCameraGeometry.fit(content, viewport: viewport)
            try await wait { destinations.contains(fit) && !camera.isAnimating && camera.carouselTargetID == "running" }
            #expect(camera.transform != displaced)
        }
    }

    @Test func interruptedReturnRetriesAfterPauseButNewManualInputCancelsIt() async throws {
        let camera = preparedCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.returnToAuto()
        try await wait { camera.isAnimating }
        camera.setInteractionPaused(true)
        camera.setInteractionPaused(false)
        let expected = attentionFocus()
        try await wait { !camera.isAnimating && camera.transform == expected }
        camera.setInteractionPaused(true)
        camera.returnToAuto()
        camera.setManualTransform(displaced)
        camera.setInteractionPaused(false)
        // Flush any queued camera reservation; manual state must win.
        try await Task.sleep(for: .milliseconds(200))
        #expect(camera.manual && camera.transform == displaced)
        #expect(!camera.isAnimating && camera.carouselTargetID == nil)
    }

    @Test func returnWaitingForLayoutStageRetriesAfterPause() async throws {
        let camera = preparedCamera()
        defer { camera.dispose() }
        let coordinator = try #require(camera.stageCoordinator)
        let layout = try await coordinator.acquire(owner: "layout")
        defer { layout.release() }
        camera.onChange = {}
        camera.returnToAuto()
        await Task.yield()
        #expect(!camera.isAnimating && camera.transform == displaced)
        camera.setInteractionPaused(true)
        layout.release()
        camera.setInteractionPaused(false)
        let expected = attentionFocus()
        try await wait { !camera.isAnimating && camera.transform == expected && coordinator.activeOwner == nil }
        #expect(!camera.manual)
    }

    @Test(arguments: [false, true])
    func footprintRevisionCannotRetainAnUnfinishedReturn(restoring: Bool) async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        let coordinator = NativeOverviewStageCoordinator()
        camera.stageCoordinator = coordinator
        let layout = try await coordinator.acquire(owner: "layout")
        defer { layout.release() }
        let small = NativeOverviewContentRect(left: 0, top: 0, width: 360, height: 200)
        let grown = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 416)
        if restoring {
            camera.restore(view: .init(transform: displaced, manual: false), content: small, viewport: viewport)
        } else {
            camera.cutTo(content: small, viewport: viewport)
            camera.setManualTransform(displaced)
            camera.returnToAuto()
        }
        camera.onChange = {}
        // Layout finishes while the return still waits for this stage. A local
        // footprint edit cannot replace the user's pending automatic framing.
        camera.deferRefit()
        camera.requestRefit(content: grown, viewport: viewport, layoutChanged: true, preserveReadingPosition: true)
        layout.release()
        try await wait { !camera.hasScheduledMotion }
        #expect(camera.liveTransform == NativeOverviewCameraGeometry.fit(grown, viewport: viewport))
        #expect(!camera.manual)
    }

    @Test func footprintShrinkLeavingAttentionFitsTheCollection() async throws {
        let camera = NativeOverviewCamera()
        defer { camera.dispose() }
        camera.onChange = {}
        camera.cutTo(content: content, viewport: viewport)
        camera.setCarouselCards([.init(id: "running", rect: card, eligible: true)])
        try await wait { camera.carouselTargetID == "running" && !camera.hasScheduledMotion }
        let smaller = NativeOverviewContentRect(left: 0, top: 0, width: 736, height: 416)
        camera.deferRefit()
        camera.requestRefit(content: smaller, viewport: viewport, layoutChanged: true, preserveReadingPosition: true)
        try await wait { camera.carouselTargetID == nil && !camera.hasScheduledMotion }
        #expect(camera.liveTransform == NativeOverviewCameraGeometry.fit(smaller, viewport: viewport))
    }

    /// Automatic attention keeps the scene's fitted reading scale and only
    /// translates the card center to the usable viewport center.
    private func attentionFocus() -> NativeOverviewTransform {
        let fit = NativeOverviewCameraGeometry.fit(content, viewport: viewport)
        return NativeOverviewCameraGeometry.centeredTransform(for: card, viewport: viewport, scale: fit.scale) ?? fit
    }

    private func wait(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Camera did not reach the expected framing", sourceLocation: sourceLocation)
        throw CancellationError()
    }

    private func preparedCamera() -> NativeOverviewCamera {
        let camera = NativeOverviewCamera()
        camera.stageCoordinator = NativeOverviewStageCoordinator()
        camera.cutTo(content: content, viewport: viewport)
        camera.setManualTransform(displaced)
        camera.setCarouselCards([.init(id: "running", rect: card, eligible: true)])
        return camera
    }
}
