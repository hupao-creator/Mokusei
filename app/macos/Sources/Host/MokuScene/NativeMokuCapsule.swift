import MokuseiPluginUI
import SwiftUI

/// Point geometry shared by the SwiftUI capsule and its interaction regions.
/// Coordinates are local to the flipped scene, including a scrolled shell.
enum NativeMokuCapsuleLayout {
    static let idleSize = CGSize(width: 64, height: 64)
    static let controlRowHeight: CGFloat = 44
    static let landingScale: CGFloat = 76.0 / 58.0
    /// Shared by the capsule glass, its clip shape and the nested composer
    /// surfaces (including attachment chips, which derive their concentric
    /// radius from this value).
    static let cornerRadius: CGFloat = 29

    static func frame(in viewport: CGRect, landing: Bool = false, reading: Bool = false) -> CGRect {
        let restingBottom = landing ? 24 : max(24, min(36, viewport.height * 0.05))
        // Reading gives the expanding composer a lower seat. Keep a physical
        // margin even in compact/zoomed windows; never translate outside the fit.
        let bottom = reading && !landing ? max(12, restingBottom - 16) : restingBottom
        let width = min(landing ? 680 : 560, max(0, viewport.width - 48))
        return CGRect(x: viewport.midX - width / 2, y: viewport.minY + 24,
                      width: width, height: max(0, viewport.height - bottom - 24))
    }

    static func surface(in frame: CGRect, expanded: Bool, height: CGFloat, centered: Bool = false) -> CGRect {
        let width = expanded ? frame.width : min(idleSize.width, frame.width)
        let height = min(max(0, expanded ? height : idleSize.height), frame.height)
        return CGRect(x: frame.midX - width / 2, y: centered ? frame.midY - height / 2 : frame.maxY - height,
                      width: width, height: height)
    }

    static func idleSurface(in viewport: CGRect) -> CGRect {
        surface(in: frame(in: viewport), expanded: false, height: idleSize.height)
    }

    static func panel(in viewport: CGRect, above surface: CGRect, question: Bool) -> CGRect {
        let width = min(question ? 760 : 480, max(0, viewport.width - 48))
        let height = min(question ? 440 : 280, max(0, surface.minY - viewport.minY - 42))
        return CGRect(x: viewport.midX - width / 2, y: surface.minY - 18 - height, width: width, height: height)
    }
}

/// The actual Harness logo occupies this seat only in Agent Thread detail.
enum NativeMokuIdentityLayout {
    static let seat = CGSize(width: 34, height: 25)
}

/// The orb and expanded forms retain one native glass node. The circular artwork
/// retires into a full-shape tint before widening can stretch its rim into an oval.
struct NativeMokuCapsuleGlass: View, @MainActor Animatable {
    var interactive: Bool
    var expansion: Double
    var forceOpaque: Bool
    @Environment(\.nativeMokuTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var systemOpaque
    private var opaque: Bool { systemOpaque || forceOpaque }
    var animatableData: Double {
        get { expansion }
        set { expansion = newValue }
    }
    init(interactive: Bool = true, expanded: Bool = true, forceOpaque: Bool = false) {
        self.interactive = interactive; self.expansion = expanded ? 1 : 0
        self.forceOpaque = forceOpaque
    }
    private var progress: Double { min(1, max(0, expansion)) }
    private var radius: CGFloat { 32 - 3 * progress }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius) }
    var body: some View {
        ZStack {
            shape.fill(LinearGradient(gradient: theme.gradient(expansion: progress), startPoint: .top, endPoint: .bottom))
            NativeMokuMapLogoArtwork.image(for: theme.harnessID)?
                .resizable().interpolation(.high)
                .opacity(max(0, 1 - progress * 8))
        }
        .clipShape(shape)
        .mask {
            LinearGradient(stops: [
                .init(color: .white.opacity(opaque ? 1 : 0.94), location: 0),
                .init(color: .white.opacity(opaque ? 1 : 0.94), location: 0.8),
                .init(color: .white.opacity(opaque ? 1 : 0.80 + 0.14 * progress), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .glassEffect(opaque ? .identity : interactive ? Glass.clear.interactive() : .clear,
                     in: .rect(cornerRadius: radius))
        .overlay {
            shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.8)
                .opacity(opaque ? 0 : progress)
        }
        .environment(\.colorScheme, .dark)
    }
}
