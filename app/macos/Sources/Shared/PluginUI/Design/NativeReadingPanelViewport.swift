import SwiftUI

public extension View {
    /// Inset the viewport itself, not its document or just the painted thumb.
    /// Both ends clear the 22pt rounded edge at the document's scroll limits.
    /// By default the top clears Close's 14pt inset + 32pt hit region. A reader
    /// that reserves horizontal space for Close can use a smaller top inset;
    /// its document and scrollers must remain outside the control's hit region.
    /// Document owners can opt into matching the fixed chrome at both ends.
    func nativeReadingPanelViewport(topInset: CGFloat = 48, balancedVerticalInsets: Bool = false) -> some View {
        padding(.horizontal, 8)
            .padding(.top, topInset)
            .padding(.bottom, balancedVerticalInsets ? topInset : 22)
    }
}
