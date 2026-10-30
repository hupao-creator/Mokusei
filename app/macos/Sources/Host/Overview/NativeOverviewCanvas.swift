import AppKit
import MokuseiPluginUI
import Observation
import SwiftUI

/// Geometry and structural identity only. The owning plugin supplies semantic card content.
public struct NativeOverviewItem: Identifiable, Equatable, Sendable {
    public let id: String
    public var columns: Int
    public var rows: Int
    public var structureKey: String
    public var carouselEligible: Bool
    public var needsAttention: Bool
    /// Opaque identity of the owning plugin projection; excluded from structural layout signatures.
    public var presentationID: String
    public var completed: Bool

    public init(id: String, columns: Int = 1, rows: Int = 1, structureKey: String = "",
                carouselEligible: Bool = false, needsAttention: Bool = false, presentationID: String = "", completed: Bool = false) {
        self.id = id
        self.columns = columns
        self.rows = rows
        self.structureKey = structureKey
        self.carouselEligible = carouselEligible
        self.needsAttention = needsAttention
        self.presentationID = presentationID
        self.completed = completed
    }

    var member: NativeOverviewMember { .init(id: id, columns: columns, rows: rows) }
    var structuralIdentity: String { "\(id)\u{0}\(columns)x\(rows)\u{0}\(structureKey)" }
}

/// Captured by the application at the runtime mutation boundary, before SwiftUI
/// can coalesce renders. Only structural facts are retained, never transcript copies.
public struct NativeOverviewLayoutRevision: Sendable {
    public let revision: UInt64
    public let sceneKey: String
    public let items: [NativeOverviewItem]
    public let instantEntryIDs: Set<String>
    public init(revision: UInt64, sceneKey: String, items: [NativeOverviewItem], instantEntryIDs: Set<String> = []) {
        self.revision = revision; self.sceneKey = sceneKey; self.items = items; self.instantEntryIDs = instantEntryIDs
    }
}

/// A navigation owner retains this object when the overview is temporarily unmounted.
/// Navigation retains camera and layout state across SwiftUI presentation changes.
@MainActor @Observable
public final class NativeOverviewCanvasState {
    public let camera = NativeOverviewCamera()
    public let motionStages: NativeOverviewStageCoordinator
    public let memory: NativeOverviewCameraMemory
    @ObservationIgnored public fileprivate(set) var sceneSnapshotCount = 0
    /// Geometric fallbacks actually presented after the straight-move budget ran out.
    @ObservationIgnored public fileprivate(set) var repackCount = 0
    @ObservationIgnored public fileprivate(set) var layoutSolveCount = 0
    @ObservationIgnored public fileprivate(set) var geometryReuseCount = 0
    /// Diagnostic lifecycle count, separate from logical layout membership.
    @ObservationIgnored public fileprivate(set) var mountedCardIDs = Set<String>()
    @ObservationIgnored private var mountedCardCounts: [String: Int] = [:]
    public fileprivate(set) var layoutError: String?
    public fileprivate(set) var overflowAttentionCount = 0
    public fileprivate(set) var isLayingOut = false
    public fileprivate(set) var presentedPlacements: [NativeOverviewPlacement] = []
    @ObservationIgnored fileprivate var retryHandler: (() -> Void)?
    @ObservationIgnored fileprivate var hostOwner: UUID?
    @ObservationIgnored fileprivate var inputFocused = false
    @ObservationIgnored fileprivate var externalInteractionPaused = false
    /// A Moku outside click already dismissed the composer. The same click must
    /// not also return the camera to automatic framing when its mouse-up lands.
    @ObservationIgnored fileprivate var autoFocusSuppressedForClick = false
    @ObservationIgnored fileprivate var activeIDs = Set<String>()
    @ObservationIgnored fileprivate var visible = true
    @ObservationIgnored private var interactionCounts: [String: Int] = [:]
    @ObservationIgnored fileprivate var activationCheck: ((String) -> Bool)?
    @ObservationIgnored var pendingSearchCameraRestoration: (sceneKey: String, view: NativeOverviewCameraState)?

    public init(memory: NativeOverviewCameraMemory = .init(), motionStages: NativeOverviewStageCoordinator = .init()) {
        self.memory = memory
        self.motionStages = motionStages
        camera.stageCoordinator = motionStages
    }
    public func retryLayout() { retryHandler?() }
    public func allowsActivation(cardID: String) -> Bool { activationCheck?(cardID) ?? false }
    /// Interaction widgets invoke this for real input, not hover or restored focus.
    public func beginInteraction(cardID: String) {
        interactionCounts[cardID, default: 0] += 1
        refreshInteractionPause()
    }
    public func endInteraction(cardID: String? = nil) {
        if let cardID {
            let remaining = max(0, (interactionCounts[cardID] ?? 0) - 1)
            if remaining == 0 { interactionCounts.removeValue(forKey: cardID) }
            else { interactionCounts[cardID] = remaining }
        } else { interactionCounts.removeAll() }
        refreshInteractionPause()
    }

    var interactionCardIDs: Set<String> { Set(interactionCounts.keys) }
    var interactionPauseReasons: [String] {
        (externalInteractionPaused ? ["presentation"] : []) + (inputFocused ? ["text-editing"] : [])
            + (!interactionCounts.isEmpty ? ["responding"] : [])
    }
    /// The Moku composer reports that this click dismissed input-box mode.
    func suppressAutoFocusForThisClick() { autoFocusSuppressedForClick = true }
    func clearAutoFocusSuppression() { autoFocusSuppressedForClick = false }
    /// One click may dismiss input-box mode or return the camera to automatic
    /// framing, never both. Consuming the mark here makes the dismissal win.
    func allowsBackgroundAutoFocus() -> Bool {
        if autoFocusSuppressedForClick {
            autoFocusSuppressedForClick = false
            return false
        }
        return !externalInteractionPaused
    }
    fileprivate func refreshInteractionPause() {
        camera.setInteractionPaused(externalInteractionPaused || inputFocused || !interactionCounts.isEmpty)
    }
    fileprivate func cardAppeared(_ id: String) {
        mountedCardCounts[id, default: 0] += 1
        mountedCardIDs.insert(id)
    }
    fileprivate func cardDisappeared(_ id: String) {
        let remaining = max(0, (mountedCardCounts[id] ?? 1) - 1)
        if remaining == 0 { mountedCardCounts.removeValue(forKey: id); mountedCardIDs.remove(id) }
        else { mountedCardCounts[id] = remaining }
    }
}


private struct OverviewCanvasWork {
    let run: @MainActor () async -> Void
}

/// Cards share one SwiftUI tree and inherit the workspace environment directly.
public struct NativeOverviewCanvas<Content: View>: View {
    public var items: [NativeOverviewItem]
    public var sceneKey: String
    public var selectionID: String?
    public var state: NativeOverviewCanvasState
    public var toolbarBottom: Double
    public var bottomReservedHeight: Double
    public var visible: Bool
    public var cloudAnimationsEnabled: Bool
    public var glassWorld: Bool
    public var interactionPaused: Bool
    public var resetEpoch: UInt64
    public var revisions: [NativeOverviewLayoutRevision]
    public var onRevisionsConsumed: ((UInt64) -> Void)?
    public var onRetainedPresentationIDsChanged: ((Set<String>) -> Void)?
    private var card: (NativeOverviewItem) -> Content
    // Native accessibility is read-only in EnvironmentValues. An explicit
    // override lets isolated hosts exercise both policies without OS changes.
    var reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.threadCardCloudAnimationsEnabled) private var inheritedCloudAnimationsEnabled
    private var spatialMotionReduced: Bool { reduceMotionOverride ?? reduceMotion }
    @Environment(\.nativeWindowContentScale) private var windowContentScale
    @FocusedValue(\.overviewFocusedCard) private var focusedCard
    @State private var rendered: [NativeOverviewItem] = []
    @State private var latestRecords: [String: NativeOverviewItem] = [:]
    @State private var retiringPresentationIDs = Set<String>()
    @State private var outgoingPlacements: [NativeOverviewPlacement] = []
    @State private var cardPoses: [String: OverviewCardPose] = [:]
    @State private var cardMotions: [String: OverviewCardMotion] = [:]
    @State private var consumedRevision: UInt64 = 0
    @State private var pendingWork: [OverviewCanvasWork] = []
    @State private var worker: Task<Void, Never>?
    @State private var workerEpoch = UUID()
    @State private var scheduledScene: String?
    @State private var scheduledSelection: String?
    @State private var scheduledResetEpoch: UInt64?
    @State private var mountedScene: String?
    @State private var mountedSelection: String?
    @State private var contentRect = NativeOverviewContentRect(left: 0, top: 0, width: 0, height: 0)
    @State private var plannedViewport: NativeOverviewViewport?
    @State private var retry = 0
    @State private var ownership = UUID()
    @State private var layoutToken = UUID()
    @State private var presentationToken = UUID()
    @State private var preparedPresentationToken: UUID?
    @GestureState private var dragOrigin: NativeOverviewTransform?
    @GestureState private var zoomActive = false
    @State private var navigationInput: NativeOverviewNavigationInput

    public init(items: [NativeOverviewItem], sceneKey: String, state: NativeOverviewCanvasState,
                selectionID: String? = nil, toolbarBottom: Double = 58, bottomReservedHeight: Double = 0, visible: Bool = true,
                cloudAnimationsEnabled: Bool = true, glassWorld: Bool = true,
                interactionPaused: Bool = false, resetEpoch: UInt64 = 0,
                revisions: [NativeOverviewLayoutRevision] = [], onRevisionsConsumed: ((UInt64) -> Void)? = nil,
                onRetainedPresentationIDsChanged: ((Set<String>) -> Void)? = nil,
                inputRegions: NativeCanvasInputRegions? = nil,
                @ViewBuilder card: @escaping (NativeOverviewItem) -> Content) {
        self.items = items; self.sceneKey = sceneKey; self.state = state; self.selectionID = selectionID
        self.toolbarBottom = toolbarBottom; self.visible = visible; self.cloudAnimationsEnabled = cloudAnimationsEnabled
        self.bottomReservedHeight = bottomReservedHeight
        self.glassWorld = glassWorld
        self.interactionPaused = interactionPaused; self.resetEpoch = resetEpoch; self.revisions = revisions
        self.onRevisionsConsumed = onRevisionsConsumed
        self.onRetainedPresentationIDsChanged = onRetainedPresentationIDsChanged
        self.card = card
        _navigationInput = State(initialValue: NativeOverviewNavigationInput(regions: inputRegions ?? .init()))
    }

    public var body: some View {
        let placements = state.presentedPlacements + outgoingPlacements
        let records = Dictionary(rendered.map { ($0.id, $0) }, uniquingKeysWith: { _, next in next })
        GeometryReader { geometry in
            let viewport = NativeOverviewViewport(width: geometry.size.width, height: geometry.size.height,
                                                  toolbarBottom: toolbarBottom, bottomReservedHeight: bottomReservedHeight)
            ZStack(alignment: .topLeading) {
                // Window dragging must never enter the camera's manual pan gesture.
                // Use the same header boundary as automatic camera framing.
                Color.clear.contentShape(Rectangle())
                    .frame(height: max(0, toolbarBottom))
                    .gesture(WindowDragGesture())
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { if state.allowsBackgroundAutoFocus() { state.camera.returnToAuto() } }
                    .gesture(pan)
                    .padding(.top, max(0, toolbarBottom))
                OverviewCameraPlane(camera: state.camera, visible: visible, ignoreLayout: true) {
                    ZStack(alignment: .topLeading) {
                        ForEach(placements, id: \.id) { placement in
                            if let item = records[placement.id] {
                                cardShell(placement, item: item)
                            }
                        }
                    }
                    .frame(width: max(1, contentRect.left + contentRect.width),
                           height: max(1, contentRect.top + contentRect.height), alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                OverviewCameraPlane(camera: state.camera, visible: visible) {
                    ZStack(alignment: .topLeading) {
                        ForEach(placements, id: \.id) { placement in
                            if let item = records[placement.id] {
                                semanticCard(placement, item: item, size: geometry.size)
                            }
                        }
                    }
                    .frame(width: max(1, contentRect.left + contentRect.width),
                           height: max(1, contentRect.top + contentRect.height), alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                NativeOverviewScrollInput(input: navigationInput, size: geometry.size, toolbarBottom: toolbarBottom,
                    identity: "\(ownership)|\(sceneKey)|\(selectionID ?? "")|\(resetEpoch)", contentScale: windowContentScale,
                    enabled: { visible && state.visible && !state.externalInteractionPaused && !interactionPaused
                        && !state.isLayingOut && state.hostOwner == ownership && state.camera.isInitialized },
                    pan: { delta in state.camera.pan(deltaX: delta.width, deltaY: delta.height) })
            }
            .background {
                OverviewEditingFocusObserver(state: state, owner: ownership, focusedCard: focusedCard)
                    .allowsHitTesting(false)
            }
            .environment(\.nativeCanvasInputRegions, navigationInput.regions)
            .coordinateSpace(name: ownership)
            // A new filter first lays out every card at its frozen start pose.
            // Acknowledging that layout keeps expensive first construction out
            // of the animation's clock, without guessing a mount-time delay.
            .onGeometryChange(for: UUID.self) { [presentationToken] _ in presentationToken } action: {
                preparedPresentationToken = $0
            }
            .clipped()
            .simultaneousGesture(magnification(in: geometry.size))
            .onChange(of: zoomActive) { _, active in if !active { navigationInput.endPinch() } }
            .onChange(of: state.isLayingOut) { _, layingOut in if layingOut { navigationInput.cancel() } }
            .disabled(interactionPaused)
            .onChange(of: requestKey(viewport)) { _, _ in enqueue(viewport) }
            .onAppear { attach(viewport); state.camera.setVisible(visible); enqueue(viewport) }
            .onChange(of: items) { previous, updated in
                state.activeIDs = Set(updated.map(\.id))
                let latest = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { _, next in next })
                latestRecords = latest
                rendered = rendered.map { item in
                    guard let next = latest[item.id], next.structuralIdentity == item.structuralIdentity else { return item }
                    return next
                }
                attach(viewport)
                if previous.map(\.structuralIdentity) == updated.map(\.structuralIdentity) {
                    if previous.map(\.carouselEligible) != updated.map(\.carouselEligible) { updateCarousel() }
                    state.camera.onChange?()
                }
                retain()
            }
            .onChange(of: visible) { _, value in state.visible = value; state.camera.setVisible(value) }
            .onChange(of: spatialMotionReduced) { _, value in state.camera.reduceMotion = value }
            .onChange(of: viewport) { _, _ in attach(viewport) }
             .onChange(of: interactionPaused) { _, value in
                state.externalInteractionPaused = value
                state.refreshInteractionPause()
            }
            .onDisappear { detach() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.canvas")
    }

    private func cardShell(_ placement: NativeOverviewPlacement, item: NativeOverviewItem) -> some View {
        OverviewCardFrame(pose: pose(placement), motion: cardMotions[placement.id], visible: visible) {
            if glassWorld {
                // Glass is composited at its container boundary. An opacity inside
                // a canvas-wide container fades text but leaves extracted surfaces
                // visible. Keep the motion wrapper outside each card's container.
                GlassEffectContainer(spacing: 0) {
                    Color.clear
                        .glassEffect(.regular.tint(item.completed ? NativePalette.overview.success.swiftUI.opacity(0.12) : nil),
                                     in: .rect(cornerRadius: 22))
                }
            } else {
                RoundedRectangle(cornerRadius: 22)
                    .fill(NativePalette.overview.surface.swiftUI)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(NativePalette.overview.lineSoft.swiftUI, lineWidth: 1)
                    }
            }
        }
    }
    private func semanticCard(_ placement: NativeOverviewPlacement, item: NativeOverviewItem, size: CGSize) -> some View {
        OverviewCardFrame(pose: pose(placement), motion: cardMotions[placement.id], visible: visible) {
            // Isolate the badge's glass from both other cards and this card's
            // backdrop so it fades with its content without fusing into the body.
            GlassEffectContainer(spacing: 0) {
                // Visibility also owns semantic clocks; disabling decorative
                // effects must not freeze the duration of a visible card.
                OverviewSwiftUICard(item: item, visible: visible,
                    viewport: size, coordinateSpace: ownership, content: card).equatable()
                    .environment(\.threadCardCloudAnimationsEnabled, inheritedCloudAnimationsEnabled && cloudAnimationsEnabled)
                    .onAppear { state.cardAppeared(item.id) }
                    .onDisappear { state.cardDisappeared(item.id) }
                    .clipShape(.rect(cornerRadius: 22))
                    .allowsHitTesting(!state.isLayingOut)
                    .focusedValue(\.overviewFocusedCard, item.id)
                    .accessibilityHidden(!state.activeIDs.contains(item.id))
                    .accessibilityIdentifier("overview-card-\(item.id)")
            }
        }
    }
    private func pose(_ placement: NativeOverviewPlacement) -> OverviewCardPose {
        cardPoses[placement.id] ?? .init(frame: placement.cardFrame)
    }
    private func livePose(_ placement: NativeOverviewPlacement, at now: TimeInterval) -> OverviewCardPose {
        cardMotions[placement.id]?.sample(at: now) ?? pose(placement)
    }
    private var pan: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragOrigin) { _, origin, _ in if origin == nil { origin = state.camera.liveTransform } }
            .onChanged { value in
                navigationInput.cancel()
                guard state.visible, !state.isLayingOut, !state.externalInteractionPaused, let origin = dragOrigin else { return }
                state.camera.setManualTransform(.init(scale: origin.scale, x: origin.x + value.translation.width,
                                                       y: origin.y + value.translation.height))
            }
    }
    private func magnification(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($zoomActive) { _, active, _ in active = true }
            .onChanged { value in
                let cursor = CGPoint(x: value.startAnchor.x * size.width, y: value.startAnchor.y * size.height)
                navigationInput.pinch(magnification: value.magnification, anchor: cursor, camera: state.camera)
            }
            .onEnded { _ in navigationInput.endPinch() }
    }
    private func requestKey(_ viewport: NativeOverviewViewport) -> String {
        "\(sceneKey)|\(selectionID ?? "")|\(items.map(\.structuralIdentity))|\(viewport)|\(resetEpoch)|\(retry)|\(revisions.last?.revision ?? 0)"
    }
    private func enqueue(_ viewport: NativeOverviewViewport) {
        let replaceScene = scheduledScene != nil && (scheduledSelection != selectionID ||
            (scheduledScene != sceneKey && (scheduledSelection == nil || selectionID == nil)))
        if replaceScene || (scheduledResetEpoch != nil && scheduledResetEpoch != resetEpoch) {
            worker?.cancel(); worker = nil
            pendingWork.removeAll()
        }
        scheduledScene = sceneKey; scheduledSelection = selectionID; scheduledResetEpoch = resetEpoch
        // Same-scene updates join the FIFO instead of cancelling a partly played
        // exit/shrink/move/grow/entry revision. Filter changes still interrupt.
        pendingWork.append(.init(run: { await reconcile(viewport) }))
        guard worker == nil else { return }
        let epoch = UUID(); workerEpoch = epoch
        worker = Task { @MainActor in
            defer { if workerEpoch == epoch { worker = nil } }
            while !Task.isCancelled && workerEpoch == epoch && !pendingWork.isEmpty {
                let work = pendingWork.removeFirst()
                await work.run()
            }
        }
    }
    private func attach(_ viewport: NativeOverviewViewport) {
        latestRecords = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, next in next })
        state.camera.reduceMotion = spatialMotionReduced
        state.hostOwner = ownership
        state.visible = visible
        state.externalInteractionPaused = interactionPaused
        state.activeIDs = Set(items.map(\.id))
        state.retryHandler = { retry += 1 }
        state.activationCheck = { id in !state.externalInteractionPaused && !state.isLayingOut && state.activeIDs.contains(id) }
        // Membership changes reattach this callback; camera movement only needs
        // to project the already-known attention cards.
        let attention = Set(items.filter(\.needsAttention).map(\.id))
        state.camera.onChange = {
            if let view = state.camera.live { state.memory.current = (sceneKey, view) }
            guard !attention.isEmpty else {
                state.overflowAttentionCount = 0
                return
            }
            state.overflowAttentionCount = state.presentedPlacements.filter { placement in
                attention.contains(placement.id) && !NativeOverviewCameraGeometry.isVisible(
                    .init(left: Double(placement.column) * 376, top: Double(placement.row) * 216,
                          width: Double(placement.columns) * 376 - 16, height: Double(placement.rows) * 216 - 16),
                    transform: state.camera.liveTransform, viewport: viewport)
            }.count
        }
        state.refreshInteractionPause()
    }
    private func detach() {
        navigationInput.cancel(); navigationInput.endPinch()
        worker?.cancel(); worker = nil; workerEpoch = UUID(); pendingWork.removeAll()
        scheduledScene = nil; scheduledSelection = nil; scheduledResetEpoch = nil
        guard state.hostOwner == ownership else { return }
        if let view = state.camera.live { state.memory.current = (sceneKey, view) }
        state.camera.setVisible(false)
        state.camera.onChange = nil
        state.retryHandler = nil; state.activationCheck = nil
        state.hostOwner = nil; state.isLayingOut = false; state.inputFocused = false; state.activeIDs.removeAll()
        cardMotions.removeAll(); cardPoses.removeAll(); outgoingPlacements.removeAll()
        state.refreshInteractionPause()
        onRetainedPresentationIDsChanged?([])
    }
    private func retain() { onRetainedPresentationIDsChanged?(Set(rendered.map(\.presentationID)).union(retiringPresentationIDs)) }
    private func updateCarousel() {
        let records = latestRecords
        state.camera.setCarouselCards(state.presentedPlacements.compactMap { placement in
            guard let item = records[placement.id] else { return nil }
            return .init(id: item.id, rect: .init(left: Double(placement.column) * 376, top: Double(placement.row) * 216,
                width: Double(placement.columns) * 376 - 16, height: Double(placement.rows) * 216 - 16), eligible: item.carouselEligible)
        })
    }
    private func reconcile(_ viewport: NativeOverviewViewport) async {
        guard viewport.width > 0, viewport.height > 0, state.hostOwner == ownership else { return }
        // Attachment callbacks and active IDs belong to the latest view, not a
        // historical revision snapshot being drained by the FIFO.
        let token = UUID(); layoutToken = token
        state.isLayingOut = true
        defer {
            if state.hostOwner == ownership, layoutToken == token {
                state.isLayingOut = false
            }
        }
        do {
            // The model retains revisions until acknowledged. Cancellation leaves
            // the current revision unconsumed, so rapid updates cannot skip exits.
            let pending = revisions.filter { $0.sceneKey == sceneKey && $0.revision > consumedRevision }
            for revision in pending {
                try await present(revision.items, instantEntryIDs: revision.instantEntryIDs, viewport: viewport)
                consumedRevision = revision.revision
                onRevisionsConsumed?(revision.revision)
            }
            if rendered != items || mountedScene != sceneKey || pending.isEmpty {
                try await present(items, instantEntryIDs: [], viewport: viewport)
            }
            try Task.checkCancellation()
            if let revision = revisions.map(\.revision).max(), revision > consumedRevision {
                consumedRevision = revision; onRevisionsConsumed?(revision)
            }
        } catch is CancellationError { }
        catch {
            // A detached solver can hit its budget as its owner is cancelled.
            // That obsolete failure must not cover a newer scene's valid result.
            guard !Task.isCancelled, state.hostOwner == ownership, layoutToken == token else { return }
            state.layoutError = error.localizedDescription
        }
    }

    private func present(_ next: [NativeOverviewItem], instantEntryIDs: Set<String>,
                         viewport: NativeOverviewViewport) async throws {
        let replaceScene = mountedSelection != selectionID ||
            (mountedScene != sceneKey && (mountedSelection == nil || selectionID == nil))
        let displayed = state.presentedPlacements
        let members = next.map(\.member)
        // Placements publish before their transition completes. A recovery can
        // cancel that owner, leaving transparent entrants or retiring snapshots;
        // those presentations must finish through the normal recovery path.
        if mountedScene == sceneKey, !replaceScene, state.layoutError == nil,
           cardMotions.isEmpty, cardPoses.isEmpty, outgoingPlacements.isEmpty, retiringPresentationIDs.isEmpty,
           displayed.count == members.count, Set(displayed.map(\.member)) == Set(members),
           plannedViewport == viewport || NativeOverviewCameraGeometry.fitsAtReadingScale(contentRect, viewport: viewport) {
            // Internal slot/content revisions still retire their snapshots and
            // acknowledge the FIFO, but never acquire a spatial stage or solver.
            rendered = next.map(currentContentItem)
            retain()
            state.geometryReuseCount += 1
            plannedViewport = viewport
            updateCarousel()
            state.camera.requestRefit(content: contentRect, viewport: viewport)
            return
        }
        let nextIDs = Set(next.map(\.id))
        let sampledCamera = state.camera.liveTransform
        let sampledAt = ProcessInfo.processInfo.systemUptime
        // Explicit filter changes keep compact framing. Only survivors the
        // user can see contribute travel costs; offscreen history must not pull
        // them away. Ordinary mutations keep the full collision-free history.
        let visibleSurvivors = displayed.filter { placement in
            guard nextIDs.contains(placement.id) else { return false }
            let frame = livePose(placement, at: sampledAt).frame
            return NativeOverviewCameraGeometry.isVisible(
                .init(left: frame.minX, top: frame.minY, width: frame.width, height: frame.height),
                transform: sampledCamera, viewport: viewport)
        }
        // Search owns a browse-camera bookmark. Returning to that scene must
        // restore it even when a result card survives on screen; retaining the
        // search framing here would skip prepareCamera and leave it unconsumed.
        let preserveFraming = replaceScene && !visibleSurvivors.isEmpty
            && state.pendingSearchCameraRestoration?.sceneKey != sceneKey
        let previous = replaceScene ? visibleSurvivors : displayed
        let stage = try await state.motionStages.acquire(owner: "overview-layout:\(sceneKey)")
        defer { stage.release() }
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        let capacity = NativeOverviewCameraGeometry.contentRegion(viewport)
        let scale = NativeOverviewCameraGeometry.minimumScale(in: viewport)
        let fittingSize = CGSize(width: region.width / scale, height: region.height / scale)
        let capacitySize = CGSize(width: capacity.width / scale, height: capacity.height / scale)
        let preferredSize = CGSize(width: region.width / max(1, scale), height: region.height / max(1, scale))
        let ordinaryLayout = mountedScene == nil || !replaceScene
        state.layoutSolveCount += 1
        let planning = Task.detached(priority: .userInitiated) {
            let preferred = try NativeOverviewLayout.plan(previous: previous, next: members, fittingSize: fittingSize,
                                          preferredSize: ordinaryLayout ? preferredSize : nil, preservePositions: ordinaryLayout)
            // Preserve ordinary packing when it fits. Before admitting a
            // carousel, also try the real control-free extent: a wider shape
            // can fit even when the preferred inset planner chose a tall one.
            if preferred.bounds.width > capacitySize.width + 1e-6 || preferred.bounds.height > capacitySize.height + 1e-6 {
                return try NativeOverviewLayout.plan(previous: previous, next: members, fittingSize: capacitySize,
                    preferredSize: ordinaryLayout ? preferredSize : nil, preservePositions: ordinaryLayout)
            }
            return preferred
        }
        let plan = try await withTaskCancellationHandler { try await planning.value } onCancel: { planning.cancel() }
        try Task.checkCancellation()
        guard state.hostOwner == ownership else { throw CancellationError() }
        let initial = mountedScene == nil || (displayed.isEmpty && outgoingPlacements.isEmpty)
        let animated = state.visible && !initial && !spatialMotionReduced
        let sameViewport = plannedViewport == viewport
        plannedViewport = viewport
        let now = ProcessInfo.processInfo.systemUptime
        let oldCamera = state.camera.liveTransform
        let oldPlacements = displayed + outgoingPlacements
        let oldPoses = Dictionary(oldPlacements.map { ($0.id, livePose($0, at: now)) }, uniquingKeysWith: { first, _ in first })
        let oldIDs = Set(displayed.map(\.id))
        let oldRecords = rendered
        let box = plan.bounds
        contentRect = .init(left: Double(box.column) * 376, top: Double(box.row) * 216, width: box.width, height: box.height)
        mountedScene = sceneKey; mountedSelection = selectionID
        state.layoutError = nil
        retiringPresentationIDs.formUnion(oldRecords.map(\.presentationID))
        outgoingPlacements = oldPlacements.filter { !nextIDs.contains($0.id) }
        rendered = next.map(currentContentItem) + oldRecords.filter { !nextIDs.contains($0.id) }
        cardMotions.removeAll()
        cardPoses = oldPoses
        state.camera.deferRefit()
        // Ordinary exits run in the old camera before an empty result can
        // dispose it or the new bounds can constrain it.
        if !animated || replaceScene {
            if preserveFraming {
                state.camera.retainFraming(content: contentRect, viewport: viewport)
            } else {
                prepareCamera(next, initial: initial, replaceScene: replaceScene, viewport: viewport)
            }
        }
        let camera = state.camera.liveTransform
        state.presentedPlacements = plan.placements
        retain()
        if !animated {
            cardPoses = Dictionary(plan.placements.map { ($0.id, OverviewCardPose(frame: $0.cardFrame)) }, uniquingKeysWith: { _, last in last })
        } else if replaceScene {
            // Rebase the visible presentation before the camera cut. A rapid
            // reversal uses the sampled in-flight bounds, including outgoing cards.
            let preparation = UUID()
            presentationToken = preparation
            let started = TimeInterval.infinity
            for placement in outgoingPlacements {
                guard let old = oldPoses[placement.id] else { continue }
                let from = old.reproject(from: oldCamera, to: camera)
                setMotion(placement.id, from: from, to: from.transformed(scale: 0.88, opacity: 0),
                          duration: 0.14, curve: .filter, layoutSize: placement.cardFrame.size, start: started)
            }
            for placement in plan.placements {
                let target = OverviewCardPose(frame: placement.cardFrame)
                if let old = oldPoses[placement.id] {
                    setMotion(placement.id, from: old.reproject(from: oldCamera, to: camera), to: target,
                              duration: 0.32, delay: 0.07, curve: .filter, layoutSize: target.frame.size, start: started)
                } else {
                    setMotion(placement.id, from: target.transformed(scale: 0.94, dy: 12 / camera.scale, opacity: 0), to: target,
                              duration: 0.23, delay: 0.15, curve: .filter, layoutSize: target.frame.size, start: started)
                }
            }
            while state.visible && preparedPresentationToken != preparation {
                try await waitForMotion(0.001)
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            for id in Array(cardMotions.keys) { cardMotions[id]?.start = startedAt }
            try await waitForMotion(0.39)
        } else if plan.requiresRepack {
            state.repackCount += 1
            // A bounded motion search can fail even when every card fits.
            // Keep mounted identities, retire their visible presentation, then
            // relocate while transparent so no unproven path crosses a card.
            for placement in plan.placements where !oldIDs.contains(placement.id) {
                cardPoses[placement.id] = .init(frame: placement.cardFrame, opacity: 0)
            }
            for placement in oldPlacements {
                guard let from = oldPoses[placement.id] else { continue }
                setMotion(placement.id, from: from, to: from.transformed(scale: 0.98, opacity: 0),
                          duration: 0.14, curve: .layout, layoutSize: from.frame.size)
            }
            try await waitForMotion(0.14)
            cardMotions.removeAll(); outgoingPlacements.removeAll()
            prepareCamera(next, initial: initial, replaceScene: false, viewport: viewport)
            for placement in plan.placements {
                let target = OverviewCardPose(frame: placement.cardFrame)
                if !oldIDs.contains(placement.id), instantEntryIDs.contains(placement.id) {
                    cardPoses[placement.id] = target
                } else {
                    setMotion(placement.id, from: target.transformed(scale: 0.98, opacity: 0), to: target,
                              duration: 0.23, curve: .entry, layoutSize: target.frame.size)
                }
            }
            try await waitForMotion(0.23)
        } else {
            // Preserve the original collision-free beat order. New cards stay
            // transparent until all shrink/move/grow beats ahead of them finish.
            for placement in plan.placements where !oldIDs.contains(placement.id) {
                cardPoses[placement.id] = .init(frame: placement.cardFrame, opacity: 0)
            }
            for placement in outgoingPlacements {
                guard let from = oldPoses[placement.id] else { continue }
                setMotion(placement.id, from: from, to: from.transformed(scale: 0.98, dy: -8, opacity: 0),
                          duration: 0.16, curve: .layout, layoutSize: from.frame.size)
                try await waitForMotion(0.16)
                finishMotion(placement.id)
            }
            outgoingPlacements.removeAll()
            prepareCamera(next, initial: initial, replaceScene: false, viewport: viewport)
            let targets = Dictionary(plan.placements.map { ($0.id, $0.cardFrame) }, uniquingKeysWith: { _, last in last })
            for placement in plan.placements where oldIDs.contains(placement.id) {
                guard let from = cardPoses[placement.id], let target = targets[placement.id] else { continue }
                let size = CGSize(width: min(from.frame.width, target.width), height: min(from.frame.height, target.height))
                try await resizeCard(placement.id, to: CGRect(origin: from.frame.origin, size: size))
            }
            for id in plan.moveOrder {
                guard let from = cardPoses[id], let target = targets[id] else { continue }
                try await resizeCard(id, to: CGRect(origin: target.origin, size: from.frame.size))
            }
            for placement in plan.placements {
                let target = OverviewCardPose(frame: placement.cardFrame)
                if oldIDs.contains(placement.id) {
                    try await resizeCard(placement.id, to: target.frame)
                } else if instantEntryIDs.contains(placement.id) {
                    cardPoses[placement.id] = target
                } else {
                    setMotion(placement.id, from: target.transformed(scale: 1, dy: 8, opacity: 0), to: target,
                              duration: 0.32, curve: .entry, layoutSize: target.frame.size)
                    try await waitForMotion(0.32)
                    finishMotion(placement.id)
                }
            }
        }
        try Task.checkCancellation()
        cardMotions.removeAll(); cardPoses.removeAll(); outgoingPlacements.removeAll()
        rendered = next.map(currentContentItem)
        retiringPresentationIDs.removeAll()
        retain()
        if next.isEmpty { state.memory.current = nil }
        state.refreshInteractionPause()
        updateCarousel()
        // Entrants change the collection being framed even when survivors keep
        // their world positions. The old camera would leave new cards at an edge.
        state.camera.requestRefit(content: contentRect, viewport: viewport, layoutChanged: previous != plan.placements,
                                  preserveFraming: preserveFraming,
                                  preserveReadingPosition: !replaceScene && !initial && sameViewport
                                      && nextIDs.isSubset(of: oldIDs) && plan.shiftedIDs.isEmpty)
    }

    private func currentContentItem(_ item: NativeOverviewItem) -> NativeOverviewItem {
        // Queued structural history must not roll back newer text/status for an
        // unchanged footprint. The model retains older structural projections.
        guard let latest = latestRecords[item.id], latest.structuralIdentity == item.structuralIdentity else { return item }
        return latest
    }

    private func prepareCamera(_ next: [NativeOverviewItem], initial: Bool, replaceScene: Bool,
                               viewport: NativeOverviewViewport) {
        if initial || next.isEmpty || !state.camera.isInitialized || replaceScene {
            if initial, !next.isEmpty, let saved = state.memory.current, saved.sceneKey == sceneKey {
                state.camera.restore(view: saved.view, content: contentRect, viewport: viewport)
            } else { state.camera.cutTo(content: contentRect, viewport: viewport) }
        } else {
            state.camera.reconcileBounds(content: contentRect, viewport: viewport)
        }
        if let restore = state.pendingSearchCameraRestoration, restore.sceneKey == sceneKey {
            state.pendingSearchCameraRestoration = nil
            state.camera.restore(view: restore.view, content: contentRect, viewport: viewport)
        }
    }

    private func setMotion(_ id: String, from: OverviewCardPose, to: OverviewCardPose,
                           duration: Double, delay: Double = 0, curve: OverviewCardMotion.Curve,
                           layoutSize: CGSize?, start: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        cardPoses[id] = to
        cardMotions[id] = .init(from: from, to: to, start: start, delay: delay, duration: duration,
                               curve: curve, layoutSize: layoutSize)
    }
    private func finishMotion(_ id: String) { cardMotions.removeValue(forKey: id) }
    private func waitForMotion(_ seconds: Double) async throws {
        if state.visible { try await Task.sleep(for: .seconds(seconds)) }
        try Task.checkCancellation()
        guard state.hostOwner == ownership else { throw CancellationError() }
    }
    private func resizeCard(_ id: String, to frame: CGRect) async throws {
        guard let from = cardPoses[id], from != OverviewCardPose(frame: frame) else { return }
        setMotion(id, from: from, to: .init(frame: frame), duration: 0.26, curve: .layout, layoutSize: nil)
        try await waitForMotion(0.26)
        finishMotion(id)
    }
}

/// Only this transform wrapper samples camera motion; card content keeps its identity.
private struct OverviewCameraPlane<Content: View>: View {
    let camera: NativeOverviewCamera
    let visible: Bool
    @Environment(\.nativeWindowContentScale) private var windowScale
    // Only decorative surfaces may opt out of geometry propagation.
    let ignoreLayout: Bool
    let content: Content
    init(camera: NativeOverviewCamera, visible: Bool, ignoreLayout: Bool = false, @ViewBuilder content: () -> Content) {
        self.camera = camera
        self.visible = visible
        self.ignoreLayout = ignoreLayout
        self.content = content()
    }
    var body: some View {
        let transform = camera.transform
        // Prepare glyphs at a bounded resolution tier. Panning never changes
        // this environment; zooming rebuilds text only when crossing a tier.
        let peakScale = camera.animationFrames.reduce(transform.scale) { max($0, $1.scale) }
        let magnification = max(1, peakScale * windowScale)
        let textResolution = min(32, pow(2, ceil(log2(magnification))))
        let delay = camera.animationFrames.dropFirst().first?.at ?? 0
        Group {
            if ignoreLayout {
                content.modifier(OverviewCameraAffineEffect(scale: transform.scale, x: transform.x, y: transform.y).ignoredByLayout())
            } else {
                content.scaleEffect(transform.scale, anchor: .topLeading)
                    .offset(x: transform.x, y: transform.y)
            }
        }
            .environment(\.threadCardTextRasterScale, textResolution)
            .animation(visible && camera.isAnimating ? Animation(OverviewCameraAnimation(delay: delay, startedAt: camera.animationStartTime ?? ProcessInfo.processInfo.systemUptime)) : nil,
                       value: transform)
    }
}

private struct OverviewSwiftUICard<Content: View>: View, Equatable {
    nonisolated let item: NativeOverviewItem
    nonisolated let visible: Bool
    nonisolated let viewport: CGSize
    nonisolated let coordinateSpace: UUID
    let content: (NativeOverviewItem) -> Content
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.visible == rhs.visible && lhs.viewport == rhs.viewport && lhs.coordinateSpace == rhs.coordinateSpace
    }
    @State private var inViewport = false
    @State private var animationVisibility = ThreadCardAnimationVisibility(isVisible: false)
    var body: some View {
        let coordinateSpace = coordinateSpace, viewport = viewport
        content(item).environment(\.threadCardAnimationVisibility, animationVisibility)
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.frame(in: .named(coordinateSpace)).intersects(CGRect(origin: .zero, size: viewport))
            } action: { value in inViewport = value; animationVisibility.isVisible = visible && value }
            .onAppear { animationVisibility.isVisible = visible && inViewport }
            .onChange(of: visible) { _, value in animationVisibility.isVisible = value && inViewport }
            .onDisappear { animationVisibility.isVisible = false }
    }
}

/// Match the camera's sampled curve so interrupting a SwiftUI animation keeps the same position.
private struct OverviewCameraAnimation: CustomAnimation {
    let delay: TimeInterval
    let startedAt: TimeInterval
    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        guard elapsed < delay + 0.36 else { return nil }
        let position = max(0, (elapsed - delay) / 0.36) * 48
        let lower = floor(position), upper = min(48, lower + 1)
        let a = 1 - pow(1 - lower / 48, 5), b = 1 - pow(1 - upper / 48, 5)
        return value.scaled(by: a + (b - a) * (position - lower))
    }
}

/// SwiftUI can restore keyboard focus to the focusable card when search exits.
/// That identifies a card, not an editing session. Only its live editable native
/// responder owns the input pause; a card/button focus must not defer auto-fit.
private struct OverviewEditingFocusObserver: NSViewRepresentable {
    let state: NativeOverviewCanvasState
    let owner: UUID
    let focusedCard: String?

    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        view.state = state; view.owner = owner; view.focusedCard = focusedCard
        view.scheduleRefresh()
    }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.stop() }

    @MainActor final class Observer: NSView {
        weak var state: NativeOverviewCanvasState?
        var owner: UUID?
        var focusedCard: String?
        private var observations: [NSObjectProtocol] = []
        private var attached = false
        private var refreshScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            attached = true
            // Window updates cover responder handoff without an edit (Tab,
            // restoration and field removal); text notifications cover edits
            // within the same card, where the FocusedValue does not change.
            let names = [NSWindow.didUpdateNotification, NSControl.textDidBeginEditingNotification,
                         NSControl.textDidEndEditingNotification, NSText.didBeginEditingNotification,
                         NSText.didEndEditingNotification]
            for name in names {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                    let senderView = notice.object as? NSView
                    let senderWindow = notice.object as? NSWindow
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window,
                              senderWindow === window || senderView?.window === window else { return }
                        self.scheduleRefresh()
                    }
                })
            }
            scheduleRefresh()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func scheduleRefresh() {
            guard !refreshScheduled else { return }
            refreshScheduled = true
            // AppKit finishes its responder handoff after begin/end callbacks;
            // also keep Observation writes outside SwiftUI's updateNSView pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                guard let state = self.state, state.hostOwner == self.owner else { return }
                let editor = self.window?.firstResponder as? NSTextView
                let editing = self.attached && self.focusedCard != nil && editor?.isEditable == true
                guard state.inputFocused != editing else { return }
                state.inputFocused = editing
                state.refreshInteractionPause()
            }
        }

        func stop() {
            attached = false
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
            scheduleRefresh()
        }
    }
}

private struct OverviewFocusedCardKey: FocusedValueKey { typealias Value = String }
private extension FocusedValues {
    var overviewFocusedCard: String? {
        get { self[OverviewFocusedCardKey.self] }
        set { self[OverviewFocusedCardKey.self] = newValue }
    }
}

private struct OverviewCameraAffineEffect: GeometryEffect {
    var scale: Double
    var x: Double
    var y: Double
    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { .init(scale, .init(x, y)) }
        set { scale = newValue.first; x = newValue.second.first; y = newValue.second.second }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y))
    }
}
