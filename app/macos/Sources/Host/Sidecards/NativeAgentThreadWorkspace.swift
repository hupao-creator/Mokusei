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
    private let followUpRequest: NativeSidecardFollowUpRequest?
    private let sidecardsSuppressed: Bool
    private let enabledSidecardIDs: Set<JSONText>?
    private let services: NativeSidecardWorkspaceServices
    private let onBack: () -> Void
    private let onFollowUpVisibilityChange: (Bool) -> Void
    private let backLabel: String?
    private let onNavigationChange: ((ThreadDetailBackAction?) -> Void)?
    @Environment(\.locale) private var locale
    @State private var navigation: ThreadDetailBackAction

    public init(harnessHost: NativeHarnessHost, thread: HarnessThread, registry: SidecardPluginRegistry,
                executionDisabled: Bool = false, readingTarget: HarnessReadingTarget? = nil,
                followUpRequest: NativeSidecardFollowUpRequest? = nil, sidecardsSuppressed: Bool = false,
                enabledSidecardIDs: Set<JSONText>? = nil, services: NativeSidecardWorkspaceServices,
                onBack: @escaping () -> Void, onFollowUpVisibilityChange: @escaping (Bool) -> Void = { _ in },
                backLabel: String? = nil, onNavigationChange: ((ThreadDetailBackAction?) -> Void)? = nil) {
        self.harnessHost = harnessHost; self.thread = thread; self.registry = registry
        self.executionDisabled = executionDisabled; self.readingTarget = readingTarget
        self.followUpRequest = followUpRequest; self.sidecardsSuppressed = sidecardsSuppressed
        self.enabledSidecardIDs = enabledSidecardIDs; self.services = services
        self.onBack = onBack; self.onFollowUpVisibilityChange = onFollowUpVisibilityChange
        self.backLabel = backLabel; self.onNavigationChange = onNavigationChange
        _navigation = State(initialValue: ThreadDetailBackAction(label: backLabel ?? "返回俯瞰", onBack: onBack))
    }

    public var body: some View {
        let label = backLabel ?? (locale.language.languageCode?.identifier == "zh" ? "返回俯瞰" : "Back to overview")
        ThreadDetailFrame(navigation: navigation, onNavigationChange: onNavigationChange) {
                NativeThreadWorkspaceBody(harnessHost: harnessHost, thread: thread, registry: registry,
                    executionDisabled: executionDisabled, readingTarget: readingTarget, followUpRequest: followUpRequest,
                    sidecardsSuppressed: sidecardsSuppressed, enabledSidecardIDs: enabledSidecardIDs,
                    services: services, onBack: onBack, onFollowUpVisibilityChange: onFollowUpVisibilityChange)
                    .id([thread.id, thread.harnessID])
            }
            .task(id: [thread.id, JSONText(label)]) {
                navigation = ThreadDetailBackAction(label: label, onBack: onBack)
            }
    }
}

@MainActor
private struct NativeThreadWorkspaceBody: View {
    let harnessHost: NativeHarnessHost
    let thread: HarnessThread
    let registry: SidecardPluginRegistry
    let executionDisabled: Bool
    let readingTarget: HarnessReadingTarget?
    let followUpRequest: NativeSidecardFollowUpRequest?
    let sidecardsSuppressed: Bool
    let enabledSidecardIDs: Set<JSONText>?
    let services: NativeSidecardWorkspaceServices
    let onBack: () -> Void
    let onFollowUpVisibilityChange: (Bool) -> Void
    @Environment(\.locale) private var locale
    @State private var model: NativeSidecardWorkspaceModel?

    private var configuration: NativeSidecardWorkspaceConfiguration {
        NativeSidecardWorkspaceConfiguration(input: HarnessThreadInput(thread: thread, readingTarget: readingTarget),
            executionDisabled: executionDisabled, suppressed: sidecardsSuppressed, enabledIDs: enabledSidecardIDs,
            followUpRequest: followUpRequest, locale: locale)
    }

    var body: some View {
        Group {
            if let model, let snapshot = model.snapshot {
                NativeSidecardWorkspaceLayout(model: model, snapshot: snapshot)
            } else {
                NativePalette.thread.canvas.swiftUI
            }
        }
        .background(NativePalette.thread.canvas.swiftUI)
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
private struct NativeSidecardWorkspaceLayout: View {
    let model: NativeSidecardWorkspaceModel
    let snapshot: NativeSidecardWorkspaceSnapshot
    @Environment(\.locale) private var locale
    @FocusState private var focusedLauncher: JSONText?

    private var animation: Animation? {
        snapshot.dragging ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.38)
    }
    private var dividerHitWidth: CGFloat {
        6
    }
    private var launcherSize: CGSize {
        CGSize(width: 32, height: 30)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = NativeSidecardWorkspaceGeometry(size: geometry.size, snapshot: snapshot)
            ZStack(alignment: .topLeading) {
                mainConversation
                    .frame(width: layout.mainWidth, height: layout.mainHeight, alignment: .topLeading)
                if snapshot.selected != nil && !layout.stacked {
                    NativeSidecardDivider(width: layout.cardWidth, maximumWidth: layout.maximumCardWidth,
                        onWidthChange: { model.resize($0, maximum: layout.maximumCardWidth) },
                        onDraggingChange: model.setDragging)
                        .frame(width: dividerHitWidth, height: geometry.size.height)
                        .offset(x: layout.mainWidth - (dividerHitWidth - 6) / 2)
                        .zIndex(2)
                        .accessibilityLabel(localize("调整卡片宽度", "Resize card"))
                }
                // All sessions remain in this ForEach, including folded and
                // suppressed cards, so child Harness interaction state survives.
                ForEach(snapshot.cards) { card in
                    sidecard(card, layout: layout)
                }
                launchers
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 16).padding(.trailing, 12)
            }
            .animation(animation, value: snapshot.selected)
            .animation(animation, value: layout.stacked)
            .clipped()
        }
        .onChange(of: snapshot.selected) { previous, selected in
            if selected == nil { focusedLauncher = previous }
            else { focusedLauncher = nil }
        }
    }

    private var mainConversation: some View {
        VStack(spacing: 0) {
            NativeHarnessThreadView(host: model.harnessHost, input: snapshot.input,
                presentation: .main(excludedExecutionIDs: snapshot.excludedExecutionIDs),
                routes: model.routes, onIndexChange: model.receiveIndex)
                .disabled(snapshot.executionDisabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = snapshot.requestError {
                Text(message).font(.system(size: 12)).foregroundStyle(NativePalette.thread.danger.swiftUI)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(message)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localize("对话轮次", "Conversation turns"))
    }

    private func sidecard(_ card: NativeSidecardWorkspaceCard, layout: NativeSidecardWorkspaceGeometry) -> some View {
        let expanded = snapshot.selected == card.id
        let availableIndex = snapshot.available.firstIndex(where: { $0.id == card.id }) ?? 0
        let trailingLaunchers = max(0, snapshot.available.count - availableIndex - 1)
        let foldedX = -6 - CGFloat(trailingLaunchers) * launcherSize.width
        let foldedY: CGFloat = 6 - (layout.stacked ? layout.size.height / 2 : 0)
        return card.view.content
            // Only the main reading body may drive the window's navigation chrome.
            // Sidecards reuse timelines and can contain further nested reading views.
            .environment(\.nativeReadingNavigation, nil)
            .frame(width: layout.surfaceWidth, height: layout.surfaceHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 21))
            .background(NativeSidecardGlass())
            .mask(NativeSidecardFoldMask(progress: expanded ? 1 : 0))
            .animation(.easeInOut(duration: 0.16)) { content in
                content.opacity(expanded ? 1 : 0)
            }
            .offset(x: layout.surfaceX + (expanded ? 0 : foldedX),
                    y: layout.surfaceY + (expanded ? 0 : foldedY))
            .allowsHitTesting(expanded && !snapshot.suppressed)
            // The plugin suppresses its native document during movement, but
            // its controls (especially Close) remain usable while opening.
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
            .nativeOnExitCommand { if expanded { model.close(card.id) } }
    }

    private var launchers: some View {
        HStack(spacing: 0) {
            ForEach(snapshot.available) { card in
                Button { model.activate(card.id) } label: {
                    card.icon.frame(width: launcherSize.width, height: launcherSize.height)
                        .overlay(alignment: .topTrailing) {
                            if let indicator = card.view.indicator {
                                Circle().fill((indicator == .attention ? NativePalette.thread.warning : NativePalette.thread.accent).swiftUI)
                                    .frame(width: 5, height: 5)
                                    .overlay(Circle().stroke(NativePalette.thread.surfaceStrong.swiftUI, lineWidth: 2))
                                    .padding(.top, 4).padding(.trailing, 3).accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(NativeSidecardLauncherStyle())
                .focused($focusedLauncher, equals: card.id)
                .help(card.view.label.string).accessibilityLabel(card.view.label.string)
                .accessibilityValue(localize("已收起", "Collapsed"))
            }
        }
        .padding(5)
        .glassEffect(.regular.interactive(), in: .capsule)
        .opacity(snapshot.selected == nil && !snapshot.available.isEmpty ? 1 : 0)
        .allowsHitTesting(snapshot.selected == nil && !snapshot.available.isEmpty && !snapshot.suppressed)
        .disabled(snapshot.selected != nil || snapshot.suppressed)
        .accessibilityHidden(snapshot.selected != nil || snapshot.available.isEmpty || snapshot.suppressed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localize("Thread 卡片", "Thread cards"))
    }

    private func localize(_ chinese: String, _ english: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? chinese : english
    }
}

@MainActor
private struct NativeSidecardWorkspaceGeometry {
    let size: CGSize
    let stacked: Bool
    let cardWidth: CGFloat
    let maximumCardWidth: CGFloat
    let mainWidth: CGFloat
    let mainHeight: CGFloat
    let surfaceWidth: CGFloat
    let surfaceHeight: CGFloat
    let surfaceX: CGFloat
    let surfaceY: CGFloat

    init(size: CGSize, snapshot: NativeSidecardWorkspaceSnapshot) {
        self.size = size; stacked = size.width > 0 && size.width < 760
        let usableWidth = max(0, size.width - 6)
        maximumCardWidth = max(320, usableWidth - 360)
        let owner = snapshot.selected ?? snapshot.lastSelected
        let preferred = snapshot.cards.first(where: { $0.id == owner })?.view.preferredWidth ?? 1 / 3
        let fraction = preferred.isFinite ? preferred : 1 / 3
        cardWidth = min(maximumCardWidth, max(320, owner.flatMap { snapshot.widths[$0] } ?? (usableWidth * fraction).rounded()))
        let open = snapshot.selected != nil
        mainWidth = max(0, size.width - (!stacked && open ? cardWidth + 6 : 0))
        mainHeight = max(0, stacked && open ? size.height / 2 : size.height)
        surfaceWidth = max(0, (stacked ? size.width : cardWidth) - 16)
        surfaceHeight = max(0, (stacked ? size.height / 2 : size.height) - 32)
        surfaceX = max(0, size.width - 12 - surfaceWidth)
        surfaceY = 16 + (stacked ? size.height / 2 : 0)
    }
}

private struct NativeSidecardFoldMask: Shape {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func path(in rect: CGRect) -> Path {
        let width = 32 + (rect.width - 32) * progress
        let height = 30 + (rect.height - 30) * progress
        return Path(roundedRect: CGRect(x: rect.maxX - width, y: 0, width: max(0, width), height: max(0, height)),
                    cornerRadius: 21)
    }
}

private struct NativeSidecardLauncherStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NativeSidecardLauncherLabel(configuration: configuration)
    }
}

private struct NativeSidecardLauncherLabel: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    var body: some View {
        configuration.label.foregroundStyle(NativePalette.thread.ink.swiftUI)
            .background(NativePalette.thread.ink.swiftUI.opacity(configuration.isPressed ? 0.12 : hovered ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
    }
}
