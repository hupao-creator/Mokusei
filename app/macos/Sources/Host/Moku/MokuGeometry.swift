import MokuseiPluginUI
import AppKit

public enum MokuExpression: String, CaseIterable, Sendable { case idle, focus, deliberating, happy, surprised, sleepy, curious }
public enum MokuShape: String, Sendable { case circle, drop, hex, triangle, mark }
public enum MokuLayout: String, Sendable { case mark, message, permission, question }

public struct MokuEye: Equatable, Sendable {
    public var x, y, w, h, radius, rotation, opacity: Double
    public init(x: Double, y: Double, w: Double, h: Double, radius: Double, rotation: Double, opacity: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
        self.radius = radius; self.rotation = rotation; self.opacity = opacity
    }
}

/// Direct numeric port of the production 36-point character, in 640-unit coordinates.
public enum MokuGeometry {
    public static let dockViewport = CGRect(x: -360, y: -720, width: 1360, height: 2080)
    public static func viewport(for layout: MokuLayout) -> CGRect {
        switch layout {
        case .permission: CGRect(x: 20, y: 110, width: 760, height: 380)
        case .question: CGRect(x: 20, y: 50, width: 760, height: 500)
        case .message: CGRect(x: 20, y: 100, width: 780, height: 400)
        case .mark: CGRect(x: 0, y: 0, width: 640, height: 640)
        }
    }
    /// Explicit sRGB components preserve the authored palette on both platforms.
    static func color(red: Double, green: Double, blue: Double, alpha: Double) -> NativePlatformColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
    static func colorComponents(_ color: NativePlatformColor) -> (red: Double, green: Double, blue: Double) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let components = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              components.count >= 3 else { preconditionFailure("Moku palette must contain sRGB colors") }
        return (components[0], components[1], components[2])
    }

    public static let pointCount = 36
    public static let center = CGPoint(x: 320, y: 300)
    public static let bodyColor = MokuGeometry.color(red: 16 / 255, green: 17 / 255, blue: 15 / 255, alpha: 1)
    public static let eyeColor = MokuGeometry.color(red: 247 / 255, green: 245 / 255, blue: 238 / 255, alpha: 1)
    public static let expressions: [MokuExpression: (left: MokuEye, right: MokuEye)] = [
        .idle: (left: MokuEye(x: -43, y: -70, w: 31, h: 78, radius: 16, rotation: -13, opacity: 1), right: MokuEye(x: 43, y: -78, w: 31, h: 78, radius: 16, rotation: -13, opacity: 1)),
        .focus: (left: MokuEye(x: -36, y: -6, w: 31, h: 82, radius: 16, rotation: -5, opacity: 1), right: MokuEye(x: 36, y: 0, w: 31, h: 82, radius: 16, rotation: 6, opacity: 1)),
        .deliberating: (left: MokuEye(x: -29, y: -5, w: 31, h: 78, radius: 16, rotation: -4, opacity: 1), right: MokuEye(x: 29, y: 1, w: 31, h: 78, radius: 16, rotation: 5, opacity: 1)),
        .happy: (left: MokuEye(x: -43, y: 54, w: 45, h: 102, radius: 23, rotation: 14, opacity: 1), right: MokuEye(x: 45, y: 58, w: 38, h: 96, radius: 20, rotation: 14, opacity: 1)),
        .surprised: (left: MokuEye(x: -52, y: 8, w: 62, h: 62, radius: 31, rotation: 0, opacity: 1), right: MokuEye(x: 48, y: -14, w: 76, h: 76, radius: 38, rotation: 0, opacity: 1)),
        .sleepy: (left: MokuEye(x: -48, y: 10, w: 76, h: 19, radius: 10, rotation: 10, opacity: 1), right: MokuEye(x: 48, y: 19, w: 76, h: 19, radius: 10, rotation: 10, opacity: 1)),
        .curious: (left: MokuEye(x: -53, y: 16, w: 60, h: 60, radius: 30, rotation: 0, opacity: 1), right: MokuEye(x: 48, y: -5, w: 78, h: 78, radius: 39, rotation: 0, opacity: 1))
    ]

    public static let messageTrace: [CGPoint] = [
        CGPoint(x: 130.0, y: 258.8),
        CGPoint(x: 138.0, y: 218.0),
        CGPoint(x: 155.8, y: 180.6),
        CGPoint(x: 182.6, y: 149.3),
        CGPoint(x: 215.7, y: 128.5),
        CGPoint(x: 252.7, y: 117.2),
        CGPoint(x: 292.9, y: 116.1),
        CGPoint(x: 332.3, y: 121.7),
        CGPoint(x: 368.9, y: 133.9),
        CGPoint(x: 404.8, y: 147.9),
        CGPoint(x: 442.5, y: 157.4),
        CGPoint(x: 481.8, y: 162.9),
        CGPoint(x: 520.7, y: 169.6),
        CGPoint(x: 558.2, y: 179.8),
        CGPoint(x: 593.5, y: 195.1),
        CGPoint(x: 626.2, y: 216.6),
        CGPoint(x: 653.0, y: 248.0),
        CGPoint(x: 668.5, y: 286.4),
        CGPoint(x: 670.6, y: 327.9),
        CGPoint(x: 660.6, y: 367.9),
        CGPoint(x: 638.4, y: 402.5),
        CGPoint(x: 607.0, y: 427.2),
        CGPoint(x: 572.0, y: 443.3),
        CGPoint(x: 534.7, y: 453.8),
        CGPoint(x: 495.4, y: 459.4),
        CGPoint(x: 455.1, y: 462.8),
        CGPoint(x: 414.3, y: 465.0),
        CGPoint(x: 373.1, y: 463.9),
        CGPoint(x: 332.4, y: 461.7),
        CGPoint(x: 293.1, y: 456.1),
        CGPoint(x: 255.6, y: 446.1),
        CGPoint(x: 220.4, y: 430.4),
        CGPoint(x: 187.9, y: 408.1),
        CGPoint(x: 160.4, y: 377.3),
        CGPoint(x: 141.3, y: 340.6),
        CGPoint(x: 131.2, y: 300.4)
    ]

    public static func buildShape(_ kind: MokuShape, layout: MokuLayout = .mark) -> [CGPoint] {
        if layout == .permission { return permissionShape() }
        if layout == .question { return interactionShape(radiusX: 375, radiusY: 225) }
        if layout == .message { return messageTrace }
        return (0..<pointCount).map { index in
            let theta = -.pi / 2 + Double(index) / Double(pointCount) * .pi * 2
            var x: Double, y: Double
            switch kind {
            case .drop:
                let vertical = sin(theta)
                let width = 154 * (0.78 - vertical * 0.25)
                x = cos(theta) * width
                y = vertical * 174
                if vertical > 0.64 { x *= 1 - (vertical - 0.64) * 2.35 }
                y -= 7
            case .hex:
                let radius = 155 * (1 + 0.065 * cos(6 * theta))
                x = cos(theta) * radius; y = sin(theta) * radius
            case .triangle:
                let radius = 160 * (1 + 0.18 * cos(3 * (theta + .pi / 2)))
                x = cos(theta) * radius * 1.04; y = sin(theta) * radius * 1.03 + 14
            case .mark:
                let cosine = cos(theta), sine = sin(theta)
                let point = rotate(x: sign(cosine) * pow(abs(cosine), 0.54) * 34,
                                   y: sign(sine) * pow(abs(sine), 0.54) * 134 - 34, angle: 0.14)
                x = point.x; y = point.y
            case .circle: x = cos(theta) * 164; y = sin(theta) * 164
            }
            return CGPoint(x: center.x + x, y: center.y + y)
        }
    }

    public static func permissionShape() -> [CGPoint] {
        (0..<pointCount).map { index in
            let theta = -.pi / 2 + Double(index) / Double(pointCount) * .pi * 2
            let cosine = cos(theta), sine = sin(theta)
            return CGPoint(x: 400 + (abs(cosine) < 1e-8 ? 0 : sign(cosine)) * (368 - 42) + cosine * 42,
                           y: 300 + (abs(sine) < 1e-8 ? 0 : sign(sine)) * (176 - 42) + sine * 42)
        }
    }

    public static func interactionShape(radiusX: Double, radiusY: Double) -> [CGPoint] {
        (0..<pointCount).map { index in
            let theta = -.pi / 2 + Double(index) / Double(pointCount) * .pi * 2
            let cosine = cos(theta), sine = sin(theta)
            return CGPoint(x: 400 + sign(cosine) * pow(abs(cosine), 0.52) * radiusX,
                           y: 300 + sign(sine) * pow(abs(sine), 0.52) * radiusY)
        }
    }

    public static func satellite(visible: Bool) -> [CGPoint] {
        (0..<pointCount).map { index in
            let theta = -.pi / 2 + Double(index) / Double(pointCount) * .pi * 2
            let cosine = cos(theta), sine = sin(theta)
            let point = rotate(x: sign(cosine) * pow(abs(cosine), 0.65) * (visible ? 23 : 1),
                               y: sign(sine) * pow(abs(sine), 0.65) * (visible ? 25 : 1), angle: -0.2)
            return CGPoint(x: center.x + point.x + 21, y: center.y + point.y + 176)
        }
    }

    public static func eyes(_ expression: MokuExpression, layout: MokuLayout) -> (left: MokuEye, right: MokuEye) {
        let source = expressions[expression]!
        func transform(_ source: MokuEye) -> MokuEye {
            var eye = source
            if layout == .message {
                eye.x = source.x * 0.713 - 47.5; eye.y = source.y * 0.07 - 89.5
                eye.w *= 0.683; eye.h *= 0.872; eye.radius *= 0.683; eye.rotation *= 0.08
            } else if layout == .permission || layout == .question {
                eye.x = source.x * 0.55 - 190; eye.y = source.y * 0.05 - 108
                eye.w *= 0.58; eye.h *= 0.56; eye.radius *= 0.58; eye.rotation *= 0.06
            }
            return eye
        }
        return (transform(source.left), transform(source.right))
    }

    public static func path(_ points: [CGPoint], tension: Double = 0.82) -> CGPath {
        let result = CGMutablePath()
        guard let first = points.first else { return result }
        // SVG's path sink rounds at two decimal places; preserve that silhouette.
        func rounded(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x * 100).rounded() / 100, y: (p.y * 100).rounded() / 100) }
        result.move(to: rounded(first))
        for index in points.indices {
            let previous = points[(index - 1 + points.count) % points.count]
            let current = points[index], next = points[(index + 1) % points.count]
            let afterNext = points[(index + 2) % points.count]
            result.addCurve(to: rounded(next),
                control1: rounded(CGPoint(x: current.x + (next.x - previous.x) / 6 * tension,
                                          y: current.y + (next.y - previous.y) / 6 * tension)),
                control2: rounded(CGPoint(x: next.x - (afterNext.x - current.x) / 6 * tension,
                                          y: next.y - (afterNext.y - current.y) / 6 * tension)))
        }
        result.closeSubpath()
        return result
    }

    public static func rotate(x: Double, y: Double, angle: Double) -> CGPoint {
        CGPoint(x: x * cos(angle) - y * sin(angle), y: x * sin(angle) + y * cos(angle))
    }
    private static func sign(_ value: Double) -> Double { value == 0 ? 0 : value < 0 ? -1 : 1 }
}
