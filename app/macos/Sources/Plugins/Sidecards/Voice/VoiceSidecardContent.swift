import AppKit
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

@MainActor
public struct VoiceSidecardContent: View {
    @Bindable private var presentation: VoiceSidecardPresentation
    @State private var lastAnnouncedError: String?
    public init(presentation: VoiceSidecardPresentation) { self.presentation = presentation }

    public var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height <= 460
            VStack(spacing: 0) {
                header(compact: compact)
                conversation(compact: compact)
                    .background(VoicePalette.paper.swiftUI)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 8)
                footer(compact: compact)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(NativePalette.thread.ink.swiftUI)
            .font(NativeTypography.inter(size: 13))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.translate("语音讨论"))
        .tint(VoicePalette.blue.swiftUI)
        .opacity(presentation.context.suppressed ? 0 : 1)
        .allowsHitTesting(presentation.context.expanded && !presentation.context.suppressed)
        .onChange(of: presentation.lastCompletedAnnouncement) { _, text in
            guard !text.isEmpty, presentation.context.expanded, !presentation.context.suppressed else { return }
            AccessibilityNotification.Announcement(text).post()
        }
        .onChange(of: presentation.error) { _, text in
            if text.isEmpty { lastAnnouncedError = nil }
            announceErrorIfVisible()
        }
        .onAppear { announceErrorIfVisible() }
        .onChange(of: canAnnounce) { _, visible in if visible { announceErrorIfVisible() } }
        .onChange(of: presentation.status) { _, text in
            guard presentation.context.expanded, !presentation.context.suppressed else { return }
            AccessibilityNotification.Announcement(text).post()
        }
    }

    private var canAnnounce: Bool { presentation.context.expanded && !presentation.context.suppressed }
    private func announceErrorIfVisible() {
        let text = presentation.error
        guard canAnnounce, !text.isEmpty, text != lastAnnouncedError else { return }
        lastAnnouncedError = text
        AccessibilityNotification.Announcement(text).post()
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 11) {
            NativeIcon(name: "AudioLines", size: 19, strokeWidth: 1.8)
                .frame(width: 36, height: 36)
                .background(VoicePalette.avatar.swiftUI, in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.translate("语音讨论"))
                    .font(NativeTypography.inter(size: 14, weight: 650)).tracking(-0.28)
                Text(presentation.context.thread.title.string)
                    .font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.thread.muted.swiftUI)
                    .lineLimit(1).truncationMode(.tail).help(presentation.context.thread.title.string)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: presentation.close) { NativeIcon(name: "X", size: 18).frame(width: 30, height: 30) }
                .buttonStyle(VoiceButtonStyle(kind: .close))
                .accessibilityLabel(presentation.translate("收起卡片")).help(presentation.translate("收起卡片"))
        }
        .padding(.horizontal, 18).padding(.top, compact ? 10 : 18).padding(.bottom, compact ? 11 : 16)
        .overlay(alignment: .bottom) { Rectangle().fill(NativePalette.thread.lineSoft.swiftUI).frame(height: 1) }
    }

    private func conversation(compact: Bool) -> some View {
        GeometryReader { geometry in
            let messages = presentation.state.messages
            NativeScrollView(.vertical) {
                VStack(spacing: 0) {
                    if messages.isEmpty {
                        emptyState(compact: compact)
                            .frame(minHeight: max(compact ? 150 : 260, geometry.size.height - 28))
                    } else {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            let previous = index > 0 ? messages[index - 1] : nil
                            let next = index + 1 < messages.count ? messages[index + 1] : nil
                            let newCall = previous?.sessionID != message.sessionID
                            if newCall { callTime(message.createdAt) }
                            VoiceMessageBubble(message: message,
                                tail: next == nil || next?.role != message.role || next?.sessionID != message.sessionID,
                                maximumWidth: max(36, (geometry.size.width - 40) * 0.85),
                                label: "\(presentation.translate(message.role == .user ? "你" : "助手")): \(message.text.codeUnits.isEmpty ? presentation.translate("正在转写") : message.text.string)")
                                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                                .padding(.top, !newCall && previous?.role == message.role ? 4 : 10)
                        }
                    }
                }
                .padding(.top, 4).padding(.horizontal, 20).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollPosition($presentation.scrollPosition)
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: VoiceScrollMetrics.self) { geometry in
                VoiceScrollMetrics(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                                   viewportHeight: geometry.containerSize.height)
            } action: { previous, next in
                // Content growth alone must not turn a pinned reader into an
                // away reader before the new bottom position is applied.
                if abs(previous.offset - next.offset) > 0.1 {
                    presentation.didScroll(offset: next.offset, contentHeight: next.contentHeight, viewportHeight: next.viewportHeight)
                }
                if previous.contentHeight != next.contentHeight || previous.viewportHeight != next.viewportHeight {
                    presentation.contentSizeChanged()
                }
            }
            .focusable()
            .accessibilityLabel(presentation.translate("语音对话记录"))
            .overlay(alignment: .bottom) {
                if presentation.away {
                    Button(action: presentation.scrollToLatest) {
                        HStack(spacing: 6) {
                            NativeIcon(name: "ArrowDown", size: 13)
                            Text(presentation.translate(presentation.newMessages ? "新消息" : "回到最新"))
                        }.font(NativeTypography.inter(size: 11)).padding(.horizontal, 12).padding(.vertical, 7)
                    }.buttonStyle(VoiceButtonStyle(kind: .jump))
                        .padding(.bottom, 12)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func emptyState(compact: Bool) -> some View {
        VStack(spacing: 0) {
            NativeIcon(name: "AudioLines", size: 36, strokeWidth: 1.2)
                .foregroundStyle(VoicePalette.blue.swiftUI)
                .padding(.bottom, compact ? 10 : 18).accessibilityHidden(true)
            Text(emptyTitle)
                .font(NativeTypography.inter(size: 17, weight: 550)).tracking(-0.34)
            Text(presentation.translate(presentation.active ? "双方的语音会实时显示在这里。" : "带着当前对话的上下文，开始只读讨论。"))
                .font(NativeTypography.inter(size: 12)).modifier(VoiceLineHeight(size: 12, height: 20.4))
                .foregroundStyle(NativePalette.thread.muted.swiftUI)
                .multilineTextAlignment(.center).frame(maxWidth: 230).padding(.top, 10)
        }
        .padding(.vertical, compact ? 16 : 28).padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
    }
    private var emptyTitle: String {
        if presentation.state.loading { return presentation.translate("正在读取语音记录…") }
        if presentation.state.phase == .listening { return presentation.translate("可以开始说话了") }
        return presentation.active ? presentation.status : presentation.translate("聊聊这个任务")
    }
    private func callTime(_ timestamp: Double) -> some View {
        VStack(spacing: 4) {
            Text(VoiceTimestamp.string(timestamp)).font(NativeTypography.inter(size: 10, weight: 550)).frame(minHeight: 14)
            Text(presentation.translate("语音讨论")).font(NativeTypography.inter(size: 10)).frame(minHeight: 14).opacity(0.7)
        }
        .foregroundStyle(NativePalette.thread.muted.swiftUI)
        .frame(maxWidth: .infinity)
        .padding(.top, 24).padding(.bottom, 18)
    }

    private func footer(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if !presentation.error.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text(presentation.error).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button { Task { await presentation.refresh() } } label: { Text(presentation.translate("重试")).underline() }
                        .buttonStyle(.plain)
                }
                .font(NativeTypography.inter(size: 11)).modifier(VoiceLineHeight(size: 11, height: 17.6))
                .foregroundStyle(NativePalette.thread.danger.swiftUI)
                .padding(.bottom, 12)
                .accessibilityLabel(presentation.error)
            }
            HStack(spacing: 7) {
                VoiceStatusDot(live: presentation.state.phase == .listening && !presentation.state.muted)
                Text(presentation.status)
            }
            .font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.thread.muted.swiftUI)
            .frame(maxWidth: .infinity, minHeight: 16).padding(.bottom, 13)
            .accessibilityElement(children: .combine)
            if presentation.active || presentation.state.phase == .stopping {
                HStack(spacing: 10) {
                    Button(action: presentation.toggleMute) {
                        HStack(spacing: 8) {
                            NativeIcon(name: presentation.state.muted ? "MicOff" : "Mic", size: 18)
                            Text(presentation.translate(presentation.state.muted ? "取消静音" : "静音"))
                        }.font(NativeTypography.inter(size: 12)).frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(VoiceButtonStyle(kind: presentation.state.muted ? .muted : .mute))
                    .disabled(presentation.state.phase != .listening)
                    .accessibilityLabel(presentation.translate(presentation.state.muted ? "取消静音" : "静音麦克风"))
                    .accessibilityAddTraits(presentation.state.muted ? .isSelected : [])
                    Button { Task { await presentation.stop() } } label: {
                        HStack(spacing: 8) {
                            NativeIcon(name: "PhoneOff", size: 18)
                            Text(presentation.translate("结束通话"))
                        }.font(NativeTypography.inter(size: 12)).frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(VoiceButtonStyle(kind: .end)).disabled(presentation.state.phase == .stopping)
                }
            } else {
                Button { Task { await presentation.start() } } label: {
                    HStack(spacing: 8) {
                        NativeIcon(name: "Mic", size: 17)
                        Text(presentation.translate("开始语音"))
                    }.font(NativeTypography.inter(size: 13, weight: 550)).frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(VoiceButtonStyle(kind: .start))
                .disabled(!presentation.state.available || presentation.state.loading || !presentation.context.expanded)
            }
            Text(presentation.translate(presentation.active ? "收起卡片即结束通话" : "每次开始使用当前任务的最新上下文"))
                .font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.thread.muted.swiftUI)
                .modifier(VoiceLineHeight(size: 10, height: 15)).multilineTextAlignment(.center).padding(.top, 10)
        }
        .padding(.horizontal, 20).padding(.top, compact ? 11 : 15).padding(.bottom, compact ? 10 : 16)
        .overlay(alignment: .top) { Rectangle().fill(NativePalette.thread.lineSoft.swiftUI).frame(height: 1) }
    }
}

private struct VoiceScrollMetrics: Equatable {
    let offset: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
}
private enum VoiceTimestamp {
    static func string(_ milliseconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
}
