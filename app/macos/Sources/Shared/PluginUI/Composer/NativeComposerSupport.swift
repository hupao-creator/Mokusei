import SwiftUI

struct ComposerRemoveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        ComposerRemoveButtonBody(label: configuration.label, pressed: configuration.isPressed, enabled: enabled)
    }
}
private struct ComposerRemoveButtonBody<Label: View>: View {
    let label: Label
    let pressed, enabled: Bool
    @State private var hovered = false
    var body: some View {
        // The remove target matches the attachment chip's 22pt control row.
        label.frame(width: 22, height: 22)
            .foregroundStyle(foreground).background(background, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.28)
            .onHover { hovered = $0 }
    }
    private var foreground: Color {
        (hovered && enabled ? NativePlatformPalette.thread.ink : NativePlatformPalette.thread.muted).swiftUI
    }
    private var background: Color {
        if (hovered || pressed) && enabled {
            return NativePlatformPalette.pair(0x20211e, 0xe0e5da, alpha: 0.08).swiftUI
        }
        return .clear
    }
}

public func composerLocalized(_ text: String, locale: Locale) -> String {
    guard locale.language.languageCode?.identifier != "zh" else { return text }
    let countPrefix = "附件数量不能超过 ", countSuffix = " 个"
    if text.hasPrefix(countPrefix), text.hasSuffix(countSuffix),
       let count = Int(text.dropFirst(countPrefix.count).dropLast(countSuffix.count)) {
        return "You can attach up to \(count) files"
    }
    if text.hasPrefix("草稿未能保存到设备：") {
        return "Could not save the draft on this device: " + text.dropFirst("草稿未能保存到设备：".count)
    }
    return [
        "无效的主机文件路径": "Invalid host file path",
        "附件总大小不能超过 100 MB": "Attachments cannot exceed 100 MB in total",
        "无路径的粘贴内容不能超过 20 MB": "Pasted content without a file path cannot exceed 20 MB",
        "此 Thread 已归档或不可用，无法追加任务。": "This thread is archived or unavailable and cannot accept a follow-up.",
        "请选择文件": "Choose files", "主机文件预览不可用": "Host file preview is unavailable",
        "主机文件选择不可用": "Host file selection is unavailable",
        "附件数量超过主机限制": "The attachments exceed the host file limit",
        "附件大小超过主机限制": "The attachments exceed the host size limit",
        "Moku 正在协调任务…": "Moku is coordinating tasks…", "让 Moku 发起、协调或汇报任务…": "Ask Moku to start, coordinate, or report on tasks…",
        "添加图片或文件": "Add images or files", "停止 Moku": "Stop Moku", "发送": "Send", "Moku 附件": "Moku attachments",
        "从此设备导入": "Import from this device", "从主机选择文件": "Choose host files", "从主机选择目录": "Choose a host directory",
        "移除目录": "Remove directory", "移除附件": "Remove attachment", "暂存中…": "Staging…",
        "附件数量不能超过 20 个": "You can attach up to 20 files", "附件正在处理中，请稍候": "Attachments are being processed. Please wait.",
        "无路径的粘贴内容不能超过 20 MB；请先保存文件后再通过回形针添加": "Pasted content without a file path cannot exceed 20 MB. Save it first, then attach it with the paperclip.",
    ][text] ?? text
}
