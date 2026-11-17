import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

/// A bare NSHostingView mounts the production Canvas without creating an
/// NSWindow or activating the application. This covers real layout and camera
/// geometry; window-level focus, pixels and animation remain graphical owners.
@MainActor
private enum HeadlessOverviewReplay {
    static func settle(_ fixture: OverviewReplayFixture, host: NSHostingView<OverviewReplayCanvas>,
                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let ids = Set(fixture.items.map(\.id))
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if fixture.viewport == fixture.size
                && fixture.state.camera.viewport == fixture.cameraViewport
                && !fixture.state.isLayingOut
                && Set(fixture.state.presentedPlacements.map(\.id)) == ids
                && Set(fixture.frames.keys) == ids
                && !fixture.state.camera.isAnimating
                && !fixture.state.camera.hasPendingAutomaticFit
                && !fixture.state.camera.hasScheduledMotion
                && fixture.projectionError < 0.5 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Headless Canvas did not settle: presented=\(fixture.state.presentedPlacements.map(\.id)) frames=\(fixture.frames.keys.sorted()) viewport=\(fixture.viewport) cameraViewport=\(String(describing: fixture.state.camera.viewport)) layingOut=\(fixture.state.isLayingOut) error=\(fixture.state.layoutError ?? "nil")", sourceLocation: sourceLocation)
        throw CancellationError()
    }

    static func host(_ fixture: OverviewReplayFixture) -> NSHostingView<OverviewReplayCanvas> {
        let host = NSHostingView(rootView: OverviewReplayCanvas(fixture: fixture))
        host.frame = CGRect(origin: .zero, size: fixture.size)
        host.layoutSubtreeIfNeeded()
        return host
    }

    static func verify(_ fixture: OverviewReplayFixture, host: NSHostingView<OverviewReplayCanvas>,
                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        if host.window != nil {
            Issue.record("Headless Canvas unexpectedly created a window", sourceLocation: sourceLocation)
        }
        if NSApp?.isActive == true {
            Issue.record("Headless Canvas unexpectedly activated NSApp", sourceLocation: sourceLocation)
        }
        let onScreen = NSApp?.windows.filter { $0.isVisible && $0.windowNumber > 0 }.count ?? 0
        if onScreen != 0 {
            Issue.record("Headless process owns \(onScreen) on-screen windows", sourceLocation: sourceLocation)
        }
        let ids = Set(fixture.items.map(\.id))
        if !ids.allSatisfy({ (fixture.appearances[$0] ?? 0) > 0 }) {
            Issue.record("Headless Canvas did not report every current card appearance", sourceLocation: sourceLocation)
        }
        if Set(fixture.state.presentedPlacements.map(\.id)) != ids || Set(fixture.frames.keys) != ids {
            Issue.record("Headless Canvas membership/frame mismatch", sourceLocation: sourceLocation)
        }
        for placement in fixture.state.presentedPlacements {
            guard let rendered = fixture.frames[placement.id],
                  let displayed = fixture.state.displayedFrame(for: placement.id) else {
                Issue.record("Missing rendered or displayed frame for \(placement.id)", sourceLocation: sourceLocation)
                continue
            }
            if abs(rendered.minX - displayed.minX) > 0.5 || abs(rendered.minY - displayed.minY) > 0.5
                || abs(rendered.width - displayed.width) > 0.5 || abs(rendered.height - displayed.height) > 0.5 {
                Issue.record("Frame disagrees with displayedFrame for \(placement.id): \(rendered) vs \(displayed)", sourceLocation: sourceLocation)
            }
        }
        guard !fixture.items.isEmpty else { return }
        let usable = fixture.usable
        let envelope = fixture.renderedEnvelope
        if abs(envelope.midX - (usable.left + usable.width / 2)) > 0.5
            || abs(envelope.midY - (usable.top + usable.height / 2)) > 0.5 {
            Issue.record("Headless rendered collection is not centered: \(envelope)", sourceLocation: sourceLocation)
        }
        let allowed = CGRect(x: usable.left, y: usable.top, width: usable.width, height: usable.height)
            .insetBy(dx: -0.5, dy: -0.5)
        for (id, frame) in fixture.frames where !allowed.contains(frame) {
            Issue.record("Headless card \(id) is outside the usable viewport: \(frame)", sourceLocation: sourceLocation)
        }
    }
}

@MainActor
@Suite(.serializedNative, .serialized)
struct NativeOverviewHeadlessGeometryTests {
    @Test func mixedFootprintsResizeWithoutAWindow() async throws {
        let fixture = OverviewReplayFixture(
            items: [.init(id: "large", columns: 2, rows: 2),
                    .init(id: "small-a"), .init(id: "small-b"),
                    .init(id: "wide", columns: 2), .init(id: "tall", rows: 2)],
            size: .init(width: 1292, height: 858))
        fixture.bottomReservedHeight = 80
        let host = HeadlessOverviewReplay.host(fixture)
        try await HeadlessOverviewReplay.settle(fixture, host: host)
        try HeadlessOverviewReplay.verify(fixture, host: host)

        fixture.size = .init(width: 860, height: 600)
        host.frame = CGRect(origin: .zero, size: fixture.size)
        host.layoutSubtreeIfNeeded()
        try await HeadlessOverviewReplay.settle(fixture, host: host)
        try HeadlessOverviewReplay.verify(fixture, host: host)
    }

    @Test func narrowViewportHonorsToolbarAndDockReservation() async throws {
        let fixture = OverviewReplayFixture(
            items: [.init(id: "one"), .init(id: "two", columns: 2), .init(id: "three", rows: 2)],
            size: .init(width: 500, height: 600))
        fixture.bottomReservedHeight = 100
        let host = HeadlessOverviewReplay.host(fixture)
        try await HeadlessOverviewReplay.settle(fixture, host: host)
        try HeadlessOverviewReplay.verify(fixture, host: host)
        let content = NativeOverviewCameraGeometry.contentRegion(fixture.cameraViewport)
        let envelope = fixture.renderedEnvelope
        #expect(envelope.minY >= content.top - 0.5)
        #expect(envelope.maxY <= content.top + content.height + 0.5)
    }

    @Test func sceneAndFilterResetConvergesOnTheLatestCollection() async throws {
        let fixture = OverviewReplayFixture(
            items: [.init(id: "browse-a"), .init(id: "browse-b")],
            scene: "browse", selection: "all")
        let host = HeadlessOverviewReplay.host(fixture)
        try await HeadlessOverviewReplay.settle(fixture, host: host)
        try HeadlessOverviewReplay.verify(fixture, host: host)

        fixture.scene = "filtered"
        fixture.selection = "directory:design"
        fixture.install([.init(id: "filter-a", columns: 2, rows: 2),
                         .init(id: "filter-b"), .init(id: "filter-c", rows: 2)])
        try await HeadlessOverviewReplay.settle(fixture, host: host)
        try HeadlessOverviewReplay.verify(fixture, host: host)
        #expect(Set(fixture.state.presentedPlacements.map(\.id)) == ["filter-a", "filter-b", "filter-c"])
    }
}
