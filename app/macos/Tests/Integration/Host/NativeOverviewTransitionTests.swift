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
    let content = NativeOverviewContentStore(items: [.init(id: "a"), .init(id: "b")])
    var items: [NativeOverviewItem] {
        get { content.items }
        set { content.install(newValue) }
    }
    var scene = "all"
    var resetEpoch: UInt64 = 0
    var selection: String? = nil
    var revisions: [NativeOverviewLayoutRevision] = []
    var locale = Locale(identifier: "en")
    var toolbarBottom: Double { 58 }
    @ObservationIgnored var viewport = CGSize.zero
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var sampleTimes: [String: TimeInterval] = [:]
    @ObservationIgnored var appearances: [String: Int] = [:]
    @ObservationIgnored var consumed: [UInt64] = []
    @ObservationIgnored var presentations: [String: String] = [:]
    @ObservationIgnored var semanticIdentities: [String: UUID] = [:]
    @ObservationIgnored var semanticLocales: [String: String] = [:]
    @ObservationIgnored var slowMountIDs = Set<String>()
    @ObservationIgnored var delayedMounts = Set<String>()
    @ObservationIgnored var presentationHistory: [String: [String]] = [:]
    @ObservationIgnored var entrySource1At: TimeInterval?
    @ObservationIgnored var geometryObserver: (@MainActor (String, CGRect, TimeInterval) -> Void)?
    @ObservationIgnored var revisionObserver: (@MainActor (UInt64, TimeInterval) -> Void)?
}

private struct TransitionCanvas: View {
    let fixture: TransitionFixture
    var body: some View {
        NativeOverviewCanvas(contentSource: fixture.content, sceneKey: fixture.scene, state: fixture.state,
            selectionID: fixture.selection, resetEpoch: fixture.resetEpoch,
            revisions: fixture.revisions, onRevisionsConsumed: { revision in
                fixture.consumed.append(revision)
                fixture.revisionObserver?(revision, ProcessInfo.processInfo.systemUptime)
            }) { item in
            slowCard(item)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("transitions")) } action: { frame in
                    let now = ProcessInfo.processInfo.systemUptime
                    fixture.frames[item.id] = frame; fixture.sampleTimes[item.id] = now
                    fixture.geometryObserver?(item.id, frame, now)
                }
                .onAppear { fixture.appearances[item.id, default: 0] += 1 }
                .onChange(of: item.presentationID, initial: true) { _, value in
                    fixture.presentations[item.id] = value
                    fixture.presentationHistory[item.id, default: []].append(value)
                }
        }.coordinateSpace(name: "transitions")
            .environment(\.locale, fixture.locale)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { fixture.viewport = $0 }
    }

    private func slowCard(_ item: NativeOverviewItem) -> some View {
        // Model first construction of a dense set of real semantic cards. Block
        // once per identity, so animation ticks themselves remain inexpensive.
        if fixture.slowMountIDs.contains(item.id), fixture.delayedMounts.insert(item.id).inserted {
            Thread.sleep(forTimeInterval: 0.04)
        }
        return TransitionSemanticCard(id: item.id, fixture: fixture)
    }
}

private struct TransitionSemanticCard: View {
    let id: String
    let fixture: TransitionFixture
    @State private var identity = UUID()
    @Environment(\.locale) private var locale

    var body: some View {
        Color.red
            .onAppear { fixture.semanticIdentities[id] = identity }
            .onChange(of: locale.identifier, initial: true) { _, value in
                fixture.semanticLocales[id] = value
            }
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
        let replacedAt = ProcessInfo.processInfo.systemUptime
        fixture.items = [.init(id: "b"), .init(id: "c")]
        var sample: (exiting: CGRect, survivor: CGRect, interactive: Bool)?
        try await SwiftUIReplay.wait {
            guard fixture.state.isLayingOut, fixture.state.mountedCardIDs.contains("a"),
                  fixture.state.presentedPlacements.contains(where: { $0.id == "c" }),
                  (fixture.sampleTimes["a"] ?? 0) > replacedAt,
                  // The exit targets 0.98x. Observe its second half before
                  // checking the corresponding fade, rather than its first tick.
                  let current = fixture.frames["a"], current.width < a.width * 0.99,
                  let survivor = fixture.frames["b"] else { return false }
            sample = (current, survivor, fixture.state.allowsActivation(cardID: "a"))
            return true
        }
        let captured = try #require(sample)
        let exiting = captured.exiting
        #expect(exiting.width < a.width && exiting.width > a.width * 0.979)
        #expect(exiting.midY < a.midY)
        #expect(captured.survivor == b)
        #expect(!captured.interactive)
        // Capture can pump AppKit's drawing loop. Assert the retained exit
        // state above, without reading a later lifecycle phase after readback.
        #expect(try redness(window, at: exiting) < originalRedness * 0.8)
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
            #expect(fixture.state.memory.current?.sceneKey == selection)
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
        let clearedAt = ProcessInfo.processInfo.systemUptime
        fixture.items = []
        var sample: (NativeOverviewTransform, CGRect)?
        // Sleep only sets a minimum delay: a busy runner can resume after the
        // exit has completed. Sample the camera and a still-mounted moving
        // card in the same main-actor turn, before checking either assertion.
        try await SwiftUIReplay.wait {
            guard fixture.state.isLayingOut, fixture.state.mountedCardIDs.contains("a"),
                  (fixture.sampleTimes["a"] ?? 0) > clearedAt,
                  let current = fixture.frames["a"], current.midY < before.midY,
                  current.midY > before.midY - 9 else { return false }
            sample = (fixture.state.camera.liveTransform, current)
            return true
        }
        let (camera, exiting) = try #require(sample)
        #expect(camera == oldCamera)
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
        let identity = try #require(fixture.semanticIdentities["a"])
        fixture.items = [.init(id: "a", rows: 2)]
        var sample: CGRect?
        try await SwiftUIReplay.wait {
            guard fixture.state.isLayingOut, let current = fixture.frames["a"],
                  current.width > 360 * scale, current.width < 736 * scale else { return false }
            sample = current
            return true
        }
        let shrinking = try #require(sample)
        #expect(shrinking.width > 360 * scale && shrinking.width < 736 * scale)
        #expect(abs(shrinking.height - 200 * scale) < 0.5)
        fixture.items[0].presentationID = "content-during-resize"
        fixture.locale = Locale(identifier: "ja")
        try await SwiftUIReplay.wait {
            fixture.presentations["a"] == "content-during-resize" && fixture.semanticLocales["a"] == "ja"
        }
        try await SwiftUIReplay.wait { (fixture.frames["a"]?.height ?? 0) > 205 * scale }
        #expect(abs(try frame("a", fixture).width - 360 * scale) < 0.5)
        try await settled(fixture)
        #expect(fixture.appearances["a"] == 1)
        #expect(fixture.semanticIdentities["a"] == identity)
        #expect(fixture.presentations["a"] == "content-during-resize")
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
        // The admitted content store is synchronous: no intervening render
        // turn may be required before a queued layout uses the newest content.
        stage.release()
        try await settled(fixture)
        #expect(fixture.presentations["new"] == "latest-content")
        #expect(fixture.appearances["a"] == 1)
    }

    @Test func queuedIncompatibleFootprintKeepsTheLastMountedContent() async throws {
        let fixture = TransitionFixture()
        fixture.items = [.init(id: "a", presentationID: "initial-small")]
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        fixture.items[0].presentationID = "latest-small"
        try await SwiftUIReplay.wait { fixture.presentations["a"] == "latest-small" }
        let stage = try await fixture.state.motionStages.acquire(owner: "content-boundary")
        defer { stage.release() }
        fixture.items = [.init(id: "a", columns: 2, presentationID: "initial-wide")]
        try await SwiftUIReplay.wait { fixture.state.isLayingOut }
        fixture.items[0].presentationID = "latest-wide"
        #expect(fixture.presentations["a"] == "latest-small")
        #expect(fixture.content.retainedPresentationIDs.contains("latest-small"))
        stage.release()
        try await settled(fixture)
        try await SwiftUIReplay.wait { fixture.presentations["a"] == "latest-wide" }
        #expect(fixture.appearances["a"] == 1)
        #expect(!fixture.content.retainedPresentationIDs.contains("latest-small"))
    }

    @Test func queuedFootprintReversalPreservesFIFOAndLatestContent() async throws {
        let fixture = TransitionFixture()
        fixture.items = [.init(id: "a", presentationID: "initial-small")]
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        let wide = [NativeOverviewItem(id: "a", columns: 2, presentationID: "queued-wide")]
        let latest = [NativeOverviewItem(id: "a", presentationID: "latest-small")]
        fixture.revisions = [
            .init(revision: 1, sceneKey: fixture.scene, items: wide),
            .init(revision: 2, sceneKey: fixture.scene, items: latest),
        ]
        fixture.items = latest
        try await SwiftUIReplay.wait { fixture.consumed == [1, 2] && !fixture.state.isLayingOut }
        #expect(fixture.presentationHistory["a"]?.contains("queued-wide") == true)
        #expect(fixture.presentations["a"] == "latest-small")
        #expect(fixture.appearances["a"] == 1)
        #expect(fixture.state.presentedPlacements.first?.columns == 1)
    }

    @Test func aNewRevisionDoesNotInterruptAnEntryAlreadyInFlight() async throws {
        let fixture = TransitionFixture()
        fixture.items = [.init(id: "a")]
        let window = try await setup(fixture)
        defer { window.close(); fixture.state.camera.dispose() }
        typealias GeometryReceipt = (frame: CGRect, targetY: Double, camera: NativeOverviewTransform, at: TimeInterval)
        var previous: GeometryReceipt?
        var precedingInjection: GeometryReceipt?
        var beforeInjection: GeometryReceipt?
        var latestAfterInjection: GeometryReceipt?
        var beforeFirstConsumption: GeometryReceipt?
        var source2At: TimeInterval?
        var source2CommittedAt: TimeInterval?
        var consumed1At: TimeInterval?
        var samples: [[String: Any]] = []
        var consumed: [[String: Any]] = []
        var droppedSamples = 0
        let camera = fixture.state.camera.liveTransform
        let final = [NativeOverviewItem(id: "a"), .init(id: "instant")]

        @MainActor func describe(_ sample: GeometryReceipt?) -> Any {
            guard let sample else { return NSNull() }
            return ["at": sample.at, "x": Double(sample.frame.minX), "y": Double(sample.frame.minY),
                    "width": Double(sample.frame.width), "height": Double(sample.frame.height),
                    "targetY": sample.targetY, "remainingY": Double(sample.frame.minY) - sample.targetY,
                    "cameraX": sample.camera.x, "cameraY": sample.camera.y, "cameraScale": sample.camera.scale]
        }
        @MainActor func timestamp(_ value: TimeInterval?) -> Any {
            if let value { return value }
            return NSNull()
        }
        @MainActor func waitForReceipt(_ predicate: @MainActor () -> Bool, _ failure: String) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                if predicate() { return }
                // This case observes geometry callbacks without forcing layouts
                // in this or another window while entry is in flight.
                try await Task.sleep(for: .milliseconds(10))
            }
            let satisfied = predicate()
            try #require(satisfied, Comment(rawValue: failure))
        }
        defer {
            fixture.geometryObserver = nil; fixture.revisionObserver = nil
            let report: [String: Any] = ["source1At": timestamp(fixture.entrySource1At), "source2At": timestamp(source2At),
                "source2CommittedAt": timestamp(source2CommittedAt), "consumed1At": timestamp(consumed1At),
                "precedingInjection": describe(precedingInjection), "beforeInjection": describe(beforeInjection),
                "beforeFirstConsumption": describe(beforeFirstConsumption), "samples": samples,
                "droppedSamples": droppedSamples, "consumptions": consumed]
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                FileHandle.standardOutput.write(Data("OVERVIEW_ENTRY_REVISION_RECEIPTS ".utf8) + data + Data("\n".utf8))
            } catch {
                Issue.record(Comment(rawValue: "Could not encode entry revision receipts: \(error)"))
            }
        }
        fixture.geometryObserver = { [weak fixture] id, frame, now in
            guard let fixture, id == "temporary",
                  let target = fixture.state.presentedPlacements.first(where: { $0.id == id }) else { return }
            let transform = fixture.state.camera.liveTransform
            let sample: GeometryReceipt = (frame, transform.y + target.cardFrame.minY * transform.scale, transform, now)
            if samples.count < 64 {
                samples.append(["geometry": describe(sample), "isLayingOut": fixture.state.isLayingOut,
                                "consumed": fixture.consumed, "revision2Installed": source2CommittedAt != nil])
            } else { droppedSamples += 1 }
            let prior = previous
            previous = sample
            guard fixture.state.isLayingOut, !fixture.consumed.contains(1), transform == camera else { return }
            if let committed = source2CommittedAt {
                if now > committed, let beforeInjection, sample.targetY == beforeInjection.targetY,
                   frame.minY >= sample.targetY {
                    latestAfterInjection = sample
                }
                return
            }
            guard source2At == nil, let prior, let source1At = fixture.entrySource1At, prior.at > source1At, now > prior.at,
                  prior.camera == transform, prior.targetY == sample.targetY,
                  frame.minY < prior.frame.minY, frame.minY - sample.targetY >= 4 else { return }
            // Two observed frames prove upward motion. Keeping at least 4pt
            // leaves 2pt of margin beyond the unchanged >2pt assertion. A fixed
            // 40ms delay after polling could instead inject at the endpoint.
            precedingInjection = prior; beforeInjection = sample
            source2At = ProcessInfo.processInfo.systemUptime
            fixture.items = final
            fixture.revisions.append(.init(revision: 2, sceneKey: fixture.scene, items: final, instantEntryIDs: ["instant"]))
            source2CommittedAt = ProcessInfo.processInfo.systemUptime
        }
        fixture.revisionObserver = { revision, now in
            consumed.append(["revision": revision, "at": now, "lastEntryGeometry": describe(latestAfterInjection)])
            if revision == 1 {
                consumed1At = now
                // Freeze only observed entry geometry before this consumption;
                // a later revision's exit cannot supply the displacement.
                beforeFirstConsumption = latestAfterInjection
            }
        }
        let next = [NativeOverviewItem(id: "a"), .init(id: "temporary")]
        fixture.entrySource1At = ProcessInfo.processInfo.systemUptime
        fixture.items = next
        fixture.revisions = [.init(revision: 1, sceneKey: fixture.scene, items: next)]
        try await waitForReceipt({ source2CommittedAt != nil },
            "Entry observation incomplete: no two rising frames with at least 4pt remaining before revision 1 completed")
        try await waitForReceipt({ consumed1At != nil }, "Revision 1 was not consumed after the in-flight injection")
        let beforeSample = try #require(beforeInjection)
        let afterSample = try #require(beforeFirstConsumption,
            "Entry observation incomplete: no actual geometry after revision 2 injection and before revision 1 consumption")
        let committedAt = try #require(source2CommittedAt)
        let consumedAt = try #require(consumed1At)
        try #require(afterSample.at > committedAt && afterSample.at < consumedAt)
        let before = beforeSample.frame
        let after = afterSample.frame
        #expect(after.minY < before.minY - 2)
        #expect(fixture.consumed.first == 1)
        try await waitForReceipt({ fixture.consumed == [1, 2] && !fixture.state.isLayingOut },
            "The queued revisions did not complete in FIFO order")
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
