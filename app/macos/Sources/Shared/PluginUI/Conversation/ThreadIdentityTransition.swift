import SwiftUI

// Opt-in presentation scope for the native transition fixture. Ordinary readers
// and cards keep their own layout and never participate in shared geometry.
struct ThreadIdentityTransition {
    let namespace: Namespace.ID
    let id: String
    let expanded: Bool
}
extension EnvironmentValues {
    @Entry var threadIdentityTransition: ThreadIdentityTransition? = nil
}
extension View {
    func threadIdentityElement(_ element: String, detail: Bool, text: String = "") -> some View {
        modifier(ThreadIdentityElement(element: element, detail: detail))
            .modifier(ThreadIdentityBridgeModifier(element: element, detail: detail, text: text))
    }
}
private struct ThreadIdentityElement: ViewModifier {
    @Environment(\.threadIdentityTransition) private var transition
    let element: String
    let detail: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if let transition {
            content
                .scaleEffect(detail && !transition.expanded ? (element == "emoji" ? 21.0 / 44 : 15.0 / 40) : 1,
                             anchor: .topLeading)
                .matchedGeometryEffect(id: transition.id + "." + element,
                    in: transition.namespace, properties: .position, anchor: .topLeading,
                    isSource: detail == transition.expanded)
        } else { content }
    }
}
