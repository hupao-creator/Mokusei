import AppKit
import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeOverviewCapacityTests {
    @Test func rapidMembershipAndViewportChangesConvergeToTheLatestSnapshot() async throws {
        let fixture = OverviewReplayFixture(items: (0..<6).map { .init(id: "card-\($0)") },
                                            size: .init(width: 860, height: 600))
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        let all = fixture.items
        for index in 0..<8 {
            fixture.size = index.isMultiple(of: 2) ? .init(width: 1500, height: 960) : .init(width: 860, height: 600)
            fixture.install(index.isMultiple(of: 2) ? Array(all.prefix(3)) : all)
            fixture.scene = "filter-\(index)"
            try await Task.sleep(for: .milliseconds(20))
        }
        fixture.size = .init(width: 1420, height: 900)
        fixture.install(all + [.init(id: "seventh", columns: 2)])
        fixture.scene = "final"
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.layoutError == nil)
        #expect(Set(fixture.state.mountedCardIDs) == Set(fixture.items.map(\.id)))
        try OverviewReplay.verifyFitAll(fixture, in: window)
        try OverviewReplay.verifyControlsClear(fixture, in: window)
    }

    @Test(arguments: [1, 6])
    func insertionAndReturnToAutoUseTheLatestCollection(count: Int) async throws {
        let fixture = OverviewReplayFixture(items: (0..<count).map { .init(id: "card-\($0)") })
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        fixture.install(fixture.items + [.init(id: "new")])
        try await OverviewReplay.settle(fixture, in: window)
        try OverviewReplay.verifyFitAll(fixture, in: window)
        #expect(Set(fixture.state.mountedCardIDs) == Set(fixture.items.map(\.id)))
        #expect(fixture.appearances.values.allSatisfy { $0 == 1 })
        let transform = fixture.state.camera.liveTransform
        fixture.state.camera.returnToAuto()
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.camera.liveTransform == transform)
    }

    @Test func freshSceneWithNoVisibleSurvivorReframesAutomatically() async throws {
        let fixture = OverviewReplayFixture(items: [.init(id: "browse-1"), .init(id: "browse-2")])
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1400, height: 900)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        fixture.state.camera.setManualTransform(.init(scale: 0.9, x: -10_000, y: -10_000))
        fixture.scene = "search-results"
        fixture.install([.init(id: "result", columns: 2, rows: 1)])
        try await OverviewReplay.settle(fixture, in: window)
        #expect(!fixture.state.camera.manual)
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }

    @Test func contentOnlyUpdatesDoNotRelayoutOrMoveTheCamera() async throws {
        let fixture = OverviewReplayFixture(items: (0..<8).map { .init(id: "card-\($0)") })
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture))
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        let solves = fixture.state.layoutSolveCount
        let transform = fixture.state.camera.liveTransform
        let frames = fixture.frames
        for revision in 0..<20 {
            var items = fixture.items
            items[0].presentationID = "content-\(revision)"
            fixture.install(items)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.layoutSolveCount == solves)
        #expect(fixture.state.camera.liveTransform == transform)
        #expect(fixture.frames == frames)
    }

    @Test func contentOnlyUpdateReusesMixedFootprintGeometryInProductOrder() async throws {
        let fixture = OverviewReplayFixture(items: [
            .init(id: "a", columns: 2, rows: 2),
            .init(id: "b", columns: 1, rows: 2),
            .init(id: "c", columns: 2, rows: 1),
            .init(id: "d"),
            .init(id: "e", columns: 1, rows: 2),
            .init(id: "f", columns: 2, rows: 1),
        ])
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1400, height: 900)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.presentedPlacements.map(\.id) == fixture.items.map(\.id))
        let solves = fixture.state.layoutSolveCount
        let transform = fixture.state.camera.liveTransform
        for revision in 0..<6 {
            var items = fixture.items
            items[0].presentationID = "mixed-\(revision)"
            fixture.install(items)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.layoutSolveCount == solves)
        #expect(fixture.state.camera.liveTransform == transform)
        #expect(fixture.state.presentedPlacements.map(\.id) == fixture.items.map(\.id))
    }

    @Test func manualCameraSurvivesBackgroundUpdatesAndReturnAutoFitsTheLatestScene() async throws {
        let fixture = OverviewReplayFixture(items: (0..<5).map { .init(id: "card-\($0)") })
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        let manual = NativeOverviewTransform(scale: 1, x: -400, y: 260)
        fixture.state.camera.setManualTransform(manual)
        fixture.install(fixture.items + [.init(id: "added", columns: 2, rows: 2)])
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.camera.manual)
        #expect(fixture.state.camera.liveTransform == manual)
        fixture.state.camera.returnToAuto()
        try await OverviewReplay.settle(fixture, in: window)
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }

    @Test func interruptionDuringEntryConvergesWithoutLeavingTransparentCards() async throws {
        let fixture = OverviewReplayFixture(items: [.init(id: "first"), .init(id: "second")])
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1400, height: 900)
        defer { window.close() }
        try await SwiftUIReplay.wait { fixture.state.presentedPlacements.count == 2 }
        fixture.install([.init(id: "first"), .init(id: "third", columns: 2, rows: 2),
                         .init(id: "fourth"), .init(id: "fifth")])
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.presentedPlacements.map(\.id).sorted()
            == fixture.items.map(\.id).sorted())
        #expect(Set(fixture.state.mountedCardIDs) == Set(fixture.items.map(\.id)))
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }

    @Test func layoutPauseAndHiddenRecoveryApplyTheLatestSnapshot() async throws {
        let fixture = OverviewReplayFixture(items: [.init(id: "before")])
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture))
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        fixture.layoutPaused = true
        fixture.install([.init(id: "paused-1"), .init(id: "paused-2", columns: 2)])
        try await SwiftUIReplay.wait { !fixture.state.isLayingOut }
        fixture.layoutPaused = false
        try await OverviewReplay.settle(fixture, in: window)
        try OverviewReplay.verifyFitAll(fixture, in: window)

        fixture.visible = false
        fixture.install([.init(id: "hidden", columns: 1, rows: 2)])
        try await SwiftUIReplay.wait { fixture.state.presentedPlacements.map(\.id) == ["hidden"] }
        fixture.visible = true
        try await OverviewReplay.settle(fixture, in: window)
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }

    @Test func zeroViewportDoesNotLatchLaterValidLayout() async throws {
        let fixture = OverviewReplayFixture(items: [.init(id: "first"), .init(id: "second")])
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1400, height: 900)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        fixture.size = .zero
        try await SwiftUIReplay.wait { fixture.viewport == .zero }
        fixture.install([.init(id: "third", columns: 2), .init(id: "fourth")])
        try await SwiftUIReplay.wait { !fixture.state.isLayingOut }
        fixture.size = .init(width: 1180, height: 780)
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.layoutError == nil)
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }

    @Test func invalidSnapshotDoesNotBlockLaterValidInput() async throws {
        let fixture = OverviewReplayFixture(items: [.init(id: "before")])
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture))
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        fixture.install([.init(id: "bad", columns: 0, rows: 1)])
        try await SwiftUIReplay.wait { fixture.state.layoutError != nil }
        #expect(fixture.state.presentedPlacements.map(\.id) == ["before"])
        fixture.install([.init(id: "recovered", columns: 2, rows: 1), .init(id: "second")])
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.layoutError == nil)
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }

    @Test func largeCollectionRendersEveryCardAtFitAll() async throws {
        let fixture = OverviewReplayFixture(items: (0..<100).map { index in
            .init(id: "large-\(index)", columns: index.isMultiple(of: 7) ? 2 : 1,
                  rows: index.isMultiple(of: 11) ? 2 : 1)
        }, size: .init(width: 1920, height: 1080))
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1920, height: 1080)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.frames.count == 100)
        #expect(Set(fixture.state.mountedCardIDs) == Set(fixture.items.map(\.id)))
        try OverviewReplay.verifyFitAll(fixture, in: window)
        try OverviewReplay.verifyControlsClear(fixture, in: window)
    }
}
