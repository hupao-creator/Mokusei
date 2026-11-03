import SwiftUI

/// Unfold the card from the right; its external launcher remains the toggle.
/// Interpolating the modifier rebuilds both paint and hit apertures at each
/// presentation step; a drawing mask alone leaves hidden controls clickable.
struct NativeSidecardFold: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }

    func body(content: Content) -> some View {
        let aperture = NativeSidecardFoldAperture(progress: progress)
        content.mask(aperture).contentShape(.interaction, aperture)
    }
}

private struct NativeSidecardFoldAperture: Shape {
    let progress: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = 32 + (rect.width - 32) * progress
        let height = 30 + (rect.height - 30) * progress
        return Path(roundedRect: CGRect(x: rect.maxX - width, y: rect.minY,
            width: max(0, width), height: max(0, height)), cornerRadius: 21)
    }
}
