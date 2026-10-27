import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Observable private final class TransitionFixture {
    let state = NativeOverviewCanvasState()
    var items: [NativeOverviewItem] = [.init(id: "a"), .init(id: "b")]
    var scene = "all"
    var resetEpoch: UInt64 = 0
    var selection: String? = nil
    var revisions: [NativeOverviewLayoutRevision] = []
    var toolbarBottom: Double { 58 }
    @ObservationIgnored var viewport = CGSize.zero
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var sampleTimes: [String: TimeInterval] = [:]
    @ObservationIgnored var appearances: [String: Int] = [:]
    @ObservationIgnored var consumed: [UInt64] = []
    @ObservationIgnored var presentations: [String: String] = [:]
    @ObservationIgnored var slowMountIDs = Set<String>()
    @ObservationIgnored var delayedMounts = Set<String>()
    @ObservationIgnored var observedItems: [NativeOverviewItem] = []
}

private struct TransitionCanvas: View {
    let fixture: TransitionFixture
    var body: some View {
        NativeOverviewCanvas(items: fixture.items, sceneKey: fixture.scene, state: fixture.state,
            selectionID: fixture.selection, resetEpoch: fixture.resetEpoch,
            revisions: fixture.revisions, onRevisionsConsumed: { fixture.consumed.append($0) }) { item in
            slowCard(item)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("transitions")) } action: { fixture.frames[item.id] = $0; fixture.sampleTimes[item.id] = ProcessInfo.processInfo.systemUptime }
                .onAppear { fixture.appearances[item.id, default: 0] += 1 }
                .onChange(of: item.presentationID, initial: true) { _, value in fixture.presentations[item.id] = value }
        }.coordinateSpace(name: "transitions")
            .onGeometryChange(for: CGSize.self) { $0.size } action: { fixture.viewport = $0 }
            .onChange(of: fixture.items, initial: true) { _, value in fixture.observedItems = value }
    }

    private func slowCard(_ item: NativeOverviewItem) -> some View {
        // Model first construction of a dense set of real semantic cards. Block
        // once per identity, so animation ticks themselves remain inexpensive.
        if fixture.slowMountIDs.contains(item.id), fixture.delayedMounts.insert(item.id).inserted {
            Thread.sleep(forTimeInterval: 0.04)
        }
        return Color.red
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeOverviewTransitionTests {
    private func setup(_ fixture: TransitionFixture) async throws -> NSWindow {
        let window = SwiftUIReplay.window(TransitionCanvas(fixture: fixture))
        try await settled(fixture)
        fixture.state.camera.setManualTransform(.init(scale: 1, x: 50, y: 100))
        try await Task.sleep(for: .milliseconds(40))
        return window
    }
    private func settled(_ fixture: TransitionFixture) async throws {
        try await SwiftUIReplay.wait {
            fixture.viewport.width > 0 && fixture.viewport.height > 0 &&
            !fixture.state.isLayingOut && Set(fixture.state.presentedPlacements.map(\.id)) == Set(fixture.items.map(\.id)) &&
            fixture.items.allSatisfy { fixture.frames[$0.id] != nil }
        }
    }
    private func frame(_ id: String, _ fixture: TransitionFixture) throws -> CGRect {
        try #require(fixture.frames[id])
    }

    private func contentRect(_ fixture: TransitionFixture) throws -> NativeOverviewContentRect {
        let placements = fixture.state.presentedPlacements
        let column = try #require(placements.map(\.column).min())
        let row = try #require(placements.map(\.row).min())
        let columns = (placements.map { $0.column + $0.columns }.max() ?? 0) - column
        let rows = (placements.map { $0.row + $0.rows }.max() ?? 0) - row
        return .init(left: Double(column) * 376, top: Double(row) * 216,
                     width: Double(columns) * 360 + Double(columns - 1) * 16,
                     height: Double(rows) * 200 + Double(rows - 1) * 16)
    }

    private func expectAnchored(_ fixture: TransitionFixture) throws {
        let content = try contentRect(fixture)
        let transform = fixture.state.camera.liveTransform
        expectCameraAnchored(content, in: transform, viewport: fixtureViewport(fixture))
    }

    private func fixtureViewport(_ fixture: TransitionFixture) -> NativeOverviewViewport {
        .init(width: fixture.viewport.width, height: fixture.viewport.height,
              toolbarBottom: fixture.toolbarBottom)
    }

    /// Assert the settled screen frames themselves, not just the camera target.
    private func expectRenderedAnchor(_ fixture: TransitionFixture,
                                      sourceLocation: SourceLocation = #_sourceLocation) throws {
        let measured = try fixture.items.map { try #require(fixture.frames[$0.id], sourceLocation: sourceLocation) }
            .reduce(CGRect.null) { $0.union($1) }
        let viewport = fixtureViewport(fixture)
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        let expectedY = region.top + region.height / 2
        #expect(abs(measured.midX - viewport.width / 2) < 0.5, sourceLocation: sourceLocation)
        #expect(abs(measured.midY - expectedY) < 0.5, sourceLocation: sourceLocation)
    }

    private func redness(_ window: NSWindow, at frame: CGRect) throws -> Double {
        let root = try #require(window.contentView)
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let x = Int(frame.midX / root.bounds.width * Double(bitmap.pixelsWide))
        let yPoint = root.isFlipped ? frame.midY : root.bounds.height - frame.midY
        let y = Int(yPoint / root.bounds.height * Double(bitmap.pixelsHigh))
        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return (color.redComponent - color.greenComponent) * color.alphaComponent
    }

    @Test func recoveryDuringEntryFinishesEveryMountedCard() async throws {
        let fixture = TransitionFixture()
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        fixture.items += [.init(id: "c"), .init(id: "d")]
        try await SwiftUIReplay.wait {
            fixture.state.isLayingOut && fixture.state.presentedPlacements.count == 4 &&
            fixture.frames["d"] != nil
        }
        // The second entrant is mounted but still transparent while the first
        // enters. Recovery cancels that owner without changing the geometry.
        try await Task.sleep(for: .milliseconds(45))
        fixture.resetEpoch += 1
        try await settled(fixture)
        try await Task.sleep(for: .milliseconds(750))
        #expect(fixture.state.mountedCardIDs == Set(fixture.items.map(\.id)))
        #expect(try redness(window, at: frame("d", fixture)) > 0.2)
        #expect(fixture.state.allowsActivation(cardID: "d"))
    }

    @Test func ordinaryExitFinishesBeforeReflowAndEntryRisesWithoutScaling() async throws {
        let fixture = TransitionFixture()
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        let a = try frame("a", fixture), b = try frame("b", fixture)
        let originalRedness = try redness(window, at: a)
        #expect(originalRedness > 0.2)
        fixture.items = [.init(id: "b"), .init(id: "c")]
        try await SwiftUIReplay.wait { fixture.state.isLayingOut && fixture.state.presentedPlacements.contains { $0.id == "c" } }
        try await Task.sleep(for: .milliseconds(45))
        let exiting = try frame("a", fixture)
        #expect(exiting.width < a.width && exiting.width > a.width * 0.979)
        #expect(exiting.midY < a.midY)
        #expect(try redness(window, at: exiting) < originalRedness * 0.8)
        #expect(try frame("b", fixture) == b)
        #expect(fixture.state.mountedCardIDs.contains("a"))
        #expect(!fixture.state.allowsActivation(cardID: "a"))
        try await SwiftUIReplay.wait { !fixture.state.mountedCardIDs.contains("a") && fixture.frames["c"] != nil }
        let target = try #require(fixture.state.presentedPlacements.first { $0.id == "c" })
        let transform = fixture.state.camera.liveTransform
        let targetY = transform.y + target.cardFrame.minY * transform.scale
        try await SwiftUIReplay.wait { (fixture.frames["c"]?.minY ?? 0) > targetY + 0.1 }
        #expect(abs(try frame("c", fixture).width - target.cardFrame.width * transform.scale) < 0.5)
        try await settled(fixture)
        #expect(fixture.state.mountedCardIDs == ["b", "c"])
        #expect(fixture.appearances["b"] == 1)
        #expect(fixture.state.allowsActivation(cardID: "c"))
    }

    @Test func filterUsesScreenSpaceEntryAndRapidReversalRetainsSurvivors() async throws {
        let fixture = TransitionFixture()
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        let before = try frame("b", fixture)
        fixture.items = [.init(id: "b"), .init(id: "c")]; fixture.scene = "filtered"
        try await SwiftUIReplay.wait { fixture.state.isLayingOut && fixture.frames["c"] != nil }
        let target = try #require(fixture.state.presentedPlacements.first { $0.id == "c" })
        let transform = fixture.state.camera.liveTransform
        let targetY = transform.y + target.cardFrame.minY * transform.scale
        let entering = try frame("c", fixture)
        #expect(abs(entering.width - target.cardFrame.width * transform.scale * 0.94) < 0.5)
        #expect(abs(entering.midY - (targetY + target.cardFrame.height * transform.scale / 2 + 12)) < 0.5)
        // The survivor starts from the old screen frame despite the camera cut.
        #expect(abs(try frame("b", fixture).minX - before.minX) < 1)
        try await Task.sleep(for: .milliseconds(95))
        let interrupted = try frame("b", fixture)
        let sampledAt = try #require(fixture.sampleTimes["b"])
        let survivorTarget = try #require(fixture.state.presentedPlacements.first { $0.id == "b" })
        let travel = abs(transform.x + survivorTarget.cardFrame.minX * transform.scale - before.minX)
        fixture.items = [.init(id: "a"), .init(id: "b")]; fixture.scene = "all"
        try await SwiftUIReplay.wait { fixture.state.presentedPlacements.contains { $0.id == "a" } }
        let resumed = try frame("b", fixture)
        // Bound forward travel by the historical curve's maximum slope (1/.22),
        // using the actual observation interval plus one display frame. A fixed
        // point tolerance mistakes ordinary fast motion for a discontinuity.
        let elapsed = (fixture.sampleTimes["b"] ?? sampledAt) - sampledAt + 1.0 / 60
        #expect(abs(resumed.minX - interrupted.minX) <= travel / 0.32 / 0.22 * elapsed + 2)
        #expect(abs(resumed.width - interrupted.width) <= abs(before.width - 360 * transform.scale) / 0.32 / 0.22 * elapsed + 2)
        try await settled(fixture)
        #expect(fixture.appearances["b"] == 1)
        #expect(fixture.state.mountedCardIDs == ["a", "b"])
    }

    @Test(arguments: [false, true])
    func compactFilterKeepsVisibleSurvivorAndCamera(manual: Bool) async throws {
        let fixture = TransitionFixture()
        fixture.selection = "all"
        let window = SwiftUIReplay.window(TransitionCanvas(fixture: fixture))
        defer { window.close(); fixture.state.camera.dispose() }
        try await settled(fixture)
        if manual { fixture.state.camera.setManualTransform(.init(scale: 1, x: 50, y: 100)) }
        try await Task.sleep(for: .milliseconds(750))
        let before = try frame("b", fixture)
        let camera = fixture.state.camera.liveTransform
        for selection in ["tag-one", "tag-two", "all"] {
            fixture.items = [.init(id: "b"), .init(id: selection == "all" ? "a" : selection)]
            fixture.scene = selection; fixture.selection = selection
            try await SwiftUIReplay.wait { fixture.state.mountedCardIDs == Set(fixture.items.map(\.id)) && !fixture.state.isLayingOut }
            // Include the throttled refit window, rather than just animation end.
            try await Task.sleep(for: .milliseconds(750))
            let after = try frame("b", fixture)
            #expect(abs(after.minX - before.minX) < 1)
            #expect(abs(after.minY - before.minY) < 1)
            #expect(abs(after.width - before.width) < 1)
            #expect(fixture.state.camera.liveTransform == camera)
            #expect(fixture.state.camera.manual == manual)
            let placements = fixture.state.presentedPlacements
            #expect(placements.map(\.column).max() == placements.map(\.column).min())
            #expect(placements.map(\.row).max()! - placements.map(\.row).min()! == 1)
            #expect(fixture.state.layoutError == nil)
        }
        #expect(fixture.appearances["b"] == 1)
    }

    @Test func compactFilterRecentersChangedContentAtTheRetainedScale() async throws {
        let fixture = TransitionFixture()
        fixture.selection = "all"
        fixture.items = [.init(id: "a"), .init(id: "b")]
        let window = SwiftUIReplay.window(TransitionCanvas(fixture: fixture))
        defer { window.close(); fixture.state.camera.dispose() }
        try await settled(fixture)
        try await Task.sleep(for: .milliseconds(750))
        let before = fixture.state.camera.liveTransform
        let beforeA = try frame("a", fixture)
        #expect(!fixture.state.camera.manual)
        try expectRenderedAnchor(fixture)

        // Grow one column from two rows to three. Both survivors keep their
        // world slots, so only the new footprint's framing anchor changes.
        fixture.items = [.init(id: "a"), .init(id: "b"), .init(id: "c")]
        fixture.scene = "three"; fixture.selection = "three"
        try await SwiftUIReplay.wait { fixture.state.mountedCardIDs == ["a", "b", "c"] && !fixture.state.isLayingOut }
        try await Task.sleep(for: .milliseconds(750))
        #expect(!fixture.state.camera.manual)
        #expect(fixture.state.camera.liveTransform.scale == before.scale)
        try expectAnchored(fixture)
        try expectRenderedAnchor(fixture)
        #expect(fixture.state.presentedPlacements.first { $0.id == "a" }?.row == 0)
        #expect(fixture.state.presentedPlacements.first { $0.id == "b" }?.row == 1)
        #expect(fixture.state.presentedPlacements.first { $0.id == "c" }?.row == 2)
        #expect(abs(try frame("a", fixture).width - beforeA.width) < 1)

        // Shrink back to two rows; the retained scale still holds.
        fixture.items = [.init(id: "a"), .init(id: "b")]
        fixture.scene = "two"; fixture.selection = "two"
        try await SwiftUIReplay.wait { fixture.state.mountedCardIDs == ["a", "b"] && !fixture.state.isLayingOut }
        try await Task.sleep(for: .milliseconds(750))
        #expect(fixture.state.camera.liveTransform.scale == before.scale)
        try expectAnchored(fixture)
        try expectRenderedAnchor(fixture)
        let shrunkA = try frame("a", fixture)
        #expect(abs(shrunkA.width - beforeA.width) < 1)
        #expect(abs(shrunkA.minX - beforeA.minX) < 1)
        #expect(fixture.state.layoutError == nil)
    }

    @Test func compactFilterDoesNotRecenterManualFraming() async throws {
        let fixture = TransitionFixture()
        fixture.selection = "all"
        fixture.items = [.init(id: "a"), .init(id: "b")]
        let window = SwiftUIReplay.window(TransitionCanvas(fixture: fixture))
        defer { window.close(); fixture.state.camera.dispose() }
        try await settled(fixture)
        let manual = NativeOverviewTransform(scale: 1, x: 50, y: 100)
        fixture.state.camera.setManualTransform(manual)
        try await Task.sleep(for: .milliseconds(40))
        fixture.items = [.init(id: "a"), .init(id: "b"), .init(id: "c")]
        fixture.scene = "three"; fixture.selection = "three"
        try await SwiftUIReplay.wait { fixture.state.mountedCardIDs == ["a", "b", "c"] && !fixture.state.isLayingOut }
        try await Task.sleep(for: .milliseconds(750))
        #expect(fixture.state.camera.manual)
        #expect(fixture.state.camera.liveTransform == manual)
        // The footprint did change, so the unchanged camera proves the manual
        // carve-out rather than an unchanged-bounds early return.
        #expect(fixture.state.presentedPlacements.contains { $0.row == 2 })
        #expect(fixture.state.layoutError == nil)
    }

    @Test func filterWithoutVisibleSurvivorsUsesFreshFraming() async throws {
        let fixture = TransitionFixture()
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        fixture.state.camera.setManualTransform(.init(scale: 1, x: -10_000, y: -10_000))
        try await Task.sleep(for: .milliseconds(40))
        fixture.items = [.init(id: "b")]; fixture.scene = "filtered"
        try await SwiftUIReplay.wait { fixture.state.mountedCardIDs == ["b"] && !fixture.state.isLayingOut }
        #expect(!fixture.state.camera.manual)
        #expect(fixture.state.camera.liveTransform.x > -1_000)
        #expect(fixture.state.presentedPlacements.first?.column == 0)
        #expect(fixture.state.presentedPlacements.first?.row == 0)
    }

    @Test(arguments: [false, true])
    func compactnessWinsWhileOffscreenHistoryDoesNotPullVisibleThreads(offscreen: Bool) async throws {
        let fixture = TransitionFixture()
        fixture.items = (0..<6).map { .init(id: "card-\($0)") }
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        let ordered = fixture.state.presentedPlacements.sorted {
            ($0.row, $0.column) < ($1.row, $1.column)
        }
        let first = try #require(ordered.first), last = try #require(ordered.last)
        // Natural-scale fitting can choose either 2×3 or 3×2. Opposite
        // corners in both axes still cannot survive in a compact two-card column.
        #expect(first.column != last.column && first.row != last.row)
        if offscreen {
            fixture.state.camera.setManualTransform(.init(scale: 1, x: 50, y: -250))
            try await Task.sleep(for: .milliseconds(40))
        }
        let before = try frame(last.id, fixture)
        fixture.items = [.init(id: first.id), .init(id: last.id)]
        fixture.scene = "compact-subset"
        try await SwiftUIReplay.wait { fixture.state.mountedCardIDs == [first.id, last.id] && !fixture.state.isLayingOut }
        try await Task.sleep(for: .milliseconds(750))
        let placements = fixture.state.presentedPlacements
        #expect(placements[0].column == placements[1].column)
        #expect(abs(placements[0].row - placements[1].row) == 1)
        if offscreen {
            let after = try frame(last.id, fixture)
            #expect(abs(after.minX - before.minX) < 1)
            #expect(abs(after.minY - before.minY) < 1)
        } else {
            // Both opposite corners cannot stay fixed in a compact two-card box.
            #expect(placements.contains { p in
                let old = p.id == first.id ? first : last
                return old.column != p.column || old.row != p.row
            })
        }
        #expect(fixture.state.layoutError == nil)
    }

    @Test func denseFilterEntryKeepsItsAnimationAfterSlowMounting() async throws {
        let fixture = TransitionFixture()
        fixture.items = [.init(id: "a")]
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        let newItems = (0..<12).map { NativeOverviewItem(id: "dense-\($0)") }
        fixture.slowMountIDs = Set(newItems.map(\.id))
        fixture.items += newItems
        fixture.scene = "dense-filter"
        try await SwiftUIReplay.wait { fixture.frames["dense-0"] != nil }
        let target = try #require(fixture.state.presentedPlacements.first { $0.id == "dense-0" })
        let transform = fixture.state.camera.liveTransform
        let targetWidth = target.cardFrame.width * transform.scale
        // The 480ms mount exceeds the whole 390ms filter window. It must not
        // consume the animation before the first laid-out frame exists.
        let first = try frame("dense-0", fixture)
        #expect(first.width < targetWidth * 0.99)
        #expect(fixture.state.isLayingOut)
        try await SwiftUIReplay.wait {
            guard let current = fixture.frames["dense-0"] else { return false }
            return current.width > first.width + 0.5 && current.width < targetWidth - 0.1
        }
        try await settled(fixture)
        #expect(abs(try frame("dense-0", fixture).width - targetWidth) < 0.5)
        #expect(fixture.appearances["a"] == 1)
    }

    @Test func ordinaryClearKeepsTheCameraUntilExitFinishes() async throws {
        let fixture = TransitionFixture()
        fixture.items = [.init(id: "a")]
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        let oldCamera = fixture.state.camera.liveTransform
        let before = try frame("a", fixture)
        fixture.items = []
        try await SwiftUIReplay.wait { fixture.state.isLayingOut }
        try await Task.sleep(for: .milliseconds(45))
        #expect(fixture.state.camera.liveTransform == oldCamera)
        let exiting = try frame("a", fixture)
        #expect(abs(exiting.midX - before.midX) < 1)
        #expect(exiting.midY < before.midY && exiting.midY > before.midY - 9)
        try await settled(fixture)
        #expect(fixture.state.mountedCardIDs.isEmpty)
        #expect(fixture.state.memory.current == nil)
    }

    @Test func ordinaryResizeShrinksBeforeItGrowsWithoutReplacingContent() async throws {
        let fixture = TransitionFixture()
        fixture.items = [.init(id: "a", columns: 2)]
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        let scale = fixture.state.camera.liveTransform.scale
        fixture.items = [.init(id: "a", rows: 2)]
        try await SwiftUIReplay.wait { fixture.state.isLayingOut }
        try await Task.sleep(for: .milliseconds(45))
        let shrinking = try frame("a", fixture)
        #expect(shrinking.width > 360 * scale && shrinking.width < 736 * scale)
        #expect(abs(shrinking.height - 200 * scale) < 0.5)
        try await SwiftUIReplay.wait { (fixture.frames["a"]?.height ?? 0) > 205 * scale }
        #expect(abs(try frame("a", fixture).width - 360 * scale) < 0.5)
        try await settled(fixture)
        #expect(fixture.appearances["a"] == 1)
        #expect(abs(try frame("a", fixture).height - 416 * scale) < 0.5)
    }

    @Test func queuedLayoutDoesNotRestoreStaleCardContent() async throws {
        let fixture = TransitionFixture()
        fixture.items = [.init(id: "a")]
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        let stage = try await fixture.state.motionStages.acquire(owner: "test-blocker")
        defer { stage.release() }
        fixture.items.append(.init(id: "new", presentationID: "old-content"))
        try await SwiftUIReplay.wait { fixture.state.isLayingOut }
        fixture.items[1].presentationID = "latest-content"
        try await SwiftUIReplay.wait { fixture.observedItems.last?.presentationID == "latest-content" }
        stage.release()
        try await settled(fixture)
        #expect(fixture.presentations["new"] == "latest-content")
        #expect(fixture.appearances["a"] == 1)
    }

    @Test func aNewRevisionDoesNotInterruptAnEntryAlreadyInFlight() async throws {
        let fixture = TransitionFixture()
        fixture.items = [.init(id: "a")]
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        let next = [NativeOverviewItem(id: "a"), .init(id: "temporary")]
        fixture.items = next
        fixture.revisions = [.init(revision: 1, sceneKey: fixture.scene, items: next)]
        try await SwiftUIReplay.wait { fixture.frames["temporary"] != nil && fixture.state.isLayingOut }
        let before = try frame("temporary", fixture)
        // Append while the first entry is rising, rather than submitting an
        // already complete batch. The first revision must finish its own beat.
        try await Task.sleep(for: .milliseconds(40))
        let final = [NativeOverviewItem(id: "a"), .init(id: "instant")]
        fixture.items = final
        fixture.revisions.append(.init(revision: 2, sceneKey: fixture.scene, items: final, instantEntryIDs: ["instant"]))
        try await SwiftUIReplay.wait { fixture.consumed.contains(1) }
        let after = try frame("temporary", fixture)
        #expect(after.minY < before.minY - 2)
        #expect(fixture.consumed.first == 1)
        try await SwiftUIReplay.wait { fixture.consumed == [1, 2] && !fixture.state.isLayingOut }
        #expect(fixture.appearances["a"] == 1)
        #expect(fixture.state.mountedCardIDs == ["a", "instant"])
    }

    @Test func queuedMembershipRevisionsAndInstantEntriesAreConsumedInOrder() async throws {
        let fixture = TransitionFixture()
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        let second = [NativeOverviewItem(id: "b"), .init(id: "temporary")]
        let final = [NativeOverviewItem(id: "b"), .init(id: "instant")]
        fixture.revisions = [
            .init(revision: 1, sceneKey: fixture.scene, items: second),
            .init(revision: 2, sceneKey: fixture.scene, items: final, instantEntryIDs: ["instant"]),
        ]
        fixture.items = final
        try await SwiftUIReplay.wait { fixture.consumed.count == 2 && !fixture.state.isLayingOut }
        #expect(fixture.consumed == [1, 2])
        #expect(fixture.appearances["temporary"] == 1)
        #expect(fixture.state.mountedCardIDs == ["b", "instant"])
        let target = try #require(fixture.state.presentedPlacements.first { $0.id == "instant" })
        let transform = fixture.state.camera.liveTransform
        #expect(abs(try frame("instant", fixture).minY - (transform.y + target.cardFrame.minY * transform.scale)) < 0.5)
        #expect(fixture.appearances["b"] == 1)
    }
}
