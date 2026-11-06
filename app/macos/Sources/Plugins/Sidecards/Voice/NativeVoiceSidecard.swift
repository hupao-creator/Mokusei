import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// The scoped read-only discussion plugin. It never routes text to context.send
/// or to the source Thread's execution actions.
@MainActor
public struct NativeVoiceSidecard: SidecardPlugin {
    public let descriptor = SidecardPluginDescriptor(id: "voice", displayName: "历史语音记录")
    public init() {}
    public var icon: some View { NativeIcon(name: "MessageSquare", size: 18, strokeWidth: 1.7) }
    public func makePresentation(context: SidecardContext, lifetime: PluginLifetime) -> VoiceSidecardPresentation {
        VoiceSidecardPresentation(context: context, lifetime: lifetime)
    }
    public func updatePresentation(_ presentation: VoiceSidecardPresentation, context: SidecardContext) {
        presentation.update(context: context)
    }
    public func sidecard(context: SidecardContext, presentation: VoiceSidecardPresentation) throws -> SidecardView<VoiceSidecardContent> {
        try SidecardView(available: !presentation.state.messages.isEmpty || !presentation.error.isEmpty,
                        label: JSONText(context.translate("历史语音记录")),
                        indicator: !presentation.error.isEmpty ? .attention : nil,
                        preferredWidth: 0.36) {
            VoiceSidecardContent(presentation: presentation)
        }
    }
}
