import SwiftUI

public extension EnvironmentValues {
    /// Resolution tier for text inside a transformed overview plane. Layout
    /// remains in world points; only the glyphs are prepared at a larger size.
    @Entry var threadCardTextRasterScale: CGFloat = 1
}

extension EnvironmentValues {
    /// A local policy input for native replays; ordinary hosts leave it nil and
    /// the title/excerpt leaves continue reading the system accessibility value.
    @Entry var threadCardTextReduceMotionOverride: Bool? = nil
}

extension View {
    func cardFont(size: CGFloat, weight: CGFloat = 400, monospaced: Bool = false,
                  lineSpacing: CGFloat = 0) -> some View {
        modifier(CardFont(size: size, weight: weight, monospaced: monospaced, spacing: lineSpacing))
    }
}

private struct CardFont: ViewModifier {
    let size: CGFloat
    let weight: CGFloat
    let monospaced: Bool
    let spacing: CGFloat
    @Environment(\.threadCardTextRasterScale) private var resolution

    func body(content: Content) -> some View {
        let scale = resolution.isFinite ? min(32, max(1, resolution)) : 1
        CardTextLayout(scale: scale) {
            content
                .font(monospaced ? .system(size: size * scale, weight: .regular, design: .monospaced)
                    : NativeTypography.inter(size: size * scale, weight: weight))
                .lineSpacing(spacing * scale)
                .scaleEffect(1 / scale, anchor: .topLeading)
        }
        // Resolution tiers change atomically; the outer camera owns motion.
        .animation(nil, value: scale)
    }
}

/// Give Text its scaled wrapping width, then return the original layout size
/// and baseline. The inverse transform cancels the camera's magnification
/// without changing card geometry, hit targets or line limits.
private struct CardTextLayout: Layout {
    let scale: CGFloat
    private func proposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        .init(width: proposal.width.map { $0 * scale }, height: proposal.height.map { $0 * scale })
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let size = text.sizeThatFits(self.proposal(proposal))
        return .init(width: size.width / scale, height: size.height / scale)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: self.proposal(.init(bounds.size)))
    }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard let text = subviews.first else { return nil }
        return text.dimensions(in: self.proposal(.init(bounds.size)))[guide] / scale
    }
}
