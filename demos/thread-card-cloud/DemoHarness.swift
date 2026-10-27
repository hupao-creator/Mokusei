import MokuseiHarnessClaude
import MokuseiHarnessCodex
import MokuseiHarnessOpenCode
import MokuseiHarnessPi
import MokuseiPluginUI
import SwiftUI

// Only fixtures live here; renderer and palettes are production code.
enum DemoHarness: String, CaseIterable, Identifiable {
    case codex, claude, pi, opencode
    var id: String { rawValue }
    var label: String {
        switch self { case .codex: "Codex"; case .claude: "Claude"; case .pi: "Pi"; case .opencode: "OpenCode" }
    }
    var colorDescription: String {
        switch self { case .codex: "蓝 · 靛蓝"; case .claude: "陶土 · 杏橙"; case .pi: "彩虹"; case .opencode: "石墨 · 银白" }
    }
    var accent: Color {
        switch self {
        case .codex: NativePalette.pair(0x3941ff, 0x8f94ff).swiftUI
        case .claude: NativePalette.pair(0xd97757, 0xe5a184).swiftUI
        case .pi: NativePalette.pair(0x6c5ce7, 0xb5a7ff).swiftUI
        case .opencode: NativePalette.pair(0x33312f, 0xd9d7d4).swiftUI
        }
    }
    @MainActor var cloudPalette: NativeCloudPalette {
        switch self {
        case .codex: CodexLogo.threadCardCloudPalette
        case .claude: ClaudeLogo.threadCardCloudPalette
        case .pi: PiLogo.threadCardCloudPalette
        case .opencode: OpenCodeLogo.threadCardCloudPalette
        }
    }
    @MainActor func cloudPalette(intensity: Double) -> NativeCloudPalette {
        let palette = cloudPalette
        return NativeCloudPalette(channels: palette.channels.map {
            .init(color: $0.color, seed: $0.seed, energy: $0.energy * intensity)
        }, phase: palette.phase, lobeScale: palette.lobeScale)
    }
}
