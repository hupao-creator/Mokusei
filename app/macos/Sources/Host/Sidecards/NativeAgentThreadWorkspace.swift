import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Native composition for a Harness conversation and one selected sidecard.
/// Plugin identities and contents are supplied by the active registry.
@MainActor
public struct NativeAgentThreadWorkspace: View {
    private let harnessHost: NativeHarnessHost
    private let thread: HarnessThread
    private let registry: SidecardPluginRegistry
    private let executionDisabled: Bool
    private let readingTarget: HarnessReadingTarget?
    private let sidecardsSuppressed: Bool
    private let enabledSidecardIDs: Set<JSONText>?
    private let services: NativeSidecardWorkspaceServices
    private let executionReveal: SidecardExecutionReveal?
    private let onEntranceReady: () -> Bool
    private let onBack: () -> Void
    private let onFollowUpVisibilityChange: (Bool) -> Void
    private let backLabel: String?
    private let onNavigationChange: ((ThreadDetailBackAction?) -> Void)?
    @Environment(\.locale) private var locale
    @State private var nestedNavigation: ThreadDetailBackAction?
    @State private var navigation: ThreadDetailBackAction

    public init(harnessHost: NativeHarnessHost, thread: HarnessThread, registry: SidecardPluginRegistry,
                executionDisabled: Bool = false, readingTarget: HarnessReadingTarget? = nil,
                sidecardsSuppressed: Bool = false,
                enabledSidecardIDs: Set<JSONText>? = nil, services: NativeSidecardWorkspaceServices,
                onBack: @escaping () -> Void, onFollowUpVisibilityChange: @escaping (Bool) -> Void = { _ in },
                backLabel: String? = nil, onNavigationChange: ((ThreadDetailBackAction?) -> Void)? = nil,
                executionReveal: SidecardExecutionReveal? = nil,
                onEntranceReady: @escaping () -> Bool = { true }) {
        self.harnessHost = harnessHost; self.thread = thread; self.registry = registry
        self.executionDisabled = executionDisabled; self.readingTarget = readingTarget
        self.sidecardsSuppressed = sidecardsSuppressed
        self.enabledSidecardIDs = enabledSidecardIDs; self.services = services
        self.onBack = onBack; self.onFollowUpVisibilityChange = onFollowUpVisibilityChange
        self.backLabel = backLabel; self.onNavigationChange = onNavigationChange
        self.executionReveal = executionReveal
        self.onEntranceReady = onEntranceReady
        _navigation = State(initialValue: ThreadDetailBackAction(label: backLabel ?? "返回俯瞰", onBack: onBack))
    }

    public var body: some View {
        let label = backLabel ?? (locale.language.languageCode?.identifier == "zh" ? "返回俯瞰" : "Back to overview")
        ThreadDetailFrame(navigation: navigation, onNavigationChange: { action in
            nestedNavigation = action; onNavigationChange?(action)
        }) {
                NativeThreadWorkspaceBody(harnessHost: harnessHost, thread: thread, registry: registry,
                    executionDisabled: executionDisabled, readingTarget: readingTarget,
                    sidecardsSuppressed: sidecardsSuppressed, enabledSidecardIDs: enabledSidecardIDs,
                    services: services, executionReveal: executionReveal, onEntranceReady: onEntranceReady,
                    onBack: onBack, onFollowUpVisibilityChange: onFollowUpVisibilityChange)
                    .environment(\.nativeAgentHasNestedNavigation, nestedNavigation.map { $0.id != navigation.id } ?? false)
                    .id([thread.id, thread.harnessID])
            }
            .task(id: [thread.id, JSONText(label)]) {
                navigation = ThreadDetailBackAction(label: label, onBack: onBack)
            }
    }
}

private extension EnvironmentValues {
    @Entry var nativeAgentHasNestedNavigation = false
}

extension EnvironmentValues {
    @Entry var nativeAgentInputTargetChanged: ((UUID, ThreadConversationInputTarget?) -> Void)?
}

@MainActor
private struct NativeThreadWorkspaceBody: View {
    let harnessHost: NativeHarnessHost
    let thread: HarnessThread
    let registry: SidecardPluginRegistry
    let executionDisabled: Bool
    let readingTarget: HarnessReadingTarget?
    let sidecardsSuppressed: Bool
    let enabledSidecardIDs: Set<JSONText>?
    let services: NativeSidecardWorkspaceServices
    let executionReveal: SidecardExecutionReveal?
    let onEntranceReady: () -> Bool
    let onBack: () -> Void
    let onFollowUpVisibilityChange: (Bool) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.nativeAgentHasNestedNavigation) private var hasNestedNavigation
    @Environment(\.nativeReadingEntranceReady) private var primaryEntranceReady
    @Environment(\.nativeExecutionDockPlacement) private var executionPlacement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: NativeSidecardWorkspaceModel?
    @State private var auxiliaryStageReady = false
    @State private var inputStageReady = false
    @State private var contentRevealComplete = false

    private var configuration: NativeSidecardWorkspaceConfiguration {
        NativeSidecardWorkspaceConfiguration(input: HarnessThreadInput(thread: thread, readingTarget: readingTarget),
            executionDisabled: executionDisabled, suppressed: sidecardsSuppressed, enabledIDs: enabledSidecardIDs,
            locale: locale, executionReveal: executionReveal, mainReadingHistory: hasNestedNavigation,
            entranceReady: auxiliaryStageReady, reduceMotion: reduceMotion)
    }

    var body: some View {
        Group {
            if let model, let snapshot = model.snapshot {
                NativeSidecardWorkspaceLayout(model: model, snapshot: snapshot, onContentRevealChange: { status in
                    guard self.model === model else { return }
                    contentRevealComplete = status.complete
                }, onDockSettled: {
                    guard self.model === model, snapshot.entranceReady, auxiliaryStageReady, !inputStageReady,
                          primaryEntranceReady else { return }
                    inputStageReady = onEntranceReady()
                })
                    .background {
                        NativeReadingEntranceStage(enabled: primaryEntranceReady && contentRevealComplete && !auxiliaryStageReady) {
                            guard self.model === model else { return }
                            auxiliaryStageReady = true
                            if executionPlacement == nil { inputStageReady = onEntranceReady() }
                        }
                    }
            } else {
                NativePalette.thread.canvas.swiftUI
            }
        }
        .task {
            let current = model ?? NativeSidecardWorkspaceModel(harnessHost: harnessHost, registry: registry,
                configuration: configuration, services: services, onBack: onBack,
                onVisibilityChange: onFollowUpVisibilityChange)
            model = current
            current.update(configuration: configuration, services: services, onBack: onBack,
                           onVisibilityChange: onFollowUpVisibilityChange)
        }
        .onChange(of: configuration) { _, value in
            model?.update(configuration: value, services: services, onBack: onBack,
                          onVisibilityChange: onFollowUpVisibilityChange)
        }
        .onDisappear {
            model?.release(); model = nil
            auxiliaryStageReady = false; inputStageReady = false; contentRevealComplete = false
        }
    }
}

@MainActor
struct NativeSidecardWorkspaceLayout: View {
    @Environment(\.nativeThreadPreparing) private var preparing
    let model: NativeSidecardWorkspaceModel
    let snapshot: NativeSidecardWorkspaceSnapshot
    /// Previews/replays can supply the same policy without changing OS settings.
    var motionReduced: Bool? = nil
    var onContentRevealChange: (NativeReadingContentRevealStatus) -> Void = { _ in }
    var onDockSettled: () -> Void = {}
    @Environment(\.locale) private var locale
    @Environment(\.nativeAgentHasNestedNavigation) private var hasNestedNavigation
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.nativeExecutionDockPlacement) private var executionPlacement
    @Environment(\.nativeAgentInputTargetChanged) private var inputTargetChanged
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedLauncher: JSONText?
    @State private var launcherFrames: [JSONText: CGRect] = [:]
    @State private var handoffProgress: CGFloat = 0
    @State private var handoffResized = false
    @State private var absorbedCardID: JSONText?
    @State private var inputTarget: ThreadConversationInputTarget?
    @State private var inputOwner = UUID()
    private var reduceMotion: Bool { motionReduced ?? systemReduceMotion }

    private var animation: Animation? {
        snapshot.dragging || reduceMotion ? nil : NativeSidecardTiming.foldAnimation
    }
    private var dividerHitWidth: CGFloat {
        6
    }

    var body: some View {
        GeometryReader { geometry in
            // The toolbar has an actual layout seat, not merely an offset
            // outside the reader; native hit testing must reach that background.
            let panelSize = CGSize(width: max(1, geometry.size.width - 76), height: geometry.size.height)
            let layout = NativeSidecardWorkspaceGeometry(size: panelSize, snapshot: snapshot)
            let dockFrame = dockFrame(in: layout)
            let mainSize = CGSize(
                width: layout.mainWidth + (panelSize.width - layout.mainWidth) * handoffProgress,
                height: layout.mainHeight + (panelSize.height - layout.mainHeight) * handoffProgress)
            launchers
                .position(x: panelSize.width + 38, y: panelSize.height / 2)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .backgroundPreferenceValue(NativeSidecardLauncherAnchors.self) { anchors in
                    GeometryReader { proxy in
                        let frames = anchors.mapValues { proxy[$0] }
                        ZStack(alignment: .topLeading) {
                            NativeExecutionHandoffReader(handoff: snapshot.handoff,
                                destinationSize: snapshot.handoff == nil ? mainSize : panelSize,
                                workspaceSize: geometry.size, reduceMotion: reduceMotion || handoffResized || scenePhase != .active,
                                onComplete: model.finishHandoff, onInputTargetChange: { target in
                                    inputTarget = target
                                    inputTargetChanged?(inputOwner, target)
                                }) {
                                mainConversation
                            }
                                .frame(width: mainSize.width, height: mainSize.height, alignment: .topLeading)
                                // Reflow the reader once at its destination width.
                                // Animate its center and the surrounding shell
                                // independently, without rescaling native text or
                                // proposing a different TextKit width every tick.
                                .offset(x: -mainSize.width / 2)
                                // Only the size change loses inherited travel;
                                // later reader-owned animations keep their transaction.
                                .transaction(value: mainSize) { $0.animation = nil }
                                .offset(x: mainSize.width / 2)
                                .frame(width: mainSize.width, height: mainSize.height, alignment: .topLeading)
                                .background(NativePalette.thread.canvas.swiftUI)
                                .background(NativeReadingPanelFrame())
                                .clipShape(RoundedRectangle(cornerRadius: 22))
                                .overlay(RoundedRectangle(cornerRadius: 22).stroke(NativePalette.thread.line.swiftUI.opacity(0.6)))
                                .nativeReadingPanelClose(label: localize("关闭 Thread", "Close thread"), onClose: model.closeThread)
                                .accessibilityIdentifier("agent-reading-panel")
                                .nativeLayoutLog("agent.reading.panel")
                                .zIndex(snapshot.handoff == nil ? 0 : 2)
                            if snapshot.selected != nil && !layout.stacked && snapshot.handoff == nil {
                                NativeSidecardDivider(width: layout.cardWidth, maximumWidth: layout.maximumCardWidth,
                                    onWidthChange: { model.resize($0, maximum: layout.maximumCardWidth) },
                                    onDraggingChange: model.setDragging)
                                    .frame(width: dividerHitWidth, height: geometry.size.height)
                                    .offset(x: layout.mainWidth + (16 - dividerHitWidth) / 2)
                                    .zIndex(2)
                                    .accessibilityLabel(localize("调整卡片宽度", "Resize card"))
                            }
                            // All sessions remain in this ForEach, including folded and
                            // suppressed cards, so child Harness interaction state survives.
                            ForEach(snapshot.cards) { card in
                                sidecard(card, layout: layout, source: frames[card.id] ?? launcherFrames[card.id])
                            }
                        }
                        .onChange(of: frames, initial: true) { _, current in
                            // Retiring availability can remove the anchor before
                            // its card finishes folding. Keep its last real seat.
                            launcherFrames.merge(current, uniquingKeysWith: { _, next in next })
                        }
                    }
                }
                .animation(animation, value: snapshot.selected)
                .animation(animation, value: layout.stacked)
                .background(alignment: .topLeading) {
                    // Measure the destination, never the animated aperture.
                    NativeExecutionDockRegion(placement: executionPlacement,
                        active: dockFrame != nil, ready: snapshot.entranceReady && !preparing,
                        dragging: snapshot.dragging, threadID: snapshot.input.thread.id,
                        onSettled: onDockSettled)
                        .destinationFrame(dockFrame)
                        .allowsHitTesting(false)
                }
                .onChange(of: geometry.size) { _, _ in
                    guard let handoff = snapshot.handoff else { return }
                    handoffResized = true
                    if handoff.contentReady { absorb(handoff.id, animated: false) }
                }
        }
        .nativeReadingExitCommand {
            closeTopLevel()
        }
        // Input ownership spans the workspace, not either transient reader
        // host. Removing the outgoing host must not clear the incoming target.
        .onDisappear { inputTargetChanged?(inputOwner, nil) }
        .onChange(of: snapshot.selected) { previous, selected in
            if selected == nil, snapshot.focusLauncherOnClose { focusedLauncher = previous }
            else { focusedLauncher = nil }
            if selected != nil && selected == absorbedCardID { absorbedCardID = nil }
        }
        .onChange(of: snapshot.handoff?.id, initial: true) { _, id in
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { handoffProgress = 0; handoffResized = false }
            if id != nil || snapshot.input.thread.observation.isExecutionActive { absorbedCardID = nil }
        }
        .onChange(of: snapshot.handoff?.travelComplete) { _, complete in
            if complete == true { absorbedCardID = snapshot.handoff?.cardID }
        }
        .onChange(of: snapshot.handoff?.contentReady) { _, ready in
            guard ready == true, let id = snapshot.handoff?.id else { return }
            absorb(id, animated: !reduceMotion && !handoffResized && scenePhase == .active)
        }
        .onChange(of: reduceMotion) { _, reduced in
            guard reduced, let handoff = snapshot.handoff else { return }
            if handoff.contentReady { absorb(handoff.id, animated: false) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, let handoff = snapshot.handoff else { return }
            handoffResized = true
            if handoff.contentReady { absorb(handoff.id, animated: false) }
        }
    }

    private func absorb(_ id: UUID, animated: Bool) {
        withAnimation(animated ? NativeReadingPageTiming.replacementAnimation : nil, completionCriteria: .removed) {
            handoffProgress = 1
        } completion: { model.completeHandoffTravel(id) }
    }

    private func dockFrame(in layout: NativeSidecardWorkspaceGeometry) -> CGRect? {
        guard !preparing, !snapshot.suppressed, snapshot.handoff == nil,
              let card = snapshot.cards.first(where: { $0.id == snapshot.selected && $0.view.available }) else { return nil }
        // Activity-specific input belongs to that card's column. Otherwise the
        // Thread input follows execution ownership, with other activities in main.
        if card.view.composer != nil {
            return CGRect(x: layout.surfaceX, y: layout.surfaceY, width: layout.surfaceWidth, height: layout.surfaceHeight)
        }
        let historicalInput = inputTarget.map { !$0.followsLatest && $0.executionID != snapshot.input.thread.observation.latestExecution?.executionID } ?? false
        if !historicalInput, snapshot.input.thread.observation.isExecutionActive,
           let executionID = snapshot.input.thread.observation.latestExecution?.executionID,
           card.view.excludeExecutionID == executionID {
            return CGRect(x: layout.surfaceX, y: layout.surfaceY, width: layout.surfaceWidth, height: layout.surfaceHeight)
        }
        return CGRect(x: 0, y: 0, width: layout.mainWidth, height: layout.mainHeight)
    }

    private var contentHandoff: NativeReadingContentHandoff? {
        guard let handoff = snapshot.handoff else { return nil }
        return NativeReadingContentHandoff(id: handoff.id, executionID: handoff.executionID) {
            model.receiveMainExecutionReady(handoff.executionID, handoffID: handoff.id)
        }
    }

    private var mainConversation: some View {
        VStack(spacing: 0) {
            NativeThreadPreparedReader {
                NativeHarnessThreadView(host: model.harnessHost, input: snapshot.input,
                presentation: .main(excludedExecutionIDs: snapshot.excludedExecutionIDs),
                routes: model.routes, onIndexChange: model.receiveIndex)
                .environment(\.nativeReadingContentHandoff, contentHandoff)
                .environment(\.nativeReadingContentReady, contentHandoff?.ready)
                .disabled(snapshot.executionDisabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // A promoting sidecard already displays this execution. Do not blank it
        // for a second entrance when the main reader takes ownership.
        .environment(\.nativeThreadContentReveal, snapshot.handoff == nil)
        // An active execution owned by a Sidecard leaves existing history in
        // main, even while folded. Keep readiness gates, but do not replay ink.
        .environment(\.nativeThreadContentRevealAnimated,
            !(snapshot.input.thread.observation.isExecutionActive
                && snapshot.input.thread.observation.latestExecution.map {
                    snapshot.excludedExecutionIDs.contains($0.executionID)
                } == true))
        .transformPreference(NativeReadingContentRevealStatusKey.self) { status in
            // The identity-only preparation reader has no loaded document. Its
            // placeholder must not leave a ready value for the live reader.
            if preparing { status = .init() }
        }
        .onPreferenceChange(NativeReadingContentRevealStatusKey.self, perform: onContentRevealChange)
        // Reserve the history rail across initial loading. The reading column
        // still centers itself inside the current main pane when it resizes.
        .environment(\.nativeThreadReservesHistoryRail, true)
        // The 48pt leading rail keeps the document and its scroller to the
        // right of Close; the rail itself has 64pt of vertical clearance.
        // Do not also reserve Close's height above the entire reading viewport.
        .nativeReadingPanelViewport(topInset: 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localize("对话轮次", "Conversation turns"))
        // History owns its own Escape. Keep this fallback out of Sidecards so
        // their browser, annotation and nested conversation handlers act first.
        .nativeReadingEscape(perform: snapshot.suppressed || hasNestedNavigation ? nil : { closeTopLevel() })
    }

    private func closeTopLevel() {
        guard !snapshot.suppressed else { return }
        if let selected = snapshot.selected { model.close(selected) }
        else { model.closeThread() }
    }

    private func sidecard(_ card: NativeSidecardWorkspaceCard, layout: NativeSidecardWorkspaceGeometry, source: CGRect?) -> some View {
        let expanded = snapshot.selected == card.id
        let promoting = snapshot.handoff?.cardID == card.id
        let progress = promoting ? handoffProgress : 0
        let destination = CGRect(
            x: layout.surfaceX - (layout.stacked ? 0 : layout.surfaceWidth * 0.8 + 16) * progress,
            y: layout.surfaceY * (1 - progress),
            width: layout.surfaceWidth, height: layout.surfaceHeight)
        return Group {
            if preparing { Color.clear } else { card.view.content }
        }
            // Only the main reading body may drive the window's navigation chrome.
            // Sidecards reuse timelines and can contain further nested reading views.
            .environment(\.nativeReadingNavigation, nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .nativeLayoutLog("agent.sidecard")
            .clipShape(RoundedRectangle(cornerRadius: 21))
            .modifier(NativeSidecardFold(progress: expanded ? 1 : 0, source: source, destination: destination,
                frameIdentifier: "sidecard-aperture-" + card.id.string))
            // Once occluded, retire the source invisibly through its normal
            // fold. Removing handoff must not expose a second closing flight.
            .opacity(card.id == absorbedCardID ? 0 : 1)
            .zIndex(expanded ? 1 : 0)
            .allowsHitTesting(expanded && !snapshot.suppressed && !promoting)
            // Native documents retain their suppression policy during travel;
            // the separate launcher remains available to reverse the choice.
            .disabled(!expanded || snapshot.suppressed || promoting)
            .accessibilityHidden(!expanded || snapshot.suppressed || promoting)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(card.view.label.string)
            .background {
                NativeSidecardContentFocus(request: snapshot.selectionRevision,
                    enabled: card.view.focusContentOnOpen && expanded && !snapshot.suppressed && !snapshot.transitioning)
                    .frame(width: layout.surfaceWidth, height: layout.surfaceHeight)
                    .offset(x: layout.surfaceX, y: layout.surfaceY)
            }
            .nativeReadingExitCommand(perform: expanded && !snapshot.suppressed ? { model.close(card.id) } : nil)
    }

    private var launchers: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 14) {
                ForEach(snapshot.available) { card in
                    NativeSidecardToggle(expanded: snapshot.selected == card.id, label: card.view.label.string,
                        action: { model.activate(card.id) }) {
                        card.icon.frame(width: 42, height: 42).contentShape(Circle())
                            .overlay(alignment: .topTrailing) {
                                if let indicator = card.view.indicator {
                                    Circle().fill((indicator == .attention ? NativePalette.thread.warning : NativePalette.thread.accent).swiftUI)
                                        .frame(width: 5, height: 5).padding(7).accessibilityHidden(true)
                                }
                            }
                    }
                    .anchorPreference(key: NativeSidecardLauncherAnchors.self, value: .bounds) { [card.id: $0] }
                    .focused($focusedLauncher, equals: card.id)
                    .accessibilityIdentifier("sidecard-toggle-" + card.id.string)
                }
            }
        }
        .disabled(snapshot.suppressed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localize("Thread 卡片", "Thread cards"))
    }

    private func localize(_ chinese: String, _ english: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? chinese : english
    }
}

extension NativeSidecardWorkspaceGeometry {
    init(size: CGSize, snapshot: NativeSidecardWorkspaceSnapshot) {
        let owner = snapshot.selected ?? snapshot.lastSelected
        self.init(size: size, open: snapshot.selected != nil,
            preferredWidth: snapshot.cards.first(where: { $0.id == owner })?.view.preferredWidth ?? 1 / 3,
            retainedWidth: owner.flatMap { snapshot.widths[$0] })
    }
}

private struct NativeSidecardLauncherAnchors: PreferenceKey {
    static let defaultValue: [JSONText: Anchor<CGRect>] = [:]
    static func reduce(value: inout [JSONText: Anchor<CGRect>], nextValue: () -> [JSONText: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
