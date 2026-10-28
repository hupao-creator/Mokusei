import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Native counterpart of ThreadExecutionPane. The host supplies its outer
/// 21-point frame, clipping and transition; this view owns the unchanged interior.
@MainActor
public struct ConversationExecutionPane: View {
    private let presentation: ConversationSidecardPresentation
    @Environment(\.locale) private var locale

    public init(presentation: ConversationSidecardPresentation) { self.presentation = presentation }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                Button(action: presentation.context.close) {
                    NativeIcon(name: "X", size: 18)
                }
                .buttonStyle(ExecutionButtonStyle())
                .help(t("收起卡片"))
                .accessibilityLabel(t("收起卡片"))
                .accessibilityIdentifier("conversation-sidecard-close")
            }
            .padding(.top, 8)
            .padding(.horizontal, 12)

            conversation
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NativeAppKitPalette.thread.canvas.swiftUI)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 8)
                .layoutPriority(1)

            VStack(spacing: 0) {
                Rectangle().fill(NativeAppKitPalette.thread.lineSoft.swiftUI).frame(height: 1)
                if let error = presentation.error, !error.isEmpty {
                    Text(t(error))
                        .font(NativeTypography.inter(size: 11))
                        .foregroundStyle(NativeAppKitPalette.thread.danger.swiftUI)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 10)
                        .textSelection(.enabled)
                        .accessibilityLabel("\(t("错误"))：\(error)")
                }
                NativeComposerAttachmentChips(attachments: presentation.attachments.attachments, containerRadius: 12,
                    onRemove: { id in Task { await presentation.attachments.removeAttachment(id) } })
                HStack(alignment: .bottom, spacing: 8) {
                    NativeComposerTextInput(
                        value: Binding(get: { presentation.draft }, set: { presentation.changeDraft($0) }),
                        placeholder: placeholder,
                        disabled: presentation.disabled,
                        readOnly: presentation.submitting,
                        focusEnabled: presentation.context.expanded && !presentation.context.suppressed && !presentation.context.transitioning,
                        automaticFocus: false,
                        focusRequestKey: presentation.focusRequest,
                        focusContext: presentation.context.expanded && !presentation.context.suppressed ? "expanded" : "folded",
                        suppressInitialFocus: true,
                        minHeight: 28, maxHeight: 124, fontSize: 13, lineHeight: 20,
                        insets: NativeComposerInsets(top: 4, left: 0, bottom: 4, right: 0),
                        onSubmit: { Task { await presentation.send() } },
                        onEscape: presentation.context.close,
                        onFiles: presentation.context.attachmentImport == nil ? nil : { files in
                            await presentation.importFiles(files)
                        }, preparePaste: presentation.attachments.preparePaste)
                        .accessibilityLabel(t("输入消息"))
                        .accessibilityIdentifier("conversation-sidecard-input")

                    if presentation.activeExecutionID != nil || presentation.context.thread.pendingInput {
                        Button { Task { await presentation.stop() } } label: {
                            RoundedRectangle(cornerRadius: 1).fill(.foreground).frame(width: 10, height: 10)
                        }
                        .buttonStyle(ExecutionButtonStyle())
                        .disabled(presentation.context.executionDisabled || presentation.stopping)
                        .help(t("停止当前轮"))
                        .accessibilityLabel(t("停止当前轮"))
                        .accessibilityIdentifier("conversation-sidecard-stop")
                    }
                    if presentation.hasDraft {
                        Button { Task { await presentation.send() } } label: {
                            NativeIcon(name: "ArrowUp", size: 16)
                        }
                        .buttonStyle(ExecutionButtonStyle(primary: true))
                        .disabled(!presentation.canSend)
                        .help(t(presentation.running ? "补充到当前轮" : "发送消息"))
                        .accessibilityLabel(t(presentation.running ? "补充到当前轮" : "发送消息"))
                        .accessibilityIdentifier("conversation-sidecard-send")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .frame(minHeight: 54)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("输入与执行卡片"))
        .accessibilityIdentifier("conversation-sidecard")
        .nativeOnExitCommand(perform: presentation.context.close)
    }

    @ViewBuilder
    private var conversation: some View {
        if let executionID = presentation.sidecardExecutionID {
            let readingTarget = presentation.context.readingTarget
            presentation.context.conversation(executionID, readingTarget?.executionID == executionID ? readingTarget : nil)
                .disabled(presentation.context.executionDisabled)
        } else {
            Color.clear
        }
    }

    private func t(_ value: String) -> String { composerLocalized(presentation.context.translate(value), locale: locale) }

    private var placeholder: String {
        if presentation.context.thread.archived == true { return t("此 Thread 已归档") }
        if presentation.waiting { return t("等待回应…") }
        return t(presentation.running ? "补充…" : "输入消息…")
    }
}

private struct ExecutionButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        ExecutionButtonBody(configuration: configuration, primary: primary, enabled: isEnabled)
    }
}

private struct ExecutionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    let enabled: Bool
    @State private var hovering = false
    private var touchPadding: CGFloat {
        0
    }

    var body: some View {
        configuration.label
            .frame(width: 28, height: 28)
            .foregroundStyle(primary ? NativeAppKitPalette.thread.surfaceStrong.swiftUI :
                                hovering && enabled ? NativeAppKitPalette.thread.ink.swiftUI : NativeAppKitPalette.thread.muted.swiftUI)
            .background(background, in: Circle())
            .opacity(enabled ? 1 : 0.4)
            .padding(touchPadding)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var background: Color {
        if primary { return hovering && enabled ? NativeAppKitPalette.thread.inkStrong.swiftUI : NativeAppKitPalette.thread.ink.swiftUI }
        return hovering && enabled ? NativeAppKitPalette.thread.ink.swiftUI.opacity(configuration.isPressed ? 0.12 : 0.07) : .clear
    }
}
