import MokuseiPluginUI
import SwiftUI

/// Point geometry shared by the SwiftUI capsule and its interaction regions.
/// Coordinates are local to the flipped scene, including a scrolled shell.
enum NativeMokuCapsuleLayout {
    static let idleSize = CGSize(width: 168, height: 44)
    /// Shared by the capsule glass, its clip shape and the nested composer
    /// surfaces (including attachment chips, which derive their concentric
    /// radius from this value).
    static let cornerRadius: CGFloat = 29

    static func frame(in viewport: CGRect, landing: Bool = false) -> CGRect {
        let bottom = landing ? 24 : max(24, min(36, viewport.height * 0.05))
        let width = min(landing ? 680 : 560, max(0, viewport.width - 48))
        return CGRect(x: viewport.midX - width / 2, y: viewport.minY + 24,
                      width: width, height: max(0, viewport.height - bottom - 24))
    }

    static func surface(in frame: CGRect, expanded: Bool, height: CGFloat, centered: Bool = false) -> CGRect {
        let width = expanded ? frame.width : min(idleSize.width, frame.width)
        let height = expanded ? height : idleSize.height
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

/// Reuses the real Moku eyes, including their tilt, proportions and expression.
struct NativeMokuCapsuleEyes: Shape {
    typealias ScalarPair = AnimatablePair<Double, Double>
    typealias EyeData = AnimatablePair<ScalarPair, AnimatablePair<ScalarPair, ScalarPair>>
    private var left: MokuEye
    private var right: MokuEye
    var blink: Double

    // Animate the resolved geometry, including expression changes. Animating
    // only focus replaces the idle expression's size and tilt in a single frame.
    var animatableData: AnimatablePair<EyeData, EyeData> {
        get { .init(Self.data(left), Self.data(right)) }
        set { left = Self.eye(newValue.first); right = Self.eye(newValue.second) }
    }

    init(expression: MokuExpression, focus: Double, blink: Double = 1) {
        let eyes = Self.resolved(expression: expression, focus: focus)
        self.init(left: eyes.left, right: eyes.right, blink: blink)
    }

    init(left: MokuEye, right: MokuEye, blink: Double = 1) {
        self.left = left; self.right = right; self.blink = blink
    }

    static func resolved(expression: MokuExpression, focus: Double) -> (left: MokuEye, right: MokuEye) {
        let idle = MokuGeometry.expressions[expression == .focus ? .idle : expression]!
        let target = MokuGeometry.expressions[.focus]!
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * focus }
        let centerY = mix((idle.left.y + idle.right.y) / 2, (target.left.y + target.right.y) / 2)
        func resolve(_ a: MokuEye, _ b: MokuEye) -> MokuEye {
            MokuEye(x: mix(a.x, b.x), y: mix(a.y, b.y) - centerY,
                    w: mix(a.w, b.w), h: mix(a.h, b.h), radius: mix(a.radius, b.radius),
                    rotation: mix(a.rotation, b.rotation), opacity: 1)
        }
        return (resolve(idle.left, target.left), resolve(idle.right, target.right))
    }

    private static func data(_ eye: MokuEye) -> EyeData {
        .init(.init(eye.x, eye.y), .init(.init(eye.w, eye.h), .init(eye.radius, eye.rotation)))
    }
    private static func eye(_ data: EyeData) -> MokuEye {
        MokuEye(x: data.first.first, y: data.first.second,
                w: data.second.first.first, h: data.second.first.second,
                radius: data.second.second.first, rotation: data.second.second.second, opacity: 1)
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for geometry in [left, right] {
            let scale = 0.22
            let width = geometry.w * scale, height = geometry.h * scale * blink
            let eye = Path(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                           cornerRadius: geometry.radius * scale)
            let transform = CGAffineTransform(rotationAngle: geometry.rotation * .pi / 180)
                .concatenating(CGAffineTransform(translationX: rect.midX + geometry.x * scale,
                                               y: rect.midY + geometry.y * scale))
            path.addPath(eye, transform: transform)
        }
        return path
    }
}

/// The gradient is above the glass sampling layer, below the text. Its stops
/// describe surface density; system refraction still comes from native glass.
struct NativeMokuCapsuleGlass: View {
    var interactive = true
    var strength = 0.85
    /// A local preview override; system Reduce Transparency always takes priority.
    var forceOpaque = false
    @Environment(\.accessibilityReduceTransparency) private var systemOpaque
    @Environment(\.colorScheme) private var colorScheme
    private var opaque: Bool { systemOpaque || forceOpaque }
    private var light: Bool { colorScheme == .light }
    private let shape = RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius)

    var body: some View {
        if opaque {
            shape.fill(light ? Color(red: 0.96, green: 0.95, blue: 0.92) : Color(red: 0.12, green: 0.11, blue: 0.10))
        } else {
            Color.clear
                .glassEffect(interactive ? Glass.clear.interactive() : .clear, in: .rect(cornerRadius: NativeMokuCapsuleLayout.cornerRadius))
                .overlay {
                    shape.fill(LinearGradient(stops: [
                        .init(color: (light ? Color(red: 1, green: 0.99, blue: 0.96) : .black).opacity(0.99 * strength), location: 0),
                        .init(color: (light ? Color(red: 0.98, green: 0.97, blue: 0.94) : Color(red: 0.04, green: 0.035, blue: 0.03)).opacity(0.96 * strength), location: 0.40),
                        .init(color: (light ? Color(red: 0.94, green: 0.91, blue: 0.85) : Color(red: 0.16, green: 0.13, blue: 0.10)).opacity(0.70 * strength), location: 0.72),
                        .init(color: (light ? Color(red: 1, green: 0.97, blue: 0.88) : Color(red: 0.38, green: 0.33, blue: 0.26)).opacity(0.12 * strength), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(stops: [
                        .init(color: .white.opacity((light ? 0.48 : 0.04) * strength), location: 0),
                        .init(color: .white.opacity(0.08 * strength), location: 0.55),
                        .init(color: Color(red: 1, green: 0.92, blue: 0.78).opacity(0.65 * strength), location: 1),
                    ], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
                }
        }
    }
}
