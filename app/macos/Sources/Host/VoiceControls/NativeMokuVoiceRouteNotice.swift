import AppKit
import MokuseiVoice
import MokuseiPluginUI
import SwiftUI

/// A route stop is visible even when the selected Agent has no voice controls.
struct NativeMokuVoiceRouteNotice: View {
    let client: NativeVoiceMediaClient
    @Environment(\.locale) private var locale

    var body: some View {
        if let notice = client.routeNotices.first {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(text("Moku 语音已停止采集", "Moku microphone stopped"), systemImage: "mic.slash")
                        .font(.headline)
                    Spacer()
                    Button { client.dismissRouteNotice(notice.id) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(text("关闭此提示", "Dismiss this notice"))
                        .disabled(client.hasPendingStop)
                }
                Text(notice.agentSelected
                    ? text("已切换发送目标，原 Moku 通话已结束采集；此处未开启 Agent 语音。已接纳的任务继续运行。", "The send target changed. Moku capture has stopped; Agent voice has not been started. Accepted tasks continue.")
                    : text("页面来源已变化。请在新页面重新开启语音；已接纳的任务继续使用原来源。", "The page source changed. Start voice again on the new page; accepted tasks keep their original source."))
                if client.state.phase == .stopping {
                    Text(text("正在等待原通话关闭确认…", "Waiting for the previous call to close…"))
                }
                if client.hasPendingStop, client.state.phase == .failed {
                    Text(client.state.error.string).foregroundStyle(.red).textSelection(.enabled)
                    Button(text("重试结束原通话", "Retry ending the previous call")) { Task { await client.stop() } }
                }
                if let transcript = notice.transcript, !transcript.string.isEmpty {
                    Text(text("已收到的原通话转写（可能不完整）：", "Received transcript from the previous call (may be incomplete):"))
                    ScrollView { Text(transcript.string).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 100)
                    Button(text("复制转写", "Copy transcript")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript.string, forType: .string)
                    }
                }
                Text(text("切换时尚未接纳的语音不会自动重送；未完成识别的内容需要重新确认。", "Unadmitted speech is not resent automatically. Please confirm any speech that was not fully transcribed."))
                    .foregroundStyle(.secondary)
            }
            .font(.callout).padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("moku-voice-route-stop")
            .nativeCanvasNavigationRegion()
        }
    }

    private func text(_ zh: String, _ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
}
