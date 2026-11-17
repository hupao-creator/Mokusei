import AppKit
import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeOverviewTransitionTests {
    @Test func rapidFilterReversalRendersTheLatestScene() async throws {
        let fixture = OverviewReplayFixture(items: [.init(id: "a"), .init(id: "b")])
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1400, height: 900)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        fixture.scene = "filter-b"
        fixture.install([.init(id: "c", columns: 2), .init(id: "d")])
        try await Task.sleep(for: .milliseconds(30))
        fixture.scene = "filter-a"
        fixture.install([.init(id: "a"), .init(id: "b"), .init(id: "e")])
        try await Task.sleep(for: .milliseconds(30))
        fixture.scene = "final"
        fixture.install([.init(id: "c", columns: 2), .init(id: "d"), .init(id: "f", rows: 2)])
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.layoutError == nil)
        #expect(Set(fixture.state.mountedCardIDs) == Set(fixture.items.map(\.id)))
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }

    @Test func interruptionSamplesCurrentPosesAndRetargets() async throws {
        let fixture = OverviewReplayFixture(items: (0..<4).map { .init(id: "card-\($0)") })
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1400, height: 900)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        fixture.install((0..<7).map { .init(id: "card-\($0)", columns: $0.isMultiple(of: 3) ? 2 : 1,
                                            rows: $0.isMultiple(of: 4) ? 2 : 1) })
        try await SwiftUIReplay.wait { fixture.state.isLayingOut }
        fixture.install((0..<5).map { .init(id: "card-\($0)", columns: $0.isMultiple(of: 2) ? 2 : 1,
                                            rows: $0.isMultiple(of: 3) ? 2 : 1) })
        try await Task.sleep(for: .milliseconds(20))
        fixture.install((0..<6).map { .init(id: "card-\($0)", columns: $0.isMultiple(of: 5) ? 2 : 1) })
        try await OverviewReplay.settle(fixture, in: window)
        #expect(Set(fixture.state.mountedCardIDs) == Set(fixture.items.map(\.id)))
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }

    @Test func survivorsKeepIdentityAcrossAnInterruptedEntryAndExit() async throws {
        let fixture = OverviewReplayFixture(items: (0..<4).map { .init(id: "keep-\($0)") })
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1400, height: 900)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        let appearances = fixture.appearances
        fixture.install([.init(id: "keep-0"), .init(id: "new-a", columns: 2),
                         .init(id: "keep-2"), .init(id: "new-b", rows: 2)])
        try await SwiftUIReplay.wait { fixture.state.isLayingOut }
        fixture.install([.init(id: "keep-0"), .init(id: "keep-2"), .init(id: "final", columns: 2, rows: 2)])
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.appearances["keep-0"] == appearances["keep-0"])
        #expect(fixture.appearances["keep-2"] == appearances["keep-2"])
        #expect(Set(fixture.state.mountedCardIDs) == Set(fixture.items.map(\.id)))
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }

    @Test func queuedOldGeometryCannotOverwriteTheNewerSnapshot() async throws {
        let fixture = OverviewReplayFixture(items: [.init(id: "initial")])
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1400, height: 900)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        let lease = try await fixture.state.motionStages.acquire(owner: "test")
        fixture.install([.init(id: "old-1", columns: 2), .init(id: "old-2")])
        try await SwiftUIReplay.wait { fixture.state.isLayingOut }
        try await Task.sleep(for: .milliseconds(40))
        fixture.install([.init(id: "new-1", columns: 2, rows: 2), .init(id: "new-2")])
        try await Task.sleep(for: .milliseconds(20))
        lease.release()
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.presentedPlacements.map(\.id).sorted() == ["new-1", "new-2"])
        #expect(fixture.state.layoutError == nil)
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }

    @Test(arguments: [false, true])
    func returningToDisplayedGeometryCancelsAQueuedSnapshot(resizeViewport: Bool) async throws {
        let items: [NativeOverviewItem] = [.init(id: "first"), .init(id: "second", columns: 2)]
        let fixture = OverviewReplayFixture(items: items)
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close(); fixture.state.camera.dispose() }
        try await OverviewReplay.settle(fixture, in: window)
        let originalSize = fixture.size
        let originalCamera = fixture.state.camera.liveTransform
        let solves = fixture.state.layoutSolveCount
        let reuses = fixture.state.geometryReuseCount
        let lease = try await fixture.state.motionStages.acquire(owner: "test-reversal")
        defer { lease.release() }
        if resizeViewport {
            fixture.size = .init(width: 1460, height: 980)
        } else {
            fixture.install([.init(id: "obsolete", columns: 2, rows: 2)])
        }
        try await SwiftUIReplay.wait { fixture.state.isLayingOut }
        if resizeViewport { fixture.size = originalSize } else { fixture.install(items) }
        try await SwiftUIReplay.wait { fixture.state.geometryReuseCount > reuses }
        #expect(!fixture.state.isLayingOut)
        lease.release()
        // Wait for the released stage to drain: an obsolete worker must not
        // publish after the latest snapshot has already taken the reuse path.
        try await SwiftUIReplay.wait { fixture.state.motionStages.activeOwner == nil }
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.layoutSolveCount == solves)
        #expect(fixture.state.presentedPlacements.map(\.id) == items.map(\.id))
        #expect(fixture.state.camera.liveTransform == originalCamera)
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }

    @Test func pauseDuringMotionResumesToThePublishedTarget() async throws {
        let fixture = OverviewReplayFixture(items: (0..<5).map { .init(id: "card-\($0)") })
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1400, height: 900)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        fixture.install((0..<7).map { .init(id: "card-\($0)", columns: $0.isMultiple(of: 3) ? 2 : 1,
                                            rows: $0.isMultiple(of: 4) ? 2 : 1) })
        try await SwiftUIReplay.wait { fixture.state.isLayingOut }
        fixture.layoutPaused = true
        try await SwiftUIReplay.wait { !fixture.state.isLayingOut }
        fixture.layoutPaused = false
        try await OverviewReplay.settle(fixture, in: window)
        try OverviewReplay.verifyFitAll(fixture, in: window)
        #expect(Set(fixture.state.mountedCardIDs) == Set(fixture.items.map(\.id)))
    }

    @Test func contentRevisionDuringMotionDoesNotReplaceTheStructuralTarget() async throws {
        let fixture = OverviewReplayFixture(items: (0..<5).map { .init(id: "card-\($0)") })
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1400, height: 900)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        fixture.install(fixture.items + [.init(id: "entrant", columns: 2, rows: 2)])
        try await SwiftUIReplay.wait { fixture.state.isLayingOut }
        for revision in 0..<12 {
            var items = fixture.items
            items[0].presentationID = "stream-\(revision)"
            fixture.install(items)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await OverviewReplay.settle(fixture, in: window)
        #expect(Set(fixture.state.presentedPlacements.map(\.id)) == Set(fixture.items.map(\.id)))
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }
}
