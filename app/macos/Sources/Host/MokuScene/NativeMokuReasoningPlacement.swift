import AppKit

/// Fit the full glyph envelope, not only its circular baseline. Normal windows
/// only lift the capsule; constrained viewports scale the complete group so its
/// proportions and open-arc angle survive without clipping or repacking cards.
struct NativeMokuReasoningPlacement: Equatable {
    var surface: CGRect
    var scale: CGFloat = 1
    var decorationPadding: CGFloat = 32

    @MainActor static func fit(surface: CGRect, arcBody: CGRect? = nil, viewport: CGRect,
                              glyphs: [MokuReasoningGlyph], preferredScale: CGFloat = 1) -> Self {
        guard viewport.width > 0, viewport.height > 0 else { return .init(surface: surface) }
        let arcBody = arcBody ?? surface
        let track = NativeMokuReasoningArcTrack(body: arcBody)
        let arcInk = track.inkBounds(for: glyphs)
        let ink = arcInk.union(surface)
        let available = viewport.insetBy(dx: min(4, viewport.width / 4), dy: min(4, viewport.height / 4))
        let scale = min(preferredScale, available.width / max(1, ink.width), available.height / max(1, ink.height))
        let left = (ink.minX - surface.midX) * scale, right = (ink.maxX - surface.midX) * scale
        let top = (ink.minY - surface.midY) * scale, bottom = (ink.maxY - surface.midY) * scale
        let x = min(max(surface.midX, available.minX - left), available.maxX - right)
        let y = min(max(surface.midY, available.minY - top), available.maxY - bottom)
        return .init(surface: CGRect(x: x - surface.width * scale / 2, y: y - surface.height * scale / 2,
                                    width: surface.width * scale, height: surface.height * scale),
                     scale: scale, decorationPadding: max(32, arcBody.minX - arcInk.minX, arcInk.maxX - arcBody.maxX,
                                                          arcBody.minY - arcInk.minY, arcInk.maxY - arcBody.maxY))
    }
}
