import SwiftUI

/// Original renderer colors, kept separate because the three surfaces intentionally
/// use different accent families. Dynamic NativeColors follow the window's appearance.
public enum NativePalette {
    private static let paletteBundle: Bundle = {
        guard let url = NativeResources.bundle.url(forResource: "PaletteResources-\(NativeResources.platform)", withExtension: "bundle"),
              let bundle = Bundle(url: url) else { preconditionFailure("Missing compiled SwiftUI palette") }
        return bundle
    }()
    public static let overview = Surface(
        canvas: pair(0xf8f7f4, 0x20211f), surface: pair(0xfffefa, 0x262724),
        surfaceStrong: pair(0xffffff, 0x2c2d29), surfaceSoft: pair(0xf8f6ef, 0x292b26),
        ink: pair(0x20211e, 0xeeeee9), inkStrong: pair(0x20211e, 0xeeeee9),
        muted: pair(0x777871, 0xb1b2aa), faint: pair(0xa5a69f, 0x96988f),
        line: pair(0xdfddd6, 0x4b4d44), lineSoft: pair(0xeae8e2, 0x383a33),
        accent: pair(0x19725f, 0x78cdb3), accentSoft: pair(0xe3f0eb, 0x283e35),
        action: pair(0xad6a12, 0xedb562), provider: pair(0x666861, 0xb7b9b2),
        danger: pair(0xb4493f, 0xf0988d), warning: pair(0x9a6d23, 0xe6bd78),
        success: pair(0x287d54, 0x68bd8c), agentRun: pair(0x6d28d9, 0xc4b5fd))

    public static let thread = Surface(
        canvas: pair(0xffffff, 0x191919), surface: pair(0xf6f5f4, 0x202020),
        surfaceStrong: pair(0xffffff, 0x252525), surfaceSoft: pair(0xfafaf9, 0x202020),
        ink: pair(0x37352f, 0xd4d3cf), inkStrong: pair(0x1a1a1a, 0xeeeeec),
        muted: pair(0x787671, 0xa19e98), faint: pair(0x98958e, 0x96928c),
        line: pair(0xe5e3df, 0x383735), lineSoft: pair(0xeeedeb, 0x2d2c2a),
        accent: pair(0x5645d4, 0xb5a7ff), accentSoft: pair(0xeeebfb, 0x302a46),
        action: pair(0x5645d4, 0xb5a7ff), provider: pair(0x5645d4, 0xb5a7ff),
        danger: pair(0xb44841, 0xe69a92), warning: pair(0x986b32, 0xd4ac76),
        success: pair(0x47785b, 0x8aba9b), agentRun: pair(0x6d28d9, 0xc4b5fd))

    public static let settings = Settings()

    public struct Surface: Sendable {
        public let canvas, surface, surfaceStrong, surfaceSoft: NativeColor
        public let ink, inkStrong, muted, faint, line, lineSoft: NativeColor
        public let accent, accentSoft, action, provider, danger, warning, success, agentRun: NativeColor
    }

    public struct Settings: Sendable {
        public let text = pair(0x282a2e, 0xe2e6eb)
        public let muted = pair(0x72747a, 0xadb5c0)
        public let accent = pair(0x426b9a, 0x8ebbea)
        public let sidebar = pair(0xe5eaf1, 0x24292f)
        public let main = pair(0xfafafb, 0x1e2227)
        public let line = pair(0x232830, 0xe0e5da, alpha: 0.09)
        public let inputBorder = pair(0x232830, 0xe0e5da, alpha: 0.14)
        public let input = pair(0xffffff, 0x2c2f33, alpha: 0.85)
        public let tab = pair(0x555f6d, 0xb6bfcb)
        public let selectedTab = pair(0x26384e, 0xe0e7f0)
        public let selectedTabFill = pair(0xffffff, 0x2c2f33, alpha: 0.82)
        public let hintSurface = pair(0xffffff, 0x2c2d29)
        public let hintBorder = pair(0xdfe3e9, 0x48515e)
        public let danger = pair(0xb84943, 0xf0988d)
    }

    public static func color(_ hex: UInt32, alpha: Double = 1) -> NativeColor {
        NativeColor(swiftUI: Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
            green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: alpha))
    }
    /// Adaptive pairs are declared in Resources/Palette.xcassets; the build plugin checks literal call sites.
    public static func pair(_ light: UInt32, _ dark: UInt32, alpha: Double = 1) -> NativeColor {
        return NativeColor(swiftUI: Color("palette-\(String(light, radix: 16))-\(String(dark, radix: 16))", bundle: paletteBundle).opacity(alpha))
    }
}
public struct NativeColor: Sendable {
    public let swiftUI: Color
    public init(swiftUI: Color) { self.swiftUI = swiftUI }
    public func opacity(_ value: Double) -> Self { .init(swiftUI: swiftUI.opacity(value)) }
}

public enum NativeGeometry {
    public static let initialWindow = CGSize(width: 1180, height: 780)
    public static let minimumWindow = CGSize(width: 860, height: 600)
    public static let overviewCard = CGSize(width: 360, height: 200)
    public static let overviewCardGap: CGFloat = 16
    public static let overviewCardRadius: CGFloat = 22
    public static let readingWidth: CGFloat = 744
    public static let settingsSidebarWidth: CGFloat = 220
    public static let settingsHeaderHeight: CGFloat = 110
}
