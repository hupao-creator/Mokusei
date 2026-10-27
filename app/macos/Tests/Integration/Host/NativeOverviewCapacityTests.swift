import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Observable private final class CapacityFixture {
    let state = NativeOverviewCanvasState()
    var scene = "capacity"
    var reduceMotion = false
    var size = CGSize(width: 1420, height: 900)
    var items: [NativeOverviewItem] = [
        .init(id: "large", columns: 2, rows: 2, carouselEligible: true),
        .init(id: "small-a"), .init(id: "small-b"),
        .init(id: "wide-a", columns: 2), .init(id: "wide-b", columns: 2)
    ]
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var appearances: [String: Int] = [:]
    @ObservationIgnored var viewport = CGSize.zero
}

private struct CapacityCanvas: View {
    let fixture: CapacityFixture
    var body: some View {
        var canvas = NativeOverviewCanvas(items: fixture.items, sceneKey: fixture.scene, state: fixture.state,
                             selectionID: fixture.scene, toolbarBottom: 58, cloudAnimationsEnabled: false) { item in
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("capacity")) } action: {
                    fixture.frames[item.id] = $0
                }
                .onAppear { fixture.appearances[item.id, default: 0] += 1 }
        }
        canvas.reduceMotionOverride = fixture.reduceMotion
        return canvas
        .coordinateSpace(name: "capacity")
        .onGeometryChange(for: CGSize.self) { $0.size } action: { fixture.viewport = $0 }
        .frame(width: fixture.size.width, height: fixture.size.height)
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeOverviewCapacityTests {
    @Test func recordingFootprintsFitWithoutMarginsAndRecoverAfterExtensionGrowth() async throws {
        let fixture = CapacityFixture()
        fixture.size = .init(width: 1292, height: 858)
        fixture.items = [
            .init(id: "git", columns: 2, rows: 2, carouselEligible: true),
            .init(id: "note", columns: 2, rows: 2, carouselEligible: true),
            .init(id: "layout", carouselEligible: true), .init(id: "done"), .init(id: "report")
        ]
        let window = SwiftUIReplay.window(CapacityCanvas(fixture: fixture), width: 1400, height: 950)
        defer { window.close() }
        try await settle(fixture)
        try expectWholeCollection(fixture, requireMargins: false)
        let appearances = fixture.appearances
        // A real extension footprint change must still admit attention when
        // the complete scene no longer fits, then retire it after shrinkage.
        fixture.items[0].rows = 4
        fixture.items[1].rows = 4
        try await settle(fixture)
        #expect(fixture.state.camera.carouselTargetID != nil)
        fixture.items[0].rows = 2
        fixture.items[1].rows = 2
        try await settle(fixture)
        try expectWholeCollection(fixture, requireMargins: false)
        // Leave much of a fitting scene offscreen. Fact refreshes cannot
        // mistake this user-owned translation for insufficient capacity.
        fixture.state.camera.pan(deltaX: 500, deltaY: 400)
        let manual = fixture.state.camera.liveTransform
        fixture.items[0].needsAttention = true
        fixture.items[2].carouselEligible = false
        try await settle(fixture)
        #expect(fixture.state.camera.manual)
        #expect(fixture.state.camera.liveTransform == manual)
        #expect(fixture.state.camera.carouselTargetID == nil)
        fixture.state.camera.returnToAuto()
        try await settle(fixture)
        try expectWholeCollection(fixture, requireMargins: false)
        try await Task.sleep(for: .milliseconds(750))
        try expectWholeCollection(fixture, requireMargins: false)
        #expect(fixture.appearances == appearances)
    }

    @Test func rapidResizeMembershipAndFilterChangesConvergeToLatestReadableScene() async throws {
        let fixture = CapacityFixture()
        fixture.size = .init(width: 860, height: 600)
        let window = SwiftUIReplay.window(CapacityCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close() }
        try await settle(fixture)
        #expect(fixture.state.camera.carouselTargetID != nil)
        let all = fixture.items
        for index in 0..<6 {
            fixture.size = index.isMultiple(of: 2) ? .init(width: 1500, height: 960) : .init(width: 860, height: 600)
            fixture.items = index.isMultiple(of: 2) ? Array(all.prefix(3)) : all
            fixture.scene = "filter-\(index)"
            try await Task.sleep(for: .milliseconds(25))
        }
        fixture.size = .init(width: 1420, height: 900)
        fixture.items = all + [.init(id: "sixth", carouselEligible: true)]
        fixture.scene = "final"
        try await settle(fixture)
        #expect(fixture.state.mountedCardIDs == Set(fixture.items.map(\.id)))
        #expect(fixture.state.camera.carouselTargetID == nil)
        // Surviving filters intentionally retain their browsing scale. Explicit
        // automatic framing must use the final capacity, never a queued viewport.
        fixture.state.camera.returnToAuto()
        try await settle(fixture)
        try expectWholeCollection(fixture)
        try await Task.sleep(for: .milliseconds(750))
        try expectWholeCollection(fixture)
        #expect(fixture.state.layoutError == nil)
    }

    @Test func sixCardGrowthAndFollowingUpdatesRecoverWithoutRetryOrRemount() async throws {
        let fixture = CapacityFixture()
        fixture.size = .init(width: 860, height: 600)
        fixture.items = (0..<6).map { .init(id: "card-\($0)") }
        let window = SwiftUIReplay.window(CapacityCanvas(fixture: fixture))
        defer { window.close() }
        try await settle(fixture)
        let appearances = fixture.appearances
        for (index, rows) in [(3, 2), (3, 1), (4, 1), (4, 2)] {
            fixture.items[index].columns = 2
            fixture.items[index].rows = rows
            try await settle(fixture)
        }
        #expect(fixture.state.repackCount > 0)
        #expect(fixture.appearances == appearances)
        #expect(fixture.state.mountedCardIDs == Set(fixture.items.map(\.id)))
        fixture.items[4].rows = 1
        fixture.items.append(.init(id: "new-card"))
        try await settle(fixture)
        #expect(fixture.state.layoutError == nil)
    }

    @Test func invalidRevisionPreservesLastLayoutAndNextValidRevisionRecovers() async throws {
        let fixture = CapacityFixture()
        let window = SwiftUIReplay.window(CapacityCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close() }
        try await settle(fixture)
        let placements = fixture.state.presentedPlacements
        let transform = fixture.state.camera.liveTransform
        let appearances = fixture.appearances
        fixture.items[0].columns = 0
        try await SwiftUIReplay.wait { fixture.state.layoutError != nil && !fixture.state.isLayingOut }
        #expect(fixture.state.presentedPlacements == placements)
        #expect(fixture.state.camera.liveTransform == transform)
        #expect(fixture.appearances == appearances)
        fixture.items[0].columns = 2
        try await settle(fixture)
        #expect(fixture.state.layoutError == nil)
        #expect(fixture.state.presentedPlacements == placements)
        try expectWholeCollection(fixture)
    }

    @Test func screenshotCardsFitWithoutCarouselAndKeepReadableFootprints() async throws {
        let fixture = CapacityFixture()
        let window = SwiftUIReplay.window(CapacityCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close() }
        try await settle(fixture)
        try expectWholeCollection(fixture)
        let placements = fixture.state.presentedPlacements
        #expect(placements.map { $0.column + $0.columns }.max() == 4)
        #expect(placements.map { $0.row + $0.rows }.max() == 3)
        // Attention and execution changes are eligibility, never a capacity weight.
        for index in fixture.items.indices {
            fixture.items[index].carouselEligible = true
            fixture.items[index].needsAttention = true
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.state.presentedPlacements == placements)
        try expectWholeCollection(fixture)
        fixture.items.append(.init(id: "sixth", carouselEligible: true))
        try await settle(fixture)
        try expectWholeCollection(fixture)
        fixture.items.removeLast()
        try await settle(fixture)
        try expectWholeCollection(fixture)
    }

    @Test func resizeExitsCarouselAndRetainsAReadableShapeAcrossAspectThreshold() async throws {
        let fixture = CapacityFixture()
        fixture.size = .init(width: 860, height: 600)
        let window = SwiftUIReplay.window(CapacityCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close() }
        try await settle(fixture)
        #expect(fixture.state.camera.carouselTargetID != nil)
        let appearances = fixture.appearances
        fixture.size = .init(width: 1420, height: 900)
        try await settle(fixture)
        try expectWholeCollection(fixture)
        let placements = fixture.state.presentedPlacements
        // A taller viewport now also fits the old square preference. Resizing
        // must not shuffle readable cards back and forth between both shapes.
        for size in [CGSize(width: 1500, height: 960), CGSize(width: 1420, height: 900),
                     CGSize(width: 1392.81, height: 900), CGSize(width: 1392.82, height: 900)] {
            fixture.size = size
            try await settle(fixture)
            #expect(fixture.state.presentedPlacements == placements)
            try expectWholeCollection(fixture)
        }
        #expect(fixture.appearances == appearances)
        fixture.size = .init(width: 1392, height: 900)
        try await settle(fixture)
        // Losing the preferred 64pt margin is not losing actual capacity.
        try expectWholeCollection(fixture, requireMargins: false)
        fixture.size = .init(width: 860, height: 600)
        try await settle(fixture)
        #expect(fixture.state.camera.carouselTargetID != nil)
        fixture.size = .init(width: 1420, height: 900)
        try await settle(fixture)
        try expectWholeCollection(fixture)
    }

    @Test func threeCardsUseNaturalScaleInTheActualViewport() async throws {
        let fixture = CapacityFixture()
        fixture.size = .init(width: 900, height: 750)
        fixture.items = (0..<3).map { .init(id: "card-\($0)") }
        let window = SwiftUIReplay.window(CapacityCanvas(fixture: fixture))
        defer { window.close() }
        try await settle(fixture)
        #expect(fixture.state.camera.liveTransform.scale == 1)
        #expect(Set(fixture.state.presentedPlacements.map(\.column)).count == 2)
        try expectWholeCollection(fixture)
    }

    @Test(arguments: [false, true])
    func structuralContentReusesGeometryAndDeletionKeepsScreenAnchors(reduceMotion: Bool) async throws {
        let fixture = CapacityFixture()
        fixture.reduceMotion = reduceMotion
        fixture.items = (0..<9).map { .init(id: "card-\($0)") }
        let window = SwiftUIReplay.window(CapacityCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close() }
        try await settle(fixture)
        let placements = fixture.state.presentedPlacements
        let center = try #require(placements.first { $0.column == 1 && $0.row == 1 })
        let frames = fixture.frames
        let solves = fixture.state.layoutSolveCount
        for revision in 0..<10 {
            fixture.items[0].structureKey = "internal-\(revision)"
            try await Task.sleep(for: .milliseconds(25))
        }
        try await settle(fixture)
        #expect(fixture.state.layoutSolveCount == solves)
        #expect(fixture.state.geometryReuseCount > 0)
        fixture.items.removeAll { $0.id == center.id }
        try await settle(fixture)
        #expect(fixture.state.presentedPlacements == placements.filter { $0.id != center.id })
        for item in fixture.items {
            let before = try #require(frames[item.id])
            let after = try #require(fixture.frames[item.id])
            #expect(hypot(before.minX - after.minX, before.minY - after.minY) < 1)
        }
        fixture.items.append(.init(id: "new"))
        try await settle(fixture)
        let inserted = try #require(fixture.state.presentedPlacements.first { $0.id == "new" })
        #expect(inserted.column == center.column && inserted.row == center.row)
        #expect(fixture.state.camera.reduceMotion == reduceMotion)
        try expectWholeCollection(fixture)
    }

    @Test func scaledEdgeDeletionPreservesReadingPosition() async throws {
        let fixture = CapacityFixture()
        fixture.size = .init(width: 1111, height: 900)
        fixture.items = (0..<9).map { .init(id: "card-\($0)") }
        let window = SwiftUIReplay.window(CapacityCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close() }
        try await settle(fixture)
        let frames = fixture.frames
        let scale = fixture.state.camera.liveTransform.scale
        let bottom = try #require(fixture.state.presentedPlacements.map(\.row).max())
        let removed = Set(fixture.state.presentedPlacements.filter { $0.row == bottom }.map(\.id))
        #expect(removed.count == 3)
        fixture.items.removeAll { removed.contains($0.id) }
        try await settle(fixture)
        for item in fixture.items {
            let before = try #require(frames[item.id])
            let after = try #require(fixture.frames[item.id])
            #expect(hypot(before.minX - after.minX, before.minY - after.minY) < 1)
        }
        #expect(fixture.state.camera.liveTransform.scale == scale)
        try expectWholeCollection(fixture)
    }

    @Test(arguments: [1, 6], [false, true])
    func insertionFramesTheCompleteCollectionWithoutBackgroundClick(count: Int, reduceMotion: Bool) async throws {
        let fixture = CapacityFixture()
        fixture.reduceMotion = reduceMotion
        fixture.items = (0..<count).map { .init(id: "card-\($0)") }
        let window = SwiftUIReplay.window(CapacityCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close() }
        try await settle(fixture)
        fixture.items.append(.init(id: "new"))
        try await settle(fixture)
        try expectWholeCollection(fixture)
        #expect(fixture.state.mountedCardIDs == Set(fixture.items.map(\.id)))
        #expect(fixture.appearances.values.allSatisfy { $0 == 1 })
        // Assert the rendered collection, not just the camera's target. Keeping
        // the single-card camera would leave the pair half a cell to the right.
        let frames = try fixture.items.map { try #require(fixture.frames[$0.id]) }
        let envelope = frames.reduce(CGRect.null) { $0.union($1) }
        let viewport = try #require(fixture.state.camera.viewport)
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        #expect(abs(envelope.midX - (region.left + region.width / 2)) < 1)
        #expect(abs(envelope.minY - (region.top + (region.height - envelope.height) * 0.5)) < 1)
        let transform = fixture.state.camera.liveTransform
        try await Task.sleep(for: .milliseconds(750))
        #expect(fixture.state.camera.liveTransform == transform)
        // The click path must no longer be needed to repair insertion framing.
        fixture.state.camera.returnToAuto()
        try await settle(fixture)
        #expect(fixture.state.camera.liveTransform == transform)
    }

    @Test(arguments: [false, true])
    func streamingContentDoesNotPostponeInsertionFraming(reduceMotion: Bool) async throws {
        let fixture = CapacityFixture()
        fixture.reduceMotion = reduceMotion
        fixture.items = [.init(id: "original")]
        let window = SwiftUIReplay.window(CapacityCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close() }
        try await settle(fixture)
        fixture.items.append(.init(id: "new"))
        try await SwiftUIReplay.wait {
            fixture.state.presentedPlacements.count == 2 && !fixture.state.isLayingOut
        }
        let solves = fixture.state.layoutSolveCount
        // Content-only projections update carousel facts too. Keep them arriving
        // faster than the refit delay, as a running Harness does after insertion.
        for revision in 0..<40 {
            fixture.items[1].presentationID = "content-\(revision)"
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(!fixture.state.camera.hasScheduledMotion)
        let frames = try fixture.items.map { try #require(fixture.frames[$0.id]) }
        #expect(abs(frames.reduce(CGRect.null) { $0.union($1) }.midX - fixture.size.width / 2) < 1)
        #expect(fixture.state.layoutSolveCount == solves)
    }

    @Test(arguments: [false, true])
    func insertionDoesNotResetManualPan(reduceMotion: Bool) async throws {
        let fixture = CapacityFixture()
        fixture.reduceMotion = reduceMotion
        fixture.items = [.init(id: "original")]
        let window = SwiftUIReplay.window(CapacityCanvas(fixture: fixture), width: 1600, height: 1100)
        defer { window.close() }
        try await settle(fixture)
        fixture.state.camera.pan(deltaX: -130, deltaY: 75)
        try await settle(fixture)
        let manual = fixture.state.camera.liveTransform
        let original = try #require(fixture.frames["original"])
        fixture.items.append(.init(id: "new"))
        try await settle(fixture)
        try await Task.sleep(for: .milliseconds(750))
        #expect(fixture.state.camera.manual)
        #expect(fixture.state.camera.liveTransform == manual)
        #expect(fixture.frames["original"] == original)
        #expect(fixture.state.mountedCardIDs == ["original", "new"])
    }

    private func settle(_ fixture: CapacityFixture) async throws {
        try await SwiftUIReplay.wait(timeout: .seconds(15)) {
            fixture.viewport == fixture.size && fixture.state.camera.viewport?.width == fixture.size.width &&
            fixture.state.camera.viewport?.height == fixture.size.height && !fixture.state.isLayingOut &&
            fixture.state.layoutError == nil &&
            Set(fixture.state.presentedPlacements.map(\.member)) == Set(fixture.items.map(\.member)) &&
            !fixture.state.camera.isAnimating && !fixture.state.camera.hasScheduledMotion &&
            fixture.state.presentedPlacements.allSatisfy { placement in
                guard let frame = fixture.frames[placement.id] else { return false }
                let transform = fixture.state.camera.liveTransform
                let expected = placement.cardFrame
                return abs(frame.minX - (transform.x + expected.minX * transform.scale)) < 0.5 &&
                    abs(frame.minY - (transform.y + expected.minY * transform.scale)) < 0.5 &&
                    abs(frame.width - expected.width * transform.scale) < 0.5 &&
                    abs(frame.height - expected.height * transform.scale) < 0.5
            }
        }
        #expect(fixture.state.layoutError == nil)
    }

    private func expectWholeCollection(_ fixture: CapacityFixture, requireMargins: Bool = true) throws {
        let camera = fixture.state.camera
        #expect(camera.carouselTargetID == nil)
        #expect(camera.liveTransform.scale >= camera.minimumScale)
        let viewport = try #require(camera.viewport)
        let region = requireMargins ? NativeOverviewCameraGeometry.framingRegion(viewport)
            : NativeOverviewContentRect(left: 0, top: viewport.toolbarBottom, width: viewport.width,
                                        height: viewport.height - viewport.toolbarBottom)
        let allowed = CGRect(x: region.left, y: region.top, width: region.width, height: region.height).insetBy(dx: -0.5, dy: -0.5)
        for item in fixture.items {
            let frame = try #require(fixture.frames[item.id])
            #expect(allowed.contains(frame), "\(item.id): \(frame) outside \(allowed)")
            #expect(frame.width + 0.5 >= Double(item.columns * 376 - 16) * camera.minimumScale)
            #expect(frame.height + 0.5 >= Double(item.rows * 216 - 16) * camera.minimumScale)
        }
    }
}
