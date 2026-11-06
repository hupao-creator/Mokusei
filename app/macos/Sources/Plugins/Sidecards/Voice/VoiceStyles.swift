import AppKit
import MokuseiPluginUI
import SwiftUI

enum VoicePalette {
    static let blue = NativePalette.pair(0x087cf0, 0x1685fa)
    static let paper = NativePalette.pair(0xffffff, 0x1b1c1e)
    static let incoming = NativePalette.pair(0xe9e9eb, 0x343538)
    static let avatar = NativePalette.pair(0xf0f1f3, 0x303135)
}

struct VoiceJumpButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(VoicePalette.blue.swiftUI)
            .background(VoicePalette.paper.swiftUI, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18).stroke(NativePalette.thread.lineSoft.swiftUI, lineWidth: 1)
            }
            .shadow(color: .black.opacity(1.0 / 15), radius: 7, y: 3)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && enabled ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct VoiceLineHeight: ViewModifier {
    let size: CGFloat
    let height: CGFloat
    func body(content: Content) -> some View {
        let font = NativeTypography.interPlatformFont(size: size)
        let leading = max(0, height - (font.ascender - font.descender + font.leading))
        content.lineSpacing(leading).padding(.vertical, leading / 2)
    }
}
