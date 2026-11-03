import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// The built-in execution display participates in the same registry as every
/// other Sidecard. The host has no special knowledge of its identifier.
@MainActor
public struct NativeConversationSidecard: SidecardPlugin {
    public let descriptor = SidecardPluginDescriptor(id: "conversation", displayName: "执行")

    public init() {}
    public var icon: some View { NativeIcon(name: "Activity", size: 17, strokeWidth: 1.8) }

    public func makePresentation(context: SidecardContext, lifetime: PluginLifetime) -> ConversationSidecardPresentation {
        ConversationSidecardPresentation(context: context, lifetime: lifetime)
    }

    public func updatePresentation(_ presentation: ConversationSidecardPresentation, context: SidecardContext) {
        presentation.update(context: context)
    }

    public func sidecard(context: SidecardContext, presentation: ConversationSidecardPresentation) throws -> SidecardView<ConversationExecutionPane> {
        let active = presentation.activeExecutionID
        let waiting = presentation.waiting
        let label = context.translate("执行") + (active == nil ? "" : "，" + context.translate(waiting ? "需要回应" : "运行中"))
        return try SidecardView(available: presentation.sidecardExecutionID != nil, label: JSONText(label),
                               indicator: active == nil ? nil : waiting ? .attention : .active,
                               acceptsInput: false, preferredWidth: 1.0 / 3, focusContentOnOpen: false,
                               excludeExecutionID: presentation.sidecardExecutionID) {
            ConversationExecutionPane(presentation: presentation)
        }
    }
}
