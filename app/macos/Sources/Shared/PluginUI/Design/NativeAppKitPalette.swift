import SwiftUI

public enum NativePlatformPalette {
    public static let overview = Surface(source: NativePalette.overview)
    public static let thread = Surface(source: NativePalette.thread)
    public static let settings = Settings(source: NativePalette.settings)
    public struct Surface: @unchecked Sendable {
        public var canvas: NativePlatformColor { NativePlatformColor(source.canvas.swiftUI) }
        public var surface: NativePlatformColor { NativePlatformColor(source.surface.swiftUI) }
        public var surfaceStrong: NativePlatformColor { NativePlatformColor(source.surfaceStrong.swiftUI) }
        public var surfaceSoft: NativePlatformColor { NativePlatformColor(source.surfaceSoft.swiftUI) }
        public var ink: NativePlatformColor { NativePlatformColor(source.ink.swiftUI) }
        public var inkStrong: NativePlatformColor { NativePlatformColor(source.inkStrong.swiftUI) }
        public var muted: NativePlatformColor { NativePlatformColor(source.muted.swiftUI) }
        public var faint: NativePlatformColor { NativePlatformColor(source.faint.swiftUI) }
        public var line: NativePlatformColor { NativePlatformColor(source.line.swiftUI) }
        public var lineSoft: NativePlatformColor { NativePlatformColor(source.lineSoft.swiftUI) }
        public var accent: NativePlatformColor { NativePlatformColor(source.accent.swiftUI) }
        public var accentSoft: NativePlatformColor { NativePlatformColor(source.accentSoft.swiftUI) }
        public var action: NativePlatformColor { NativePlatformColor(source.action.swiftUI) }
        public var provider: NativePlatformColor { NativePlatformColor(source.provider.swiftUI) }
        public var danger: NativePlatformColor { NativePlatformColor(source.danger.swiftUI) }
        public var warning: NativePlatformColor { NativePlatformColor(source.warning.swiftUI) }
        public var success: NativePlatformColor { NativePlatformColor(source.success.swiftUI) }
        public var agentRun: NativePlatformColor { NativePlatformColor(source.agentRun.swiftUI) }
        let source: NativePalette.Surface
    }
    public struct Settings: @unchecked Sendable {
        public var text: NativePlatformColor { NativePlatformColor(source.text.swiftUI) }
        public var muted: NativePlatformColor { NativePlatformColor(source.muted.swiftUI) }
        public var accent: NativePlatformColor { NativePlatformColor(source.accent.swiftUI) }
        public var sidebar: NativePlatformColor { NativePlatformColor(source.sidebar.swiftUI) }
        public var main: NativePlatformColor { NativePlatformColor(source.main.swiftUI) }
        public var line: NativePlatformColor { NativePlatformColor(source.line.swiftUI) }
        public var inputBorder: NativePlatformColor { NativePlatformColor(source.inputBorder.swiftUI) }
        public var input: NativePlatformColor { NativePlatformColor(source.input.swiftUI) }
        public var tab: NativePlatformColor { NativePlatformColor(source.tab.swiftUI) }
        public var selectedTab: NativePlatformColor { NativePlatformColor(source.selectedTab.swiftUI) }
        public var selectedTabFill: NativePlatformColor { NativePlatformColor(source.selectedTabFill.swiftUI) }
        public var hintSurface: NativePlatformColor { NativePlatformColor(source.hintSurface.swiftUI) }
        public var hintBorder: NativePlatformColor { NativePlatformColor(source.hintBorder.swiftUI) }
        public var danger: NativePlatformColor { NativePlatformColor(source.danger.swiftUI) }
        let source: NativePalette.Settings
    }
    /// Blend in native sRGB.
    public static func blend(_ first: NativePlatformColor, with second: NativePlatformColor,
                             fraction: CGFloat) -> NativePlatformColor {
        return first.blended(withFraction: fraction, of: second) ?? second
    }
    public static func color(_ hex: UInt32, alpha: Double = 1) -> NativePlatformColor { NativePlatformColor(NativePalette.color(hex, alpha: alpha).swiftUI) }
    public static func pair(_ light: UInt32, _ dark: UInt32, alpha: Double = 1) -> NativePlatformColor { NativePlatformColor(NativePalette.pair(light, dark, alpha: alpha).swiftUI) }
}
/// Existing shared call sites retain their spelling while using native colors on each platform.
public typealias NativeAppKitPalette = NativePlatformPalette
