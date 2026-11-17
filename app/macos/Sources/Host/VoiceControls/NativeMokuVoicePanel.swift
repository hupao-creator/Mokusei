import MokuseiVoice
import MokuseiPluginUI
import SwiftUI

/// A workspace surface observing the retained media owner. Mounting and
/// unmounting affect visualizer demand only, never microphone authority.
struct NativeMokuVoicePanel: View {
    let client: NativeVoiceMediaClient
    var exclusions: NativeClickExclusions? = nil
    @Environment(\.locale) private var locale

    var body: some View {
        if client.interfacePresented {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(text("Moku 语音", "Moku voice")).font(.headline)
                    Text(status).foregroundStyle(.secondary)
                    Spacer()
                    NativeMokuVoiceControls(client: client, style: .dock)
                    if client.state.phase == .listening {
                        Button(action: client.toggleMute) {
                            Image(systemName: client.state.muted ? "mic.slash" : "mic")
                        }
                        .accessibilityLabel(client.state.muted
                            ? text("取消静音", "Unmute") : text("静音", "Mute"))
                    }
                    Button { Task { await client.closeInterface() } } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(text("关闭语音模式", "Close voice mode"))
                    .accessibilityIdentifier("moku-voice-close")
                    .disabled(client.state.phase == .stopping)
                }
                if !client.state.error.string.isEmpty {
                    NativeScrollView {
                        Text(client.state.error.string).foregroundStyle(.red)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 80)
                }
                if let transcript = client.inputTranscript.message {
                    NativeScrollView {
                        Text(transcript.text.string).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                    .accessibilityIdentifier("moku-voice-transcript")
                }
            }
            .font(.callout).padding(14)
            .background {
                NativeMokuVoiceCloud(client: client, visible: true)
                    .allowsHitTesting(false)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("moku-voice-panel")
            .nativeCanvasNavigationRegion()
            .background {
                if let exclusions { NativeClickExclusionRegion(exclusions: exclusions) }
            }
        }
    }

    private var status: String {
        switch client.state.phase {
        case .preparing: text("准备中…", "Preparing…")
        case .connecting: text("连接中…", "Connecting…")
        case .listening: client.state.muted ? text("已静音", "Muted") : text("正在聆听", "Listening")
        case .stopping: text("正在关闭…", "Closing…")
        case .failed: text("连接异常", "Connection failed")
        case .closed: text("连接已关闭", "Connection closed")
        }
    }

    private func text(_ zh: String, _ en: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }
}
