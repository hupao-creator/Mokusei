import SwiftUI

/// The plugin supplies all semantic contents; this view only places/render its cells.
public struct HarnessThreadCard: View {
    public let identity: ThreadCardIdentityView
    public let presentation: ThreadCardPresentation
    private let onRespond: ThreadCardInterventionHandler?
    private let onOpen: (() -> Void)?
    private let onFollowUp: (() -> Void)?
    private let slots: [String: AnyView]
    private let interventionDetails: AnyView?
    private let interventionActionLabel: ((ThreadCardDecisionAction) -> String)?
    private let status: ThreadCardStatusProjection?
    private let emoji: String?
    private let providerStatus: AnyView?
    private let state: AnyView?
    private let harnessLogo: AnyView?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.threadCardCloudAnimationsEnabled) private var cloudAnimationsEnabled
    @State private var hovered = false

    public init(identity: ThreadCardIdentityView, presentation: ThreadCardPresentation,
                onRespond: ThreadCardInterventionHandler? = nil, onOpen: (() -> Void)? = nil,
                onFollowUp: (() -> Void)? = nil, slots: [String: AnyView] = [:],
                interventionDetails: AnyView? = nil,
                interventionActionLabel: ((ThreadCardDecisionAction) -> String)? = nil,
                status: ThreadCardStatusProjection? = nil, emoji: String? = nil,
                providerStatus: AnyView? = nil, state: AnyView? = nil, harnessLogo: AnyView? = nil,
                onInterventionResponse: ThreadCardInterventionHandler? = nil, onOpenThread: (() -> Void)? = nil) {
        self.identity = identity; self.presentation = presentation; self.onRespond = onInterventionResponse ?? onRespond
        self.onOpen = onOpenThread ?? onOpen; self.onFollowUp = onFollowUp; self.slots = slots
        self.interventionDetails = interventionDetails; self.interventionActionLabel = interventionActionLabel
        self.status = status; self.emoji = emoji; self.providerStatus = providerStatus; self.state = state
        self.harnessLogo = harnessLogo
    }

    public var body: some View {
        GeometryReader { geometry in
            let columns = max(1, presentation.size.cols)
            let rows = max(1, presentation.size.rows)
            let cell = CGSize(width: max(0, (geometry.size.width - CGFloat(columns - 1) * 16) / CGFloat(columns)),
                              height: max(0, (geometry.size.height - CGFloat(rows - 1) * 16) / CGFloat(rows)))
            ZStack(alignment: .topLeading) {
                ThreadCardIdentity(identity: identity, projection: presentation.projection.identity,
                                   expanded: presentation.composition.identitySize.rows > 1,
                                   status: status, emoji: emoji, providerStatus: providerStatus, state: state,
                                   harnessLogo: harnessLogo, onFollowUp: onFollowUp)
                    .frame(width: span(presentation.composition.identitySize.cols, cell.width),
                           height: span(presentation.composition.identitySize.rows, cell.height), alignment: .topLeading)
                switch presentation.composition {
                case .slots(_, _, let cells, _):
                    ForEach(cells) { slot in
                        slots[slot.id]
                            .frame(width: span(slot.size.cols, cell.width), height: span(slot.size.rows, cell.height), alignment: .topLeading)
                            .offset(x: CGFloat(slot.col) * (cell.width + 16), y: CGFloat(slot.row) * (cell.height + 16))
                    }
                case .standard(_, _, let placements, _):
                    ForEach(placements, id: \.kind) { placement in
                        if let item = extensionProjection(placement.kind) {
                            extensionContent(item, placement: placement)
                                .padding(.horizontal, 18).padding(.vertical, 16)
                                .frame(width: span(placement.selectedSize.cols, cell.width),
                                       height: span(placement.selectedSize.rows, cell.height), alignment: .topLeading)
                                .clipped()
                                .offset(x: CGFloat(placement.col) * (cell.width + 16), y: CGFloat(placement.row) * (cell.height + 16))
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: placement.col > 0 ? -16 : 0, y: placement.row > 0 ? -16 : 0)), removal: .opacity))
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(idealWidth: CGFloat(presentation.size.cols) * 360 + CGFloat(max(0, presentation.size.cols - 1)) * 16,
               idealHeight: CGFloat(presentation.size.rows) * 200 + CGFloat(max(0, presentation.size.rows - 1)) * 16)
        .background {
            ThreadCardCloud(running: status?.kind == .running)
                .environment(\.threadCardCloudAnimationsEnabled, cloudAnimationsEnabled && !(identity.initialResponse != nil && reduceMotion))
        }
        .environment(\.threadCardHovered, hovered)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.22), value: presentation.key)
    }
    private func span(_ count: Int, _ cell: CGFloat) -> CGFloat { CGFloat(count) * cell + CGFloat(max(0, count - 1)) * 16 }
    private func extensionProjection(_ kind: ThreadCardExtensionKind) -> ThreadCardExtensionProjection? {
        guard case .standard(_, let extensions) = presentation.projection else { return nil }
        return extensions.last { $0.kind == kind }
    }
    @ViewBuilder private func extensionContent(_ item: ThreadCardExtensionProjection, placement: ThreadCardExtensionPlacement) -> some View {
        switch item {
        case .git(let status): ThreadCardGitExtension(status: status)
        case .todo(let steps): CardPlanLadder(steps: steps, variant: placement.variant)
        case .derived(let rows): CardDerivedWork(rows: rows, variant: placement.variant, capacity: placement.selectedSize.rows > 1 ? 12 : 6)
        case .intervention(let intervention):
            CardInterventionPanel(intervention: intervention, variant: placement.variant, onRespond: onRespond,
                                  onOpenThread: onOpen, details: interventionDetails, actionLabel: interventionActionLabel)
                .id(intervention.id)
        }
    }
}

private struct ThreadCardIdentity: View {
    let identity: ThreadCardIdentityView
    let projection: ThreadCardIdentityProjection?
    let expanded: Bool
    let status: ThreadCardStatusProjection?
    let emoji: String?
    let providerStatus: AnyView?
    let state: AnyView?
    let harnessLogo: AnyView?
    let onFollowUp: (() -> Void)?
    @Environment(\.locale) private var locale
    @Environment(\.threadCardProviderColor) private var providerColor
    private var cornerClearance: CGFloat { ThreadCardProviderStatus.diameter + 8 }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let state { state.padding(.bottom, 6).padding(.trailing, cornerClearance) }
            else if let status, identity.initialResponse == nil, status.showsState { ThreadCardTaskState(status: status).padding(.bottom, 6).padding(.trailing, cornerClearance) }
            else if let state = identity.state { Text(state).font(NativeTypography.inter(size: 12, weight: 650)).padding(.bottom, 6).padding(.trailing, cornerClearance) }
            CardTitleSwap(text: identity.title)
                .foregroundStyle(NativePalette.overview.ink.swiftUI)
                .lineLimit(2).padding(.trailing, cornerClearance).help(identity.title)
            if identity.harness != nil || identity.model != nil || effort != nil || identity.fastMode {
                HStack(spacing: 5) {
                    if let harnessLogo { harnessLogo.frame(width: 12, height: 12) }
                    else if let harness = identity.harness { ThreadCardBrandLogo(logoSource: harness.logoSource, label: harness.label, brandKey: harness.brandKey) }
                    HStack(spacing: 0) {
                        if let model = identity.model { Text(model).cardFont(size: 11, weight: 580).foregroundStyle(NativePalette.pair(0x10110f, 0xe0e5da, alpha: 0.58).swiftUI) }
                        if effort != nil || identity.fastMode {
                            if identity.model != nil { Text(" · ").cardFont(size: 11) }
                            HStack(spacing: 1) {
                                if identity.fastMode { NativeIcon(name: "Zap", size: 10) }
                                if let effort { Text(effort).cardFont(size: 11, weight: identity.fastMode ? 600 : 400) }
                            }.font(NativeTypography.inter(size: 11, weight: identity.fastMode ? 600 : 400))
                                .foregroundStyle(identity.fastMode ? providerColor : NativePalette.overview.faint.swiftUI)
                        }
                    }.lineLimit(1)
                }
                .font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.overview.faint.swiftUI)
                .padding(.top, 5).padding(.trailing, cornerClearance)
            }
            if identity.runtime != nil || projection?.usage?.parts.isEmpty == false {
                HStack(alignment: .center, spacing: 10) {
                    if let runtime = identity.runtime { ThreadCardRuntime(startedAt: runtime.startedAt, endedAt: runtime.endedAt) }
                    if let usage = projection?.usage, !usage.parts.isEmpty {
                        if identity.runtime != nil { Rectangle().fill(NativePalette.overview.muted.swiftUI.opacity(0.35)).frame(width: 1, height: 10) }
                        ThreadCardUsage(usage: usage)
                    }
                }.padding(.top, 5)
            }
            if let steer = identity.steer, !steer.isEmpty {
                HStack(spacing: 4) {
                    NativeIcon(name: "CornerDownRight", size: 11).foregroundStyle(providerColor)
                    Text(steer).lineLimit(1)
                }.font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.overview.muted.swiftUI)
                    .padding(.top, 8).help(steer)
            }
            ThreadCardBody(identity: identity, expanded: expanded).padding(.top, 10)
            if expanded {
                ForEach(Array(recentTools.enumerated()), id: \.offset) { index, tool in
                    ThreadCardLatestTool(tool: tool).padding(.top, index == 0 ? 14 : 7)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            Group {
                if let providerStatus { providerStatus }
                else if let status {
                    ThreadCardProviderStatus(label: status.providerLabel(identity.harness?.label, locale: locale), brandKey: identity.harness?.brandKey ?? "", emoji: emoji,
                                             terminal: status.terminal, onFollowUp: onFollowUp)
                } else if let providerStatus = identity.providerStatus {
                    ThreadCardProviderStatus(label: providerStatus, brandKey: identity.harness?.brandKey ?? "", emoji: emoji, onFollowUp: onFollowUp)
                } else if emoji != nil || onFollowUp != nil {
                    ThreadCardProviderStatus(label: identity.title, brandKey: identity.harness?.brandKey ?? "", emoji: emoji, onFollowUp: onFollowUp)
                }
            }.padding(.top, 12).padding(.trailing, 17)
        }
        .clipped()
    }
    private var effort: String? {
        if let value = identity.effort, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           value.trimmingCharacters(in: .whitespacesAndNewlines) != "default" {
            return cardLocalized(value, identity.harness?.brandKey == "codex" ? Locale(identifier: "en") : locale)
        }
        return identity.model == nil ? nil : cardLocalized("默认", locale)
    }
    private var recentTools: [ThreadCardIdentityTool] {
        Array((projection?.recentTools ?? projection?.latestTool.map { [$0] } ?? []).suffix(3))
    }
}

private struct CardTitleSwap: View {
    let text: String
    @State private var displayed: String
    @State private var phase = 0
    init(text: String) { self.text = text; _displayed = State(initialValue: text) }
    var body: some View {
        Text(displayed).cardFont(size: 15, weight: 620).offset(y: phase == 1 ? -4 : phase == 2 ? 4 : 0)
            .blur(radius: phase == 0 ? 0 : 2).opacity(phase == 0 ? 1 : 0)
            .task(id: text) {
                guard displayed != text else { return }
                withAnimation(.easeInOut(duration: 0.15)) { phase = 1 }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                displayed = text; phase = 2
                do { try await Task.sleep(for: .seconds(NativeFrameRate.interval)) } catch { return }
                withAnimation(.easeInOut(duration: 0.15)) { phase = 0 }
            }
    }
}

public struct ThreadCardLatestTool: View {
    public let tool: ThreadCardIdentityTool
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.threadCardCloudAnimationsEnabled) private var enabled
    @Environment(\.threadCardAnimationVisibility) private var visibility
    @Environment(\.threadCardProviderColor) private var providerColor
    private var animates: Bool {
        tool.status == .running && scenePhase != .background && !reduceMotion && enabled && (visibility?.isVisible ?? true)
    }
    public init(tool: ThreadCardIdentityTool) { self.tool = tool }
    public var body: some View {
        HStack(spacing: 6) {
            NativeIcon(name: kindIcon, size: 13).foregroundStyle(providerColor)
            Text(tool.name).font(NativeTypography.inter(size: 10, weight: 650)).lineLimit(1)
            if let summary = tool.summary { Text(summary).lineLimit(1).help(summary).frame(maxWidth: .infinity, alignment: .leading) }
            else { Spacer(minLength: 0) }
            // Flipping state cannot retract a repeatForever animation because
            // that change is animated too; only the schedule pauses at its source.
            TimelineView(.animation(minimumInterval: NativeFrameRate.interval, paused: !animates)) { context in
                NativeIcon(name: statusIcon, size: 13)
                    .foregroundStyle(tool.status == .failed ? NativePalette.overview.danger.swiftUI : tool.status == .running ? NativePalette.overview.accent.swiftUI : NativePalette.overview.faint.swiftUI)
                    .rotationEffect(.degrees(rotation(at: context.date)))
            }
            .accessibilityLabel(cardLocalized(statusLabel, locale))
        }.font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.overview.muted.swiftUI)
    }
    private func rotation(at date: Date) -> Double {
        guard animates else { return 0 }
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360
    }
    private var kindIcon: String { switch tool.kind { case .command: "Terminal"; case .file: "FileText"; case .search: "Search"; case .tool: "Wrench" } }
    private var statusIcon: String { switch tool.status { case .running: "LoaderCircle"; case .failed: "CircleX"; case .cancelled: "CircleAlert"; case .completed: "CheckCircle2" } }
    private var statusLabel: String { switch tool.status { case .running: "运行中"; case .failed: "失败"; case .cancelled: "已取消"; case .completed: "已完成" } }
}

public struct ThreadCardUsage: View {
    public let usage: ThreadCardIdentityUsage
    public init(usage: ThreadCardIdentityUsage) { self.usage = usage }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            ForEach(Array(usage.parts.enumerated()), id: \.element.id) { index, part in
                if index > 0 { Text(" · ").cardFont(size: 11) }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let label = part.label { Text(label) }
                    HStack(alignment: .center, spacing: 4) {
                        if part.suffix == "tokens" { NativeIcon(name: "Combine", size: 12) }
                        if part.numericValue == nil { Text(part.value) } else { RollingNumberText(value: part.value) }
                    }
                    if let suffix = part.suffix, suffix != "tokens" { Text(suffix).font(.custom("Rockwell", size: 10)) }
                }
                .help(part.description ?? "")
                .focusable()
                .accessibilityLabel(part.numericValue.map { "\($0.formatted()) \(part.suffix ?? "")" } ?? part.value)
            }
        }.font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.overview.muted.swiftUI)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ThreadCardHoveredKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var threadCardHovered: Bool {
        get { self[ThreadCardHoveredKey.self] }
        set { self[ThreadCardHoveredKey.self] = newValue }
    }
}

private struct ThreadCardProviderColorKey: EnvironmentKey {
    static let defaultValue = NativePalette.overview.provider.swiftUI
}
public extension EnvironmentValues {
    /// The owning Harness supplies its original brand accent without shared semantic lookup.
    var threadCardProviderColor: Color {
        get { self[ThreadCardProviderColorKey.self] }
        set { self[ThreadCardProviderColorKey.self] = newValue }
    }
}
