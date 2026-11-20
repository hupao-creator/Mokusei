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
                                    clearsCloseHorizontally: Bool = false, minimumBottomInset: CGFloat = 0) -> some View {
        let side: CGFloat = 8
        let closeEdge = NativeReadingPanelCloseButton.edgeInset + NativeReadingPanelCloseButton.diameter
        return environment(\.threadDocumentMinimumInset, clearsCloseHorizontally ? closeEdge - side : 0)
            .padding(.horizontal, side)
            .padding(.top, topInset)
            .padding(.bottom, max(balancedVerticalInsets ? topInset : 22, minimumBottomInset))
    }

    /// The main timeline supplies its viewport width before SwiftUI allocates a scroller.
    func nativeThreadDocumentMargins(standard: CGFloat = 0, viewportWidth: CGFloat? = nil) -> some View {
        modifier(NativeThreadDocumentMargins(standard: standard, viewportWidth: viewportWidth))
    }
}

private struct NativeThreadDocumentMargins: ViewModifier {
    let standard: CGFloat
    let viewportWidth: CGFloat?
    @Environment(\.threadDocumentMinimumInset) private var minimumInset

    func body(content: Content) -> some View {
        let document = content.environment(\.threadDocumentMinimumInset, 0)
        let inset = max(standard, minimumInset)
        if minimumInset > 0, let viewportWidth {
            let width = min(NativeGeometry.readingWidth, max(0, viewportWidth - 2 * inset))
            // A persistent scroller uses part of the trailing margin. Anchor the
            // column to the full viewport so its appearance cannot rewrap a reply.
            document.frame(width: width, alignment: .leading)
                .padding(.leading, (viewportWidth - width) / 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            document.padding(.horizontal, inset)
        }
    }
}
