import SwiftUI
import MokuseiPluginAPI

public enum ThreadCardTerminalStatus: String, Hashable, Sendable { case completed, interrupted, failed }
public enum ThreadCardStatusKind: String, Hashable, Sendable { case attention, failed, interrupted, running, completed, idle }
public struct ThreadCardStatusProjection: Hashable, Sendable {
    public let kind: ThreadCardStatusKind
    public let label: String
    public let icon: String?
    public let secondary: String?
    public let terminal: ThreadCardTerminalStatus?
    public let quiet: Bool
    public init(kind: ThreadCardStatusKind, label: String, icon: String? = nil, secondary: String? = nil,
                terminal: ThreadCardTerminalStatus? = nil, quiet: Bool = false) {
        self.kind = kind; self.label = label; self.icon = icon; self.secondary = secondary
        self.terminal = terminal; self.quiet = quiet
    }
    public var showsState: Bool { terminal == nil && kind != .running && kind != .idle && !quiet }

    // A newly published thread can precede execution admission. Keep its idle
    // classification without announcing a placeholder status in the card or tooltip.
    func providerLabel(_ provider: String?, locale: Locale) -> String {
        [provider, kind == .idle ? nil : cardLocalized(label, locale),
         secondary.map { cardLocalized($0, locale) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Status precedence only uses the public execution/background observation.
public func threadCardStatus(_ observation: ThreadPublicObservation) -> ThreadCardStatusProjection {
    let execution = observation.latestExecution
    let background = observation.backgroundWork?.status == .running
    let secondary = background ? "后台仍在运行" : nil
    if execution?.status == .waitingForUser {
        let question = execution?.interactions.contains { $0.kind == .question } == true
        let permission = execution?.interactions.contains { $0.kind == .permission } == true
        return .init(kind: .attention,
                     label: question && permission ? "需要你处理" : question ? "等你回答" : permission ? "等你授权" : "等待你的响应",
                     icon: question ? "MessageCircle" : "ShieldCheck", secondary: secondary, quiet: question || permission)
    }
    if execution?.status == .failed || execution?.status == .interrupted {
        let failed = execution?.status == .failed
        return .init(kind: failed ? .failed : .interrupted, label: failed ? "执行失败" : "已中断",
                     icon: failed ? "CircleX" : "Pause", secondary: secondary,
                     terminal: background ? nil : failed ? .failed : .interrupted)
    }
    if execution?.status == .running || background {
        return .init(kind: .running, label: execution?.status == .running ? "运行中" : "后台运行中", secondary: secondary)
    }
    if execution?.status == .completed { return .init(kind: .completed, label: "已完成", terminal: .completed) }
    return .init(kind: .idle, label: "等待开始", icon: "CircleDashed")
}

public struct ThreadCardStatus: View {
    public let observation: ThreadPublicObservation
    public let brandKey: String
    public let label: String
    public let emoji: String?
    public let onFollowUp: (() -> Void)?
    @Environment(\.locale) private var locale
    public init(observation: ThreadPublicObservation, brandKey: String, label: String,
                emoji: String? = nil, onFollowUp: (() -> Void)? = nil) {
        self.observation = observation; self.brandKey = brandKey; self.label = label
        self.emoji = emoji; self.onFollowUp = onFollowUp
    }
    public var body: some View {
        let status = threadCardStatus(observation)
        HStack(alignment: .top, spacing: 8) {
            if status.showsState { ThreadCardTaskState(status: status) }
            ThreadCardProviderStatus(label: status.providerLabel(label, locale: locale), brandKey: brandKey, emoji: emoji,
                                     terminal: status.terminal, onFollowUp: onFollowUp)
        }
    }
}

public struct ThreadCardTaskState: View {
    public let status: ThreadCardStatusProjection
    @Environment(\.locale) private var locale
    public init(status: ThreadCardStatusProjection) { self.status = status }
    public var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                if let icon = status.icon { NativeIcon(name: icon, size: 14) }
                Text(cardLocalized(status.label, locale)).font(NativeTypography.inter(size: 12, weight: 650))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tone.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            if let secondary = status.secondary {
                Text(cardLocalized(secondary, locale)).font(NativeTypography.inter(size: 11))
                    .foregroundStyle(NativePalette.overview.muted.swiftUI)
            }
        }
        .foregroundStyle(tone)
        .accessibilityElement(children: .combine)
    }
    private var tone: Color {
        switch status.kind {
        case .attention: NativePalette.pair(0x92580a, 0xedbc70).swiftUI
        case .failed: NativePalette.pair(0xb13c38, 0xf4a39a).swiftUI
        case .interrupted: NativePalette.pair(0x76613e, 0xc9b68f).swiftUI
        default: NativePalette.overview.muted.swiftUI
        }
    }
}

func cardLocalized(_ text: String, _ locale: Locale) -> String {
    NativePluginLocalization.localize(text, locale: locale)
}
