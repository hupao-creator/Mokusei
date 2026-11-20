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

    /// Top-level status views can precede the timeline that normally sets the margins.
    func nativeThreadRailFallback() -> some View { nativeThreadDocumentMargins(standard: 0) }
}

extension View {
    func nativeThreadDocumentMargins(standard: CGFloat) -> some View {
        modifier(NativeThreadDocumentMargins(standard: standard))
    }
}

private struct NativeThreadDocumentMargins: ViewModifier {
    let standard: CGFloat
    @Environment(\.nativeThreadReservesHistoryRail) private var reservesHistoryRail

    func body(content: Content) -> some View {
        // Leave the hit targets in the margin, including when a second turn
        // arrives. The scroll view and its indicator keep the full viewport.
        content.padding(.horizontal, reservesHistoryRail ? ThreadHistorySidebar.documentMargin : standard)
            .environment(\.nativeThreadReservesHistoryRail, false)
    }
}
