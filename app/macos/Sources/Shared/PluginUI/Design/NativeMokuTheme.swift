import MokuseiCore
import SwiftUI

/// Moku Map artwork and its deepest interior hue share one identity across the
/// resident orb and expanded surfaces. Unregistered artwork uses neutral glass.
public enum NativeMokuTheme: String, CaseIterable, Sendable {
    case codex, opencode, claude, pi, neutral

    public init(harnessID: JSONText?) {
        self = Self(rawValue: harnessID?.string ?? "") ?? .neutral
    }

    public var harnessID: JSONText { JSONText(rawValue) }

    private var darkest: RGB {
        // Sampled from the reviewed artwork's low-luminance 0.1% interior;
        // transparent pixels and the outer 4% illustrated rim are excluded.
        switch self {
        case .codex: RGB(0.0361, 0.3201, 0.9827)
        case .opencode: RGB(0.1142, 0.1027, 0.1081)
        case .claude: RGB(0.8327, 0.4708, 0.3586)
        case .pi: RGB(0.5316, 0.7075, 0.7966)
        case .neutral: RGB(0.16, 0.18, 0.21)
        }
    }

    private var orbStops: [RGB] {
        switch self {
        case .codex: [RGB(0.06, 0.20, 1), RGB(0.24, 0.43, 1), RGB(0.43, 0.64, 1), RGB(0.80, 0.91, 0.96)]
        case .opencode: [darkest, RGB(0.25, 0.23, 0.24), RGB(0.50, 0.47, 0.48), RGB(0.90, 0.88, 0.89)]
        case .claude: [darkest, RGB(0.88, 0.52, 0.38), RGB(0.94, 0.66, 0.51), RGB(0.99, 0.87, 0.79)]
        case .pi: [RGB(0.88, 0.61, 0.58), darkest, RGB(0.56, 0.74, 0.80), RGB(0.96, 0.90, 0.73)]
        case .neutral: [darkest, RGB(0.32, 0.36, 0.42), RGB(0.51, 0.57, 0.65), RGB(0.82, 0.86, 0.91)]
        }
    }

    private static let deepTints: [Self: RGB] = Dictionary(uniqueKeysWithValues: allCases.map { theme in
        let source = theme.darkest
        // Preserve hue and lower only brightness. Leave headroom for clear-glass
        // sampling over light content and the native composer's 85% placeholder.
        var low = 0.0, high = 1.0
        for _ in 0..<18 {
            let middle = (low + high) / 2
            if source.scaled(middle).luminance <= 0.045 { low = middle } else { high = middle }
        }
        return (theme, source.scaled(low))
    })

    /// The centered Stop mark sits on the bright orb, not its expanded dark tint.
    public var orbControlInk: Color { orbStops[1].luminance > 0.20 ? .black : .white }

    public func gradient(expansion: Double) -> Gradient {
        let progress = min(1, max(0, expansion))
        let target = Self.deepTints[self]!
        return Gradient(stops: zip(orbStops, [0.0, 0.4, 0.72, 1.0]).map { source, location in
            .init(color: RGB(source.r + (target.r - source.r) * progress,
                             source.g + (target.g - source.g) * progress,
                             source.b + (target.b - source.b) * progress).color,
                  location: location)
        })
    }

    private struct RGB: Sendable {
        let r, g, b: Double
        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        var color: Color { Color(red: r, green: g, blue: b) }
        func scaled(_ scale: Double) -> Self { Self(r * scale, g * scale, b * scale) }
        var luminance: Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
    }
}

private struct NativeMokuThemeKey: EnvironmentKey { static let defaultValue = NativeMokuTheme.neutral }
public extension EnvironmentValues {
    var nativeMokuTheme: NativeMokuTheme {
        get { self[NativeMokuThemeKey.self] }
        set { self[NativeMokuThemeKey.self] = newValue }
    }
}
