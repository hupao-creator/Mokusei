import SwiftUI

/// The same Lucide outlines as the Electron UI, drawn by SwiftUI/CoreGraphics.
/// Names accept the original React spelling (`ArrowUp`) or SVG spelling
/// (`arrow-up`). `strokeWidth` is expressed in Lucide's 24-point viewBox units.
public struct NativeIcon: View {
    public let name: String
    public let size: CGFloat
    public let strokeWidth: CGFloat

    public init(name: String, size: CGFloat = 16, strokeWidth: CGFloat = 1.5) {
        self.name = name
        self.size = size
        self.strokeWidth = strokeWidth
    }

    public var body: some View {
        if Self.contains(name) {
            glyph.accessibilityHidden(true)
        } else {
            glyph.accessibilityLabel("Unknown Lucide icon: \(name)")
        }
    }

    private var glyph: some View {
        LucideShape(name: name)
            .stroke(style: StrokeStyle(lineWidth: strokeWidth * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }

    nonisolated public static func contains(_ name: String) -> Bool {
        catalog[normalized(name)] != nil
    }

    private struct Command: Decodable, Sendable {
        let op: String
        let values: [Double]
    }

    nonisolated private static let catalog: [String: [Command]] = {
        let resources = NativeResources.bundle
        guard let url = resources.url(forResource: "lucide-paths", withExtension: "json")
                ?? resources.url(forResource: "lucide-paths", withExtension: "json", subdirectory: "icons") else {
            preconditionFailure("Missing bundled Lucide paths (lucide-paths.json)")
        }
        do {
            return try JSONDecoder().decode([String: [Command]].self, from: Data(contentsOf: url))
        } catch {
            preconditionFailure("Cannot decode bundled Lucide paths: \(error)")
        }
    }()

    nonisolated private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    nonisolated static func path(named name: String, in rect: CGRect) -> Path {
        var result = Path()
        guard let commands = catalog[normalized(name)] else {
            // A visibly missing icon is preferable to silently substituting an
            // unrelated SF Symbol. The accessibility label also identifies it.
            result.addRect(CGRect(x: 3, y: 3, width: 18, height: 18))
            result.move(to: CGPoint(x: 3, y: 3))
            result.addLine(to: CGPoint(x: 21, y: 21))
            result.move(to: CGPoint(x: 3, y: 21))
            result.addLine(to: CGPoint(x: 21, y: 3))
            return result.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
        }
        for command in commands {
            let v = command.values
            switch command.op {
            case "M":
                result.move(to: CGPoint(x: v[0], y: v[1]))
            case "L":
                result.addLine(to: CGPoint(x: v[0], y: v[1]))
            case "C":
                result.addCurve(to: CGPoint(x: v[4], y: v[5]),
                                control1: CGPoint(x: v[0], y: v[1]),
                                control2: CGPoint(x: v[2], y: v[3]))
            case "Q":
                result.addQuadCurve(to: CGPoint(x: v[2], y: v[3]), control: CGPoint(x: v[0], y: v[1]))
            case "Z":
                result.closeSubpath()
            case "E":
                result.addEllipse(in: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
            case "R":
                result.addRoundedRect(in: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]),
                                      cornerSize: CGSize(width: v[4], height: v[5]), style: .circular)
            case "A":
                // SVG endpoint arcs were converted to center/radius/angles at
                // generation time. Draw the ellipse analytically, preserving
                // rotation, sweep direction, and the original 24-unit geometry.
                let rotation = v[4] * .pi / 180
                let transform = CGAffineTransform(a: v[2] * cos(rotation), b: v[2] * sin(rotation),
                                                  c: -v[3] * sin(rotation), d: v[3] * cos(rotation),
                                                  tx: v[0], ty: v[1])
                result.addRelativeArc(center: .zero, radius: 1,
                                      startAngle: .degrees(v[5]), delta: .degrees(v[6]), transform: transform)
            default:
                preconditionFailure("Unsupported bundled Lucide path command: \(command.op)")
            }
        }
        return result.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

private struct LucideShape: Shape {
    let name: String

    func path(in rect: CGRect) -> Path {
        NativeIcon.path(named: name, in: rect)
    }
}
