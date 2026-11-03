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
                executionReveal: SidecardExecutionReveal? = nil) {
        self.harnessHost = harnessHost; self.thread = thread; self.registry = registry
        self.executionDisabled = executionDisabled; self.readingTarget = readingTarget
        self.sidecardsSuppressed = sidecardsSuppressed
        self.enabledSidecardIDs = enabledSidecardIDs; self.services = services
        self.onBack = onBack; self.onFollowUpVisibilityChange = onFollowUpVisibilityChange
        self.backLabel = backLabel; self.onNavigationChange = onNavigationChange
        self.executionReveal = executionReveal
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
                    services: services, executionReveal: executionReveal,
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
    let onBack: () -> Void
    let onFollowUpVisibilityChange: (Bool) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.nativeAgentHasNestedNavigation) private var hasNestedNavigation
    @State private var model: NativeSidecardWorkspaceModel?

    private var configuration: NativeSidecardWorkspaceConfiguration {
        NativeSidecardWorkspaceConfiguration(input: HarnessThreadInput(thread: thread, readingTarget: readingTarget),
            executionDisabled: executionDisabled, suppressed: sidecardsSuppressed, enabledIDs: enabledSidecardIDs,
            locale: locale, executionReveal: executionReveal, mainReadingHistory: hasNestedNavigation)
    }

    var body: some View {
        Group {
            if let model, let snapshot = model.snapshot {
                NativeSidecardWorkspaceLayout(model: model, snapshot: snapshot)
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
        .onDisappear { model?.release(); model = nil }
    }
}

@MainActor
struct NativeSidecardWorkspaceLayout: View {
    @Environment(\.nativeThreadPreparing) private var preparing
    let model: NativeSidecardWorkspaceModel
    let snapshot: NativeSidecardWorkspaceSnapshot
    /// Previews/replays can supply the same policy without changing OS settings.
    var motionReduced: Bool? = nil
    @Environment(\.locale) private var locale
    @Environment(\.nativeAgentHasNestedNavigation) private var hasNestedNavigation
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var focusedLauncher: JSONText?
    @State private var handoffProgress: CGFloat = 0
    @State private var handoffOpacity: Double = 1
    private var reduceMotion: Bool { motionReduced ?? systemReduceMotion }

    private var animation: Animation? {
        snapshot.dragging || reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.38)
    }
    private var dividerHitWidth: CGFloat {
        6
    }
    private var launcherSize: CGSize {
        CGSize(width: 32, height: 30)
    }

    var body: some View {
        GeometryReader { geometry in
            // The toolbar has an actual layout seat, not merely an offset
            // outside the reader; native hit testing must reach that background.
            let panelSize = CGSize(width: max(1, geometry.size.width - 76), height: geometry.size.height)
            let layout = NativeSidecardWorkspaceGeometry(size: panelSize, snapshot: snapshot)
            ZStack(alignment: .topLeading) {
                mainConversation
                    .frame(width: snapshot.handoff?.travelComplete == true ? panelSize.width : layout.mainWidth,
                           height: snapshot.handoff?.travelComplete == true ? panelSize.height : layout.mainHeight, alignment: .topLeading)
                    .background(NativePalette.thread.canvas.swiftUI)
                    .background(NativeReadingPanelFrame())
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(NativePalette.thread.line.swiftUI.opacity(0.6)))
                    .accessibilityIdentifier("agent-reading-panel")
                    .nativeLayoutLog("agent.reading.panel")
                    .allowsHitTesting(snapshot.handoff == nil)
                    .accessibilityHidden(snapshot.handoff != nil)
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
                    sidecard(card, layout: layout)
                }
                launchers.position(x: panelSize.width + 38, y: panelSize.height / 2)
            }
            .animation(animation, value: snapshot.selected)
            .animation(animation, value: layout.stacked)
        }
        .nativeReadingExitCommand {
            closeTopLevel()
        }
        .onChange(of: snapshot.selected) { previous, selected in
            if selected == nil, snapshot.focusLauncherOnClose { focusedLauncher = previous }
            else { focusedLauncher = nil }
        }
        .onChange(of: snapshot.handoff?.id, initial: true) { _, id in
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { handoffProgress = 0; handoffOpacity = 1 }
            guard let id else { return }
            withAnimation(reduceMotion ? nil : NativeReadingPageTiming.replacementAnimation, completionCriteria: .removed) {
                handoffProgress = 1
            } completion: { model.completeHandoffTravel(id) }
        }
        .onChange(of: snapshot.handoff?.contentReady) { _, ready in
            guard ready == true, let id = snapshot.handoff?.id else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16), completionCriteria: .removed) {
                handoffOpacity = 0
            } completion: { model.finishHandoff(id) }
        }
        .onChange(of: reduceMotion) { _, reduced in
            guard reduced, let handoff = snapshot.handoff else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { handoffProgress = 1 }
            model.completeHandoffTravel(handoff.id)
            if handoff.contentReady { model.finishHandoff(handoff.id) }
        }
    }

    private var contentHandoff: NativeReadingContentHandoff? {
        guard let handoff = snapshot.handoff, handoff.travelComplete else { return nil }
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
        // Sidecards can become available after their execution index arrives.
        // Keep the reading origin stable while only its available width changes.
        .environment(\.nativeThreadStableOrigin, true)
        .nativeReadingPanelViewport(balancedVerticalInsets: true)
        .nativeReadingPanelClose(label: localize("关闭 Thread", "Close thread"), onClose: model.closeThread)
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

    private func sidecard(_ card: NativeSidecardWorkspaceCard, layout: NativeSidecardWorkspaceGeometry) -> some View {
        let expanded = snapshot.selected == card.id
        let promoting = snapshot.handoff?.cardID == card.id
        let progress = promoting ? handoffProgress : 0
        let availableIndex = snapshot.available.firstIndex(where: { $0.id == card.id }) ?? 0
        let trailingLaunchers = max(0, snapshot.available.count - availableIndex - 1)
        let foldedX = -6 - CGFloat(trailingLaunchers) * launcherSize.width
        let foldedY: CGFloat = 6 - (layout.stacked ? layout.size.height / 2 : 0)
        return Group {
            if preparing { Color.clear } else { card.view.content }
        }
            // Only the main reading body may drive the window's navigation chrome.
            // Sidecards reuse timelines and can contain further nested reading views.
            .environment(\.nativeReadingNavigation, nil)
            .frame(width: layout.surfaceWidth + (layout.size.width - layout.surfaceWidth) * progress,
                   height: layout.surfaceHeight + (layout.size.height - layout.surfaceHeight) * progress, alignment: .topLeading)
            .nativeLayoutLog("agent.sidecard")
            .clipShape(RoundedRectangle(cornerRadius: 21))
            .background(NativePalette.thread.canvas.swiftUI, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).stroke(NativePalette.thread.line.swiftUI.opacity(0.6)))
            .modifier(NativeSidecardFold(progress: expanded ? 1 : 0))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { content in
                content.opacity(expanded ? (promoting ? handoffOpacity : 1) : 0)
            }
            .offset(x: layout.surfaceX * (1 - progress) + (expanded ? 0 : foldedX),
                    y: layout.surfaceY * (1 - progress) + (expanded ? 0 : foldedY))
            .zIndex(promoting ? 3 : 0)
            .allowsHitTesting(expanded && !snapshot.suppressed)
            // Native documents retain their suppression policy during travel;
            // the separate launcher remains available to reverse the choice.
            .disabled(!expanded || snapshot.suppressed)
            .accessibilityHidden(!expanded || snapshot.suppressed)
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
                    Button { model.activate(card.id) } label: {
                        card.icon.frame(width: 42, height: 42).contentShape(Circle())
                            .overlay(alignment: .topTrailing) {
                                if let indicator = card.view.indicator {
                                    Circle().fill((indicator == .attention ? NativePalette.thread.warning : NativePalette.thread.accent).swiftUI)
                                        .frame(width: 5, height: 5).padding(7).accessibilityHidden(true)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(snapshot.selected == card.id ? .blue.opacity(0.18) : .clear).interactive(), in: .circle)
                    .focused($focusedLauncher, equals: card.id)
                    .accessibilityIdentifier("sidecard-toggle-" + card.id.string)
                    .help(card.view.label.string).accessibilityLabel(card.view.label.string)
                    .accessibilityValue(localize(snapshot.selected == card.id ? "已展开" : "已收起", snapshot.selected == card.id ? "Expanded" : "Collapsed"))
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

@MainActor
public struct NativeSidecardWorkspaceGeometry {
    public let size: CGSize
    public let stacked: Bool
    public let cardWidth: CGFloat
    public let maximumCardWidth: CGFloat
    public let mainWidth: CGFloat
    public let mainHeight: CGFloat
    public let surfaceWidth: CGFloat
    public let surfaceHeight: CGFloat
    public let surfaceX: CGFloat
    public let surfaceY: CGFloat

    init(size: CGSize, snapshot: NativeSidecardWorkspaceSnapshot) {
        let owner = snapshot.selected ?? snapshot.lastSelected
        self.init(size: size, open: snapshot.selected != nil,
            preferredWidth: snapshot.cards.first(where: { $0.id == owner })?.view.preferredWidth ?? 1 / 3,
            retainedWidth: owner.flatMap { snapshot.widths[$0] })
    }
    public init(size: CGSize, open: Bool, preferredWidth: Double = 1 / 3, retainedWidth: CGFloat? = nil) {
        self.size = size; stacked = size.width > 0 && size.width < 760
        let usableWidth = max(0, size.width - 16)
        maximumCardWidth = max(320, usableWidth - 360)
        let fraction = preferredWidth.isFinite ? preferredWidth : 1 / 3
        cardWidth = min(maximumCardWidth, max(320, retainedWidth ?? (usableWidth * fraction).rounded()))
        mainWidth = max(0, size.width - (!stacked && open ? cardWidth + 16 : 0))
        mainHeight = max(0, stacked && open ? (size.height - 16) / 2 : size.height)
        surfaceWidth = max(0, stacked ? size.width : cardWidth)
        surfaceHeight = max(0, stacked ? (size.height - 16) / 2 : size.height)
        surfaceX = max(0, size.width - surfaceWidth)
        surfaceY = stacked ? (size.height + 16) / 2 : 0
    }
}
