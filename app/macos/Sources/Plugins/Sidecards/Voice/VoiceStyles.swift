import AppKit
import MokuseiPluginUI
import SwiftUI

enum VoicePalette {
    static let blue = NativePalette.pair(0x087cf0, 0x1685fa)
    static let startHover = NativePalette.pair(0x006ee0, 0x3096ff)
    static let paper = NativePalette.pair(0xffffff, 0x1b1c1e)
    static let incoming = NativePalette.pair(0xe9e9eb, 0x343538)
    static let avatar = NativePalette.pair(0xf0f1f3, 0x303135)
    static let endBackground = NativePalette.pair(0xffebe9, 0x472727)
    static let endInk = NativePalette.pair(0xd7342c, 0xff8c85)
    static let mutedBackground = NativePalette.pair(0xdfeefd, 0x1a2a3b)
}

struct VoiceButtonStyle: ButtonStyle {
    enum Kind { case close, start, mute, muted, end, jump }
    let kind: Kind
    func makeBody(configuration: Configuration) -> some View {
        VoiceButtonBody(configuration: configuration, kind: kind)
    }
}
private struct VoiceButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: VoiceButtonStyle.Kind
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                if kind == .jump { RoundedRectangle(cornerRadius: 18).stroke(NativePalette.thread.lineSoft.swiftUI, lineWidth: 1) }
            }
            .shadow(color: kind == .jump ? .black.opacity(1.0 / 15) : .clear, radius: 7, y: 3)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && enabled ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.15), value: hovered)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
            .onHover { hovered = $0 }
    }
    private var radius: CGFloat { kind == .close ? 15 : kind == .jump ? 18 : 23 }
    private var foreground: Color {
        switch kind {
        case .close: hovered ? NativePalette.thread.ink.swiftUI : NativePalette.thread.muted.swiftUI
        case .start: .white
        case .mute: NativePalette.thread.ink.swiftUI
        case .muted, .jump: VoicePalette.blue.swiftUI
        case .end: VoicePalette.endInk.swiftUI
        }
    }
    private var background: Color {
        switch kind {
        case .close: hovered ? VoicePalette.incoming.swiftUI : .clear
        case .start: hovered && enabled ? VoicePalette.startHover.swiftUI : VoicePalette.blue.swiftUI
        case .mute: VoicePalette.incoming.swiftUI
        case .muted: VoicePalette.mutedBackground.swiftUI
        case .end: VoicePalette.endBackground.swiftUI
        case .jump: VoicePalette.paper.swiftUI
        }
    }
}

struct VoiceStatusDot: View {
    let live: Bool
    @State private var pulse = false
    var body: some View {
        Circle().fill(live ? VoicePalette.blue.swiftUI : NativePalette.thread.muted.swiftUI)
            .frame(width: 5, height: 5).opacity(live ? 1 : 0.6)
            .background {
                if live {
                    Circle().fill(VoicePalette.blue.swiftUI.opacity(0.12))
                        .frame(width: pulse ? 11 : 5, height: pulse ? 11 : 5)
                }
            }
            .animation(live ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : nil, value: pulse)
            .onAppear { pulse = live }
            .onChange(of: live) { _, value in pulse = value }
            .accessibilityHidden(true)
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
