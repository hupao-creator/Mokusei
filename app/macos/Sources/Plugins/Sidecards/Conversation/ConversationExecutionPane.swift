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
        conversation
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .nativeReadingPanelViewport()
            .nativeReadingPanelClose(label: t("收起卡片"), identifier: "conversation-sidecard-close",
                onClose: presentation.context.close)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(t("执行卡片"))
            .accessibilityIdentifier("conversation-sidecard")
            .nativeReadingExitCommand(perform: presentation.context.suppressed ? nil : presentation.context.close)
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
