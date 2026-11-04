import SwiftUI

public extension View {
    /// Inset the viewport itself, not its document or just the painted thumb.
    /// The host clips its rounded edge at the document's scroll limits.
    /// By default the top clears Close's 14pt inset + 32pt hit region. A reader
    /// that reserves horizontal space for Close can use a smaller top inset;
    /// overlay readers instead provide a backed Close above their content.
    /// Document owners can opt into matching the fixed chrome at both ends.
    func nativeReadingPanelViewport(topInset: CGFloat = 48, balancedVerticalInsets: Bool = false) -> some View {
        padding(.horizontal, 8)
            .padding(.top, topInset)
            .padding(.bottom, balancedVerticalInsets ? topInset : 22)
    }

    /// Top-level loading/error content has no conversation sidebar. Reserve its
    /// host's unconsumed rail so the smaller viewport still clears Close.
    func nativeThreadRailFallback() -> some View { modifier(NativeThreadRailFallback()) }
}

private struct NativeThreadRailFallback: ViewModifier {
    @Environment(\.nativeThreadReservesHistoryRail) private var reservesHistoryRail

    func body(content: Content) -> some View {
        content.padding(.leading, reservesHistoryRail ? 48 : 0)
            .environment(\.nativeThreadReservesHistoryRail, false)
    }
}
