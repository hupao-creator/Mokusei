import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Execution display only. Thread input belongs to the detail Moku bar.
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("执行卡片"))
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
}

private struct ExecutionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        ExecutionButtonBody(configuration: configuration, enabled: isEnabled)
    }
}

private struct ExecutionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let enabled: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .frame(width: 28, height: 28)
            .foregroundStyle(hovering && enabled ? NativeAppKitPalette.thread.ink.swiftUI : NativeAppKitPalette.thread.muted.swiftUI)
            .background(background, in: Circle())
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var background: Color {
        return hovering && enabled ? NativeAppKitPalette.thread.ink.swiftUI.opacity(configuration.isPressed ? 0.12 : 0.07) : .clear
    }
}
