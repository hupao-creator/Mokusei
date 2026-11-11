import SwiftUI

/// Shared stationary-ink reveal. Hosts own timing and layer outgoing ink above
/// incoming ink; the 240%-wide mask travels from x=0 to x=-140% of its viewport.
/// The built-in offset interpolates the translation without reevaluating this
/// gradient/geometry view for every intermediate progress value.
public struct ThreadCardInkMask: View {
    public var progress: CGFloat
    public let outgoing: Bool

    public init(progress: CGFloat, outgoing: Bool) {
        self.progress = progress; self.outgoing = outgoing
    }

    public var body: some View {
        GeometryReader { geometry in
            LinearGradient(stops: outgoing ? [
                .init(color: .white, location: 0.45),
                .init(color: .white.opacity(0.36), location: 0.53),
                .init(color: .white.opacity(0.20), location: 0.56),
                .init(color: .clear, location: 0.58),
            ] : [
                .init(color: .clear, location: 0.45),
                .init(color: .white, location: 0.55),
            ], startPoint: .leading, endPoint: .trailing)
                .frame(width: geometry.size.width * 2.4, height: geometry.size.height)
                .offset(x: -geometry.size.width * 1.4 * progress)
        }
    }
}
