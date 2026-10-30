import AppKit
import Observation
import SwiftUI
import Testing
import MokuseiPluginUI
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Observable private final class OverviewMountingFixture {
    let state = NativeOverviewCanvasState()
    let content = NativeOverviewContentStore()
    var items: [NativeOverviewItem] {
        get { content.items }
        set { content.install(newValue) }
    }
    var attached = true
    var glassWorld = true
    var visible = true
    var cloudAnimationsEnabled = false
    var selection = "all"
    @ObservationIgnored let inputIDs: Set<String>
    // Measurements must not themselves invalidate the canvas being measured.
    @ObservationIgnored var appearances: [String: Int] = [:]
    @ObservationIgnored var contentBuilds: [String: Int] = [:]
    @ObservationIgnored var visualIDs: [String: UUID] = [:]
    @ObservationIgnored var markerIDs: [String: UUID] = [:]
    @ObservationIgnored var drafts: [String: String] = [:]
    @ObservationIgnored var viewport = CGSize.zero
    @ObservationIgnored var animationVisibility: [String: Bool] = [:]
    @ObservationIgnored var cloudAnimations: [String: Bool] = [:]

    init(items: [NativeOverviewItem], inputIDs: Set<String> = []) {
        self.inputIDs = inputIDs
        content.install(items)
    }
}

/// This AppKit marker observes real SwiftUI mounting; production keeps its native SwiftUI tree.
private struct OverviewMountingMarker: NSViewRepresentable {
    let id: String
    let fixture: OverviewMountingFixture
    func makeNSView(context: Context) -> NSView {
        fixture.markerIDs[id] = UUID()
        return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct OverviewMountingCard: View {
    let item: NativeOverviewItem
    private var id: String { item.id }
    let fixture: OverviewMountingFixture
    @State private var draft = ""
    @State private var visualID = UUID()
    @Environment(\.threadCardAnimationVisibility) private var animationVisibility
    @Environment(\.threadCardCloudAnimationsEnabled) private var cloudAnimationsEnabled
    var body: some View {
        fixture.contentBuilds[id, default: 0] += 1
        return VStack {
            Text(item.presentationID.isEmpty ? id : item.presentationID)
            if fixture.inputIDs.contains(id) {
                TextField("Draft", text: $draft)
                    .onChange(of: draft) { _, value in fixture.drafts[id] = value }
            }
            OverviewMountingMarker(id: id, fixture: fixture).frame(width: 1, height: 1)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            fixture.appearances[id, default: 0] += 1
            fixture.visualIDs[id] = visualID
            fixture.drafts[id] = draft
        }
        .onChange(of: animationVisibility?.isVisible, initial: true) { _, value in
            fixture.animationVisibility[id] = value ?? true
        }
        .onChange(of: cloudAnimationsEnabled, initial: true) { _, value in
            fixture.cloudAnimations[id] = value
        }
    }
}

private struct OverviewMountingReplay: View {
    let fixture: OverviewMountingFixture
    var body: some View {
        if fixture.attached {
            NativeOverviewCanvas(contentSource: fixture.content, sceneKey: "mounting", state: fixture.state,
                                 selectionID: fixture.selection, visible: fixture.visible,
                                 cloudAnimationsEnabled: fixture.cloudAnimationsEnabled,
                                 glassWorld: fixture.glassWorld) { item in
                OverviewMountingCard(item: item, fixture: fixture)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { fixture.viewport = $0 }
        } else {
            Color.clear
        }
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeOverviewMountingIntegrationTests {
    @Test func contentUpdatesReachOnlyTheirMountedCard() async throws {
        let fixture = OverviewMountingFixture(items: (0..<10).map {
            .init(id: "isolated-\($0)", presentationID: "Initial \($0)", completed: true)
        })
        let window = SwiftUIReplay.window(OverviewMountingReplay(fixture: fixture))
        defer { window.close(); fixture.state.camera.dispose() }
        try await settled(fixture)
        try await Task.sleep(for: .milliseconds(800))
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Initial 0") }
        let bodyUpdates = fixture.state.bodyEvaluationCount
        let solves = fixture.state.layoutSolveCount
        let constructions = fixture.contentBuilds
        let mounted = fixture.markerIDs
        for revision in 1...5 {
            fixture.items[0].presentationID = "Delivered \(revision)"
            try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Delivered \(revision)") }
            #expect(fixture.state.bodyEvaluationCount == bodyUpdates)
            #expect(fixture.state.layoutSolveCount == solves)
            for index in 1..<10 {
                #expect(fixture.contentBuilds["isolated-\(index)"] == constructions["isolated-\(index)"])
            }
        }
        #expect(fixture.markerIDs == mounted)
        #expect(fixture.appearances.values.allSatisfy { $0 == 1 })
        #expect(fixture.content.retainedPresentationIDs.contains("Delivered 5"))
    }

    @Test func viewportVisibilityIsIndependentOfCloudEffectsAndRetainsIdentity() async throws {
        let id = "card-000"
        let fixture = OverviewMountingFixture(items: [.init(id: id)])
        let window = SwiftUIReplay.window(OverviewMountingReplay(fixture: fixture))
        defer { window.close(); fixture.state.camera.dispose() }
        try await settled(fixture)
        try await SwiftUIReplay.wait { fixture.animationVisibility[id] == true && fixture.cloudAnimations[id] == false }
        let identities = fixture.markerIDs, appearances = fixture.appearances
        let transform = fixture.state.camera.transform
        fixture.state.camera.setManualTransform(.init(scale: 1, x: -100_000, y: -100_000))
        try await SwiftUIReplay.wait { fixture.animationVisibility[id] == false }
        fixture.state.camera.setManualTransform(transform)
        try await SwiftUIReplay.wait { fixture.animationVisibility[id] == true }
        fixture.visible = false
        try await SwiftUIReplay.wait { fixture.animationVisibility[id] == false }
        fixture.visible = true
        fixture.cloudAnimationsEnabled = true
        try await SwiftUIReplay.wait { fixture.animationVisibility[id] == true && fixture.cloudAnimations[id] == true }
        #expect(fixture.markerIDs == identities && fixture.appearances == appearances)
    }

    @Test func allCardsStayMountedAcrossPanZoomAndAutomaticFraming() async throws {
        let fixture = OverviewMountingFixture(items: cards() + [
            .init(id: "running", carouselEligible: true),
            .init(id: "attention", needsAttention: true),
            .init(id: "application"),
        ])
        let window = SwiftUIReplay.window(OverviewMountingReplay(fixture: fixture))
        defer { window.close(); fixture.state.camera.dispose() }
        try await settled(fixture)
        let identities = fixture.markerIDs
        let appearances = fixture.appearances
        fixture.state.camera.setManualTransform(.init(scale: 1, x: -100_000, y: -100_000))
        try await settled(fixture)
        #expect(fixture.markerIDs == identities)
        #expect(fixture.appearances == appearances)
        fixture.state.camera.returnToAuto()
        try await SwiftUIReplay.wait { fixture.state.camera.isAnimating }
        #expect(fixture.state.mountedCardIDs == Set(fixture.items.map(\.id)))
        try await settled(fixture)
        #expect(fixture.markerIDs == identities)
        #expect(fixture.appearances == appearances)
    }

    @Test func explicitReturnCorrectsVisibleAttentionCardInMountedCanvas() async throws {
        let fixture = OverviewMountingFixture(items: [.init(id: "running", carouselEligible: true)] + cards())
        let window = SwiftUIReplay.window(OverviewMountingReplay(fixture: fixture))
        defer { window.close(); fixture.state.camera.dispose() }
        try await settled(fixture)
        let camera = fixture.state.camera
        // Wait for the first attention step to finish translating, not merely
        // for its target id: a pre-motion gap still has the fitted composition.
        try await SwiftUIReplay.wait(timeout: .seconds(10)) {
            camera.carouselTargetID == "running" && !camera.isAnimating
                && fixture.state.motionStages.activeOwner == nil
                && attentionCenterError(id: "running", fixture: fixture) <= 1
        }
        let automatic = camera.transform
        // Leave the first attention card completely visible, shifted right/down.
        let placement = try #require(fixture.state.presentedPlacements.first { $0.id == "running" })
        let manual = NativeOverviewTransform(scale: 1, x: 500 - Double(placement.column) * 376,
                                             y: 300 - Double(placement.row) * 216)
        camera.setManualTransform(manual)
        try await settled(fixture)
        let identities = fixture.markerIDs
        camera.returnToAuto()
        try await SwiftUIReplay.wait(timeout: .seconds(10)) {
            !camera.isAnimating && camera.carouselTargetID == "running" && camera.transform == automatic
        }
        #expect(!camera.manual && camera.transform != manual)
        #expect(fixture.markerIDs == identities)
    }

    @Test func completedCardKeepsDraftAndNativeIdentityOffscreenAfterBlur() async throws {
        let id = "card-000"
        let fixture = OverviewMountingFixture(items: cards(), inputIDs: [id])
        let window = SwiftUIReplay.window(OverviewMountingReplay(fixture: fixture))
        defer { window.close(); fixture.state.camera.dispose() }
        try await settled(fixture)
        let root = try #require(window.contentView)
        let field = try #require(SwiftUIReplay.textField(in: root))
        let editor = try #require(SwiftUIReplay.editor(in: root))
        editor.insertText("保留草稿", replacementRange: .init(location: 0, length: 0))
        try await SwiftUIReplay.wait { fixture.drafts[id] == "保留草稿" }
        window.makeFirstResponder(nil)
        let identities = fixture.markerIDs
        let visualIDs = fixture.visualIDs
        let original = fixture.state.camera.transform
        fixture.state.camera.setManualTransform(.init(scale: 1, x: -100_000, y: -100_000))
        try await settled(fixture)
        #expect(SwiftUIReplay.textField(in: root) === field)
        #expect(field.stringValue == "保留草稿")
        fixture.state.camera.setManualTransform(original)
        try await settled(fixture)
        #expect(fixture.markerIDs == identities)
        #expect(fixture.visualIDs == visualIDs)
        #expect(SwiftUIReplay.textField(in: root) === field)
        #expect(field.stringValue == "保留草稿")
    }

    @Test func glassWorldChangesRetainMountedEditingAndSpatialState() async throws {
        let id = "card-000"
        let fixture = OverviewMountingFixture(items: Array(cards().prefix(4)), inputIDs: [id])
        let window = SwiftUIReplay.window(OverviewMountingReplay(fixture: fixture))
        defer { window.close(); fixture.state.camera.dispose() }
        try await settled(fixture)
        let root = try #require(window.contentView)
        let field = try #require(SwiftUIReplay.textField(in: root))
        let editor = try #require(SwiftUIReplay.editor(in: root))
        editor.insertText("玻璃切换保留草稿", replacementRange: .init(location: 0, length: 0))
        editor.setSelectedRange(.init(location: 2, length: 3))
        try await SwiftUIReplay.wait { fixture.drafts[id] == "玻璃切换保留草稿" }
        fixture.state.camera.setManualTransform(.init(scale: 0.9, x: 40, y: 100))
        try await settled(fixture)
        let transform = fixture.state.camera.liveTransform
        let placements = fixture.state.presentedPlacements
        let snapshots = fixture.state.sceneSnapshotCount
        let identities = fixture.markerIDs, visualIDs = fixture.visualIDs
        let appearances = fixture.appearances
        for glassWorld in [false, true, false, true] {
            fixture.glassWorld = glassWorld
            // A settled geometry predicate alone could succeed before SwiftUI
            // applies the material change; allow the update and glass animation.
            try await Task.sleep(for: .milliseconds(350))
            #expect(fixture.state.mountedCardIDs == Set(fixture.items.map(\.id)))
            #expect(fixture.markerIDs == identities && fixture.visualIDs == visualIDs)
            #expect(fixture.appearances == appearances)
            #expect(fixture.state.presentedPlacements == placements)
            #expect(fixture.state.sceneSnapshotCount == snapshots)
            #expect(fixture.state.camera.manual && fixture.state.camera.liveTransform == transform)
            #expect(fixture.selection == "all")
            #expect(SwiftUIReplay.textField(in: root) === field)
            #expect(window.firstResponder === editor)
            #expect(editor.selectedRange() == NSRange(location: 2, length: 3))
            #expect(field.stringValue == "玻璃切换保留草稿")
        }
        // New membership and filter transitions must use the current material
        // without replacing surviving native inputs or disturbing a manual view.
        fixture.glassWorld = false
        fixture.items.append(.init(id: "added", completed: true))
        try await settled(fixture)
        #expect(fixture.state.mountedCardIDs.contains("added"))
        #expect(fixture.markerIDs[id] == identities[id])
        #expect(fixture.state.camera.liveTransform == transform)
        fixture.items = [fixture.items[0], fixture.items[1]]
        fixture.selection = "filtered"
        try await SwiftUIReplay.wait { fixture.state.isLayingOut }
        // Retiring cards remain mounted while the same modifier changes.
        fixture.glassWorld = true
        #expect(fixture.state.mountedCardIDs.contains("added"))
        try await settled(fixture)
        #expect(fixture.state.mountedCardIDs == ["card-000", "card-001"])
        #expect(fixture.markerIDs[id] == identities[id])
        #expect(SwiftUIReplay.textField(in: root) === field)
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == NSRange(location: 2, length: 3))
        #expect(field.stringValue == "玻璃切换保留草稿")
        fixture.glassWorld = false
        fixture.items = []
        try await settled(fixture)
        #expect(fixture.state.mountedCardIDs.isEmpty)
        fixture.items = [.init(id: "after-empty", completed: true)]
        try await settled(fixture)
        #expect(fixture.state.mountedCardIDs == ["after-empty"])
        #expect(fixture.appearances["after-empty"] == 1)
    }

    @Test func nestedInteractionsRemainBalancedAcrossHostDetach() async throws {
        let fixture = OverviewMountingFixture(items: cards() + [.init(id: "running", carouselEligible: true)])
        let window = SwiftUIReplay.window(OverviewMountingReplay(fixture: fixture))
        defer { window.close(); fixture.state.camera.dispose() }
        try await settled(fixture)
        try await SwiftUIReplay.wait { fixture.state.camera.carouselTargetID != nil }
        let id = "card-000"
        fixture.state.beginInteraction(cardID: id)
        fixture.state.beginInteraction(cardID: id)
        #expect(fixture.state.camera.carouselPaused)
        fixture.state.endInteraction(cardID: id)
        #expect(fixture.state.camera.carouselPaused)
        fixture.attached = false
        try await SwiftUIReplay.wait { fixture.state.mountedCardIDs.isEmpty }
        fixture.state.beginInteraction(cardID: id)
        fixture.state.endInteraction(cardID: id)
        fixture.attached = true
        try await settled(fixture)
        #expect(fixture.state.interactionCardIDs == [id])
        fixture.state.endInteraction(cardID: id)
        #expect(fixture.state.interactionCardIDs.isEmpty)
        try await settled(fixture)
    }

    @Test func membershipRemovalStillUnmountsCardsAndRetainsSurvivors() async throws {
        let fixture = OverviewMountingFixture(items: Array(cards().prefix(4)))
        let window = SwiftUIReplay.window(OverviewMountingReplay(fixture: fixture))
        defer { window.close(); fixture.state.camera.dispose() }
        try await settled(fixture)
        let identities = fixture.markerIDs
        fixture.items.removeLast()
        try await settled(fixture)
        for item in fixture.items { #expect(fixture.markerIDs[item.id] == identities[item.id]) }
        fixture.items = []
        try await settled(fixture)
        #expect(fixture.state.mountedCardIDs.isEmpty)
    }

    private func attentionCenterError(id: String, fixture: OverviewMountingFixture) -> Double {
        guard fixture.viewport.width > 0, fixture.viewport.height > 0,
              let placement = fixture.state.presentedPlacements.first(where: { $0.id == id }) else {
            return .infinity
        }
        let viewport = NativeOverviewViewport(width: fixture.viewport.width, height: fixture.viewport.height,
                                              toolbarBottom: 58)
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        let transform = fixture.state.camera.liveTransform
        let frame = placement.cardFrame
        let centerX = transform.x + (frame.midX) * transform.scale
        let centerY = transform.y + (frame.midY) * transform.scale
        return max(abs(centerX - (region.left + region.width / 2)),
                   abs(centerY - (region.top + region.height / 2)))
    }

    private func cards() -> [NativeOverviewItem] {
        (0..<64).map { .init(id: String(format: "card-%03d", $0), completed: true) }
    }
    private func settled(_ fixture: OverviewMountingFixture) async throws {
        try await SwiftUIReplay.wait(timeout: .seconds(10)) {
            !fixture.state.isLayingOut && !fixture.state.camera.isAnimating
                && Set(fixture.state.presentedPlacements.map(\.id)) == Set(fixture.items.map(\.id))
                && fixture.state.mountedCardIDs == Set(fixture.items.map(\.id))
                && fixture.state.layoutError == nil
                && (fixture.items.first.map { fixture.state.allowsActivation(cardID: $0.id) } ?? true)
        }
    }
}

@MainActor @Observable private final class OverviewCardVisualFixture {
    let visibility = ThreadCardAnimationVisibility()
    let startedAt = Date().timeIntervalSince1970 * 1_000 - 10_000
    var endedAt: Double?
    var suppliesVisibility = true
    var scenePhase = ScenePhase.active
    var animationsEnabled = true
    @ObservationIgnored var appearances = 0
}

private struct OverviewCardVisualReplay: View {
    let fixture: OverviewCardVisualFixture
    var decoration: Int?
    var body: some View {
        Group {
            switch decoration {
            case 0:
                CardDerivedWork(rows: [.init(id: "derived", label: "Running child", status: .running, kind: .agent)],
                                variant: .compact, capacity: 1)
            case 1:
                CardInterventionPanel(intervention: .init(id: "permission", title: "Permission",
                    actions: [.init(id: "allow", label: "Allow")]), variant: .compact, onRespond: { _ in })
            case 2:
                ThreadCardLatestTool(tool: .init(kind: .tool, name: "Running tool", status: .running))
            default:
                ThreadCardRuntime(startedAt: fixture.startedAt, endedAt: fixture.endedAt)
            }
        }
        .padding(20)
        .frame(width: 360, height: 200)
        .background(Color.white)
        .environment(\.locale, Locale(identifier: "en"))
        .environment(\.colorScheme, .light)
        .environment(\.scenePhase, fixture.scenePhase)
        .environment(\.threadCardAnimationVisibility, fixture.suppliesVisibility ? fixture.visibility : nil)
        .environment(\.threadCardCloudAnimationsEnabled, fixture.animationsEnabled)
        .onAppear { fixture.appearances += 1 }
    }
}

extension NativeOverviewMountingIntegrationTests {
    @Test func retainedRuntimePausesAndResumesWithoutReplayingMissedSeconds() async throws {
        let fixture = OverviewCardVisualFixture()
        fixture.animationsEnabled = false
        let window = SwiftUIReplay.window(OverviewCardVisualReplay(fixture: fixture), width: 360, height: 200)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { runtimeSeconds(in: root) != nil }
        let initial = try #require(runtimeSeconds(in: root))
        // Disabling decorative effects must not stop a visible running clock.
        try await SwiftUIReplay.wait { (runtimeSeconds(in: root) ?? 0) > initial }
        fixture.visibility.isVisible = false
        try await Task.sleep(for: .milliseconds(100))
        let hidden = try #require(runtimeSeconds(in: root))
        try await Task.sleep(for: .milliseconds(2_200))
        #expect(runtimeSeconds(in: root) == hidden)
        fixture.visibility.isVisible = true
        let wallSeconds = Int((Date().timeIntervalSince1970 * 1_000 - fixture.startedAt) / 1_000)
        try await SwiftUIReplay.wait { (runtimeSeconds(in: root) ?? 0) >= wallSeconds }
        fixture.scenePhase = .background
        try await Task.sleep(for: .milliseconds(100))
        let background = try #require(runtimeSeconds(in: root))
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(runtimeSeconds(in: root) == background)
        // A visible, unfocused window still shows elapsed time.
        fixture.scenePhase = .inactive
        try await SwiftUIReplay.wait { (runtimeSeconds(in: root) ?? 0) > background }
        fixture.endedAt = fixture.startedAt + 23_000
        try await SwiftUIReplay.wait { runtimeSeconds(in: root) == 23 }
        fixture.visibility.isVisible = false
        try await Task.sleep(for: .milliseconds(100))
        fixture.visibility.isVisible = true
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(runtimeSeconds(in: root) == 23)
        #expect(fixture.appearances == 1)
    }

    @Test func runtimeWithoutOverviewVisibilityKeepsUpdating() async throws {
        let fixture = OverviewCardVisualFixture()
        fixture.suppliesVisibility = false
        fixture.visibility.isVisible = false
        let window = SwiftUIReplay.window(OverviewCardVisualReplay(fixture: fixture), width: 360, height: 200)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { runtimeSeconds(in: root) != nil }
        let initial = try #require(runtimeSeconds(in: root))
        try await SwiftUIReplay.wait { (runtimeSeconds(in: root) ?? 0) > initial }
    }

    @Test(arguments: [0, 1, 2])
    func retainedDecorationsPauseAndResumeWithoutRemount(decoration: Int) async throws {
        let fixture = OverviewCardVisualFixture()
        let window = SwiftUIReplay.window(OverviewCardVisualReplay(fixture: fixture, decoration: decoration), width: 360, height: 200)
        defer { window.close() }
        let root = try #require(window.contentView)
        window.appearance = NSAppearance(named: .aqua)
        func pixels() throws -> Data {
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            return try #require(image.representation(using: .png, properties: [:]))
        }
        try await Task.sleep(for: .milliseconds(250))
        fixture.visibility.isVisible = false
        try await Task.sleep(for: .milliseconds(100))
        let hidden = try pixels()
        try await Task.sleep(for: .milliseconds(300))
        #expect(try pixels() == hidden)
        fixture.visibility.isVisible = true
        try await Task.sleep(for: .milliseconds(100))
        let resumed = try pixels()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try await Task.sleep(for: .milliseconds(300))
            #expect(try pixels() == resumed)
        } else {
            // Permission attention has a transparent rest within its cycle;
            // sample through that rest rather than requiring every frame to move.
            var moved = false
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(50))
                if try pixels() != resumed { moved = true; break }
            }
            #expect(moved)
        }
        fixture.animationsEnabled = false
        try await Task.sleep(for: .milliseconds(100))
        let disabled = try pixels()
        try await Task.sleep(for: .milliseconds(300))
        #expect(try pixels() == disabled)
        #expect(fixture.appearances == 1)
    }

    private func runtimeSeconds(in root: NSView) -> Int? {
        guard let label = SwiftUIReplay.text(in: root).first(where: { $0.hasPrefix("Duration: ") }) else { return nil }
        let parts = label.dropFirst("Duration: ".count).split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3_600 + parts[1] * 60 + parts[2]
    }
}
