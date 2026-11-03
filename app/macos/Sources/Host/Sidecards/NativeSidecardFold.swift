import SwiftUI

/// Keep panel chrome available while the document unfolds from the right.
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
        var path = Path(roundedRect: CGRect(x: rect.maxX - width, y: rect.minY,
            width: max(0, width), height: max(0, height)), cornerRadius: 21)
        // 14pt inset + 32pt Close target + 14pt inset. This also contains its
        // focus ring and preserves toolbars whose Close remains on the right.
        path.addRoundedRect(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width,
            height: min(60, rect.height)), cornerSize: CGSize(width: 21, height: 21))
        return path
    }
}
