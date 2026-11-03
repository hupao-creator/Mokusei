import SwiftUI

public extension View {
    /// Inset the viewport itself, not its document or just the painted thumb.
    /// Both ends clear the 22pt rounded edge at the document's scroll limits.
    /// The top also clears the Close button's 14pt inset + 32pt hit region,
    /// so an expanded overlay scroller cannot compete with that control.
    func nativeReadingPanelViewport() -> some View {
        padding(.horizontal, 8)
            .padding(.top, 48)
            .padding(.bottom, 22)
    }
}
