import SwiftUI

private extension EnvironmentValues {
    @Entry var threadDocumentMinimumInset: CGFloat = 0
}

public extension View {
    /// Inset the viewport itself, not its document or just the painted thumb.
    /// The host clips its rounded edge at the document's scroll limits.
    /// By default the top clears Close's 14pt inset + 32pt hit region. A reader
    /// that reserves horizontal space for Close can use a smaller top inset;
    /// overlay readers instead provide a backed Close above their content.
    /// Document owners can opt into matching the fixed chrome at both ends.
    func nativeReadingPanelViewport(topInset: CGFloat = 48, balancedVerticalInsets: Bool = false,
                                    clearsCloseHorizontally: Bool = false) -> some View {
        let side: CGFloat = 8
        let closeEdge = NativeReadingPanelCloseButton.edgeInset + NativeReadingPanelCloseButton.diameter
        return environment(\.threadDocumentMinimumInset, clearsCloseHorizontally ? closeEdge - side : 0)
            .padding(.horizontal, side)
            .padding(.top, topInset)
            .padding(.bottom, balancedVerticalInsets ? topInset : 22)
    }

    /// A panel with a fixed Close control needs the same clearance during loading.
    func nativeThreadDocumentMargins(standard: CGFloat = 0) -> some View {
        modifier(NativeThreadDocumentMargins(standard: standard))
    }
}

private struct NativeThreadDocumentMargins: ViewModifier {
    let standard: CGFloat
    @Environment(\.threadDocumentMinimumInset) private var minimumInset

    func body(content: Content) -> some View {
        content.padding(.horizontal, max(standard, minimumInset))
            .environment(\.threadDocumentMinimumInset, 0)
    }
}
