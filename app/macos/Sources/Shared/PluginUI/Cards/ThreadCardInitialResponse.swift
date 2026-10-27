import MokuseiPluginAPI
import SwiftUI

/// A display fact for the first execution, never a persisted execution phase.
public struct ThreadCardInitialResponse: Hashable, Sendable {
    public enum Phase: Hashable, Sendable { case waiting, submitting, running, attention, failed, interrupted, completed, background }
    public let phase: Phase
    public let title: String
    public let detail: String
    public let icon: String?
}

public func threadCardInitialResponse(pendingInput: Bool, observation: ThreadPublicObservation,
                                      hasVisibleInteraction: Bool) -> ThreadCardInitialResponse {
    let background = observation.backgroundWork?.status == .running
    let backgroundDetail = "后台仍在运行"
    switch observation.latestExecution?.status {
    case .running:
        return .init(phase: .running, title: "正在执行", detail: "回复会显示在这里", icon: nil)
    case .waitingForUser:
        let status = threadCardStatus(observation)
        return .init(phase: .attention, title: status.label,
                     detail: hasVisibleInteraction ? "请处理卡片中的请求" : "打开对话查看请求", icon: status.icon)
    case .failed:
        return .init(phase: .failed, title: "执行失败", detail: background ? backgroundDetail : "尚未收到回复，可打开对话查看", icon: "CircleX")
    case .interrupted:
        return .init(phase: .interrupted, title: "已中断", detail: background ? backgroundDetail : "尚未收到回复", icon: "Pause")
    case .completed:
        return .init(phase: .completed, title: "执行已结束", detail: background ? backgroundDetail : "没有可显示的回复", icon: "Check")
    case nil:
        if background { return .init(phase: .background, title: "后台仍在运行", detail: "尚无可显示的回复", icon: nil) }
        return .init(phase: pendingInput ? .submitting : .waiting, title: pendingInput ? "准备开始" : "尚无回复",
                     detail: "回复会显示在这里", icon: pendingInput ? nil : "CircleDashed")
    }
}

struct ThreadCardInitialResponseView: View {
    let value: ThreadCardInitialResponse
    @Environment(\.locale) private var locale
    @Environment(\.threadCardProviderColor) private var providerColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.threadCardCloudAnimationsEnabled) private var enabled
    @Environment(\.threadCardAnimationVisibility) private var visibility
    @State private var startedAt = Date()

    private var pulses: Bool {
        value.phase == .submitting && !reduceMotion && enabled && (visibility?.isVisible ?? true)
    }
    private var title: String {
        if locale.language.languageCode?.identifier != "zh" {
            if value.phase == .failed { return "Execution failed" }
            if value.phase == .background { return "Background work is running" }
        }
        return cardLocalized(value.title, locale)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let icon = value.icon {
                    NativeIcon(name: icon, size: 14)
                        .foregroundStyle(value.phase == .failed ? NativePalette.overview.danger.swiftUI : NativePalette.overview.muted.swiftUI)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: !pulses)) { context in
                        let elapsed = context.date.timeIntervalSince(startedAt)
                        let opacity = pulses ? 0.65 - 0.2 * cos(elapsed * .pi / 1.2) : 0.85
                        Circle().fill(providerColor).frame(width: 6, height: 6).opacity(opacity)
                    }
                }
            }.frame(width: 14, height: 14).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(NativeTypography.inter(size: 12, weight: 550))
                    .foregroundStyle(NativePalette.overview.ink.swiftUI.opacity(0.78)).lineLimit(1)
                Text(cardLocalized(value.detail, locale)).font(NativeTypography.inter(size: 11.5))
                    .foregroundStyle(NativePalette.overview.muted.swiftUI).lineLimit(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ". " + cardLocalized(value.detail, locale))
    }
}

/// Only a mounted initial-state → real-content edge fades in. Remounts and
/// subsequent text revisions use the excerpt's existing scheduling unchanged.
struct ThreadCardBody: View {
    let identity: ThreadCardIdentityView
    let expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.threadCardCloudAnimationsEnabled) private var enabled
    @Environment(\.threadCardAnimationVisibility) private var visibility
    @State private var awaitingContent = false
    @State private var opacity = 1.0

    var body: some View {
        Group {
            if let initial = identity.initialResponse {
                ThreadCardInitialResponseView(value: initial)
            } else {
                ThreadCardExcerpt(content: identity.excerpt, messageId: identity.message?.id, messageText: identity.message?.text)
                    .lineLimit(expanded ? 8 : 5).opacity(opacity)
            }
        }
        .task(id: identity.initialResponse != nil) {
            if identity.initialResponse != nil { awaitingContent = true; opacity = 1; return }
            guard awaitingContent else { return }
            awaitingContent = false
            guard identity.initialResponseContent, !reduceMotion, enabled, visibility?.isVisible != false else { opacity = 1; return }
            opacity = 0
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) { opacity = 1 }
        }
    }
}
