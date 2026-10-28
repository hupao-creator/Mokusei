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

    static func frame(in viewport: CGRect) -> CGRect {
        let bottom = max(24, min(36, viewport.height * 0.05))
        let width = min(560, max(0, viewport.width - 48))
        return CGRect(x: viewport.midX - width / 2, y: viewport.minY + 24,
                      width: width, height: max(0, viewport.height - bottom - 24))
    }

    static func surface(in frame: CGRect, expanded: Bool, height: CGFloat) -> CGRect {
        let width = expanded ? frame.width : min(idleSize.width, frame.width)
        let height = expanded ? height : idleSize.height
        return CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
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

struct NativeMokuCapsuleGlass: View {
    var interactive = true
    var usesThemeTint = false
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        (usesThemeTint && colorScheme == .light ? MokuGeometry.eyeColor : MokuGeometry.bodyColor).swiftUI
    }

    var body: some View {
        if opaque {
            RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius).fill(tint)
        } else {
            let glass = Glass.regular
            Color.clear.glassEffect(interactive ? glass.interactive() : glass, in: .rect(cornerRadius: NativeMokuCapsuleLayout.cornerRadius))
        }
    }
}
