import MokuseiPluginUI
import MokuseiVoice
import SwiftUI

public enum NativeMokuVoiceButtonStyle: Sendable {
    case composer
    case dock
}

/// One persistent voice entry point owns state and call actions in both Moku surfaces.
/// Appearance never starts or stops media.
@MainActor
public struct NativeMokuVoiceControls: View {
    public let client: NativeVoiceMediaClient
    public var style: NativeMokuVoiceButtonStyle
    public var disabled: Bool
    @Environment(\.locale) private var locale
    @State private var confirmingTakeover = false

    public init(client: NativeVoiceMediaClient,
                style: NativeMokuVoiceButtonStyle = .composer, disabled: Bool = false) {
        self.client = client; self.style = style; self.disabled = disabled
    }

    private var active: Bool { client.state.phase != .closed && client.state.phase != .failed }
    private var targetSize: CGFloat {
        34
    }
    private var status: String {
        if client.state.mediaSuspended { return localize("语音已暂停，任务内通话正在使用音频", "Voice paused during thread call") }
        return switch client.state.phase {
        case .preparing: localize("准备语音…", "Preparing voice…")
        case .connecting: localize("连接语音…", "Connecting voice…")
        case .stopping: localize("结束语音…", "Ending voice…")
        case .failed: localize("语音失败", "Voice failed")
        case .closed: localize("语音已关闭", "Voice off")
        case .listening: client.state.muted
            ? localize("麦克风已静音", "Microphone muted") : localize("正在聆听", "Listening")
        }
    }
    private var actionLabel: String {
        if client.state.occupiedOwner != nil { return localize("接管语音…", "Take over voice…") }
        return active ? localize("结束语音，保留任务", "End voice, keep tasks")
            : localize("开始语音", "Start voice")
    }
    private var muteLabel: String {
        client.state.muted ? localize("取消麦克风静音", "Unmute microphone") : localize("麦克风静音", "Mute microphone")
    }
    private var help: String {
        if !client.state.error.codeUnits.isEmpty { return client.state.error.string + "\n" + actionLabel }
        return active ? status + " · " + actionLabel : actionLabel
    }

    public var body: some View {
        if client.state.available || active || !client.state.error.codeUnits.isEmpty {
            Button(action: activate) {
                ZStack {
                    Group {
                        if client.state.phase == .preparing || client.state.phase == .connecting || client.state.phase == .stopping {
                            Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                        } else if !client.state.error.codeUnits.isEmpty && !active {
                            Image(systemName: "exclamationmark").font(.system(size: 15, weight: .semibold))
                        } else {
                            NativeIcon(name: (client.state.muted || client.state.mediaSuspended) ? "MicOff" : "Mic", size: 15)
                        }
                    }
                }
                .frame(width: targetSize, height: targetSize).contentShape(Circle())
            }
            .buttonStyle(MokuVoiceStartStyle(style: style))
            .accessibilityLabel(actionLabel)
            .accessibilityValue(client.state.error.codeUnits.isEmpty ? status : client.state.error.string)
            .accessibilityIdentifier(active ? "moku-voice-stop" : "moku-voice-start")
            .accessibilityActions {
                if client.state.phase == .listening { Button(muteLabel, action: client.toggleMute) }
            }
            // An overlay proposes the entire capsule's size. Keep the button's
            // touch and accessibility bounds on its own visible control.
            .frame(width: targetSize, height: targetSize)
            .fixedSize()
            .focusable()
            .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                activate(); return .handled
            }
            .disabled(!canActivate)
            .help(help)
            .contextMenu {
                if client.state.occupiedOwner != nil {
                    Button(localize("接管语音…", "Take over voice…")) { confirmingTakeover = true }
                }
                if active {
                    Button(muteLabel, action: client.toggleMute).disabled(client.state.phase != .listening)
                    Button(actionLabel) { Task { await client.stop() } }.disabled(client.state.phase == .stopping)
                }
                if !client.state.error.codeUnits.isEmpty { Text(client.state.error.string) }
            }
            .confirmationDialog(localize("另一台设备正在使用 Moku 语音", "Moku voice is active on another device"),
                isPresented: $confirmingTakeover, titleVisibility: .visible) {
                    Button(localize("接管语音", "Take over voice")) { Task { await client.takeOver() } }
                    Button(localize("取消", "Cancel"), role: .cancel) {}
                } message: {
                    Text(localize("接管会结束另一台设备的语音，已经接纳的任务会继续运行。",
                        "Taking over ends the other device’s voice call. Accepted tasks keep running."))
                }
            .background(MokuVoiceAnnouncements(status: status, error: client.state.error.string).frame(width: 0, height: 0))
        }
    }
    private var canActivate: Bool {
        active ? client.state.phase != .stopping : !disabled && client.state.available
    }
    private func activate() {
        guard canActivate else { return }
        if client.state.occupiedOwner != nil && !active { confirmingTakeover = true; return }
        Task { if active { await client.stop() } else { await client.start() } }
    }
    private func localize(_ zh: String, _ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
}

private struct MokuVoiceStartStyle: ButtonStyle {
    let style: NativeMokuVoiceButtonStyle
    func makeBody(configuration: Configuration) -> some View {
        MokuVoiceStartBody(label: configuration.label, style: style)
    }
}

private struct MokuVoiceStartBody<Label: View>: View {
    let label: Label
    let style: NativeMokuVoiceButtonStyle
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    private var highlighted: Bool { enabled && hovered }
    var body: some View {
        label
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: style == .composer ? 7 : 17))
            .opacity(enabled ? 1 : 0.28)
            .animation(style == .dock ? .easeInOut(duration: 0.16) : nil, value: highlighted)
            .animation(style == .dock ? .easeInOut(duration: 0.16) : nil, value: enabled)
            .onHover { hovered = $0 }
    }
    private var foreground: Color {
        switch style {
        case .composer: (highlighted ? NativePalette.thread.ink : NativePalette.thread.muted).swiftUI
        case .dock: Color.primary.opacity(highlighted ? 1 : 0.72)
        }
    }
    private var background: Color {
        guard highlighted else { return .clear }
        return style == .composer ? NativePalette.pair(0xf0efe9, 0x30322b).swiftUI : Color.primary.opacity(0.1)
    }
}

/// Native equivalent of the source's polite status and assertive role="alert".
/// Announcements do not open a modal alert or move keyboard focus.
private struct MokuVoiceAnnouncements: View {
    let status: String
    let error: String
    var body: some View {
        Color.clear.onChange(of: error.isEmpty ? status : error) { _, message in
            if !message.isEmpty { AccessibilityNotification.Announcement(message).post() }
        }
    }
}
