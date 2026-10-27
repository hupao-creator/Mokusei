import AppKit
import MokuseiCore
import SwiftUI

/// The shared full-size Moku composer. Its owner controls draft state and scoped
/// actions; this view supplies the existing textarea/chips/toolbar composition.
public struct NativeComposerView: View {
    private static let containerRadius: CGFloat = 15
    @Binding private var value: String
    private let provider: String
    private let providerName: String
    private let providerLogoSource: String
    private let harnessLogo: AnyView?
    private let running: Bool
    private let submitting: Bool
    private let importing: Bool
    private let disabled: Bool
    private let focusEnabled: Bool
    private let focusRequestKey: Int
    private let suppressInitialFocus: Bool
    private let attachments: [NativeComposerAttachment]
    private let directories: [NativeComposerDirectory]
    private let error: String?
    private let voiceControls: AnyView
    private let voiceBackground: AnyView
    private let onChooseFiles: () -> Void
    private let onChooseHostFiles: (() -> Void)?
    private let onChooseHostDirectory: (() -> Void)?
    private let onPasteFiles: (([NativeComposerFile]) -> Void)?
    private let onRemoveAttachment: (JSONText) -> Void
    private let onRemoveDirectory: ((JSONText) -> Void)?
    private let onSend: () -> Void
    private let onCancel: () -> Void
    @Environment(\.locale) private var locale
    @State private var focused = false

    public init(value: Binding<String>, provider: String, providerName: String? = nil, providerLogoSource: String = "", harnessLogo: AnyView? = nil,
                running: Bool, submitting: Bool = false, importing: Bool = false, disabled: Bool = false, focusEnabled: Bool = true,
                focusRequestKey: Int = 0, suppressInitialFocus: Bool = false,
                attachments: [NativeComposerAttachment], directories: [NativeComposerDirectory] = [],
                error: String? = nil, voiceControls: AnyView = AnyView(EmptyView()),
                voiceBackground: AnyView = AnyView(EmptyView()),
                onChooseFiles: @escaping () -> Void, onChooseHostFiles: (() -> Void)? = nil,
                onChooseHostDirectory: (() -> Void)? = nil, onPasteFiles: (([NativeComposerFile]) -> Void)? = nil,
                onRemoveAttachment: @escaping (JSONText) -> Void, onRemoveDirectory: ((JSONText) -> Void)? = nil,
                onSend: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _value = value; self.provider = provider; self.providerName = providerName ?? provider
        self.providerLogoSource = providerLogoSource
        self.harnessLogo = harnessLogo
        self.running = running; self.submitting = submitting; self.disabled = disabled; self.focusEnabled = focusEnabled
        self.importing = importing
        self.focusRequestKey = focusRequestKey; self.suppressInitialFocus = suppressInitialFocus
        self.attachments = attachments; self.directories = directories; self.error = error
        self.voiceControls = voiceControls; self.voiceBackground = voiceBackground; self.onChooseFiles = onChooseFiles; self.onPasteFiles = onPasteFiles
        self.onChooseHostFiles = onChooseHostFiles; self.onChooseHostDirectory = onChooseHostDirectory
        self.onRemoveAttachment = onRemoveAttachment; self.onRemoveDirectory = onRemoveDirectory
        self.onSend = onSend; self.onCancel = onCancel
    }

    private var canSend: Bool {
        !submitting && !importing && !disabled && NativeComposerSubmissionPolicy.canSubmit(text: value, attachments: attachments, directories: directories)
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                NativeComposerAttachmentChips(attachments: attachments, directories: directories,
                    containerRadius: Self.containerRadius,
                    onRemove: onRemoveAttachment, onRemoveDirectory: onRemoveDirectory)
                NativeComposerTextInput(value: $value,
                    placeholder: localized(running ? "Moku 正在协调任务…" : "让 Moku 发起、协调或汇报任务…"),
                    disabled: disabled, focusEnabled: focusEnabled, focusRequestKey: focusRequestKey, focusContext: provider,
                    suppressInitialFocus: suppressInitialFocus,
                    onSubmit: { if canSend { onSend() } }, onFiles: onPasteFiles,
                    onFocusChange: { focused = $0 })
                toolbar
            }
            .background { ZStack { NativePlatformPalette.thread.surfaceStrong.swiftUI; voiceBackground } }
            .clipShape(RoundedRectangle(cornerRadius: Self.containerRadius))
            .overlay(RoundedRectangle(cornerRadius: Self.containerRadius).strokeBorder(border, lineWidth: 1))
            .shadow(color: Color(red: 43 / 255, green: 41 / 255, blue: 35 / 255).opacity(focused ? 0.11 : 0.09),
                    radius: focused ? 19 : 17, y: focused ? 14 : 12)
            .shadow(color: Color(red: 43 / 255, green: 41 / 255, blue: 35 / 255).opacity(focused ? 0.05 : 0.04),
                    radius: focused ? 3.5 : 3, y: 2)
            .animation(.easeOut(duration: 0.12), value: focused)
            .animation(.easeOut(duration: 0.12), value: running)
            if let error, !error.isEmpty {
                Text(localized(error)).font(NativeTypography.inter(size: 9.5))
                    .foregroundStyle(NativePlatformPalette.thread.danger.swiftUI)
                    .multilineTextAlignment(.center).textSelection(.enabled).padding(.top, 6)
                    .accessibilityLabel(localized(error))
            }
        }
        .frame(maxWidth: 820)
        .padding(.bottom, 12)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                Group {
                    if let harnessLogo { harnessLogo.frame(width: 14, height: 14) }
                    else { ThreadCardBrandLogo(logoSource: providerLogoSource, label: providerName, brandKey: provider).scaleEffect(14.0 / 12.0) }
                }.frame(width: 25, height: 25).accessibilityLabel(providerName).help(providerName)
                    .foregroundStyle(NativePlatformPalette.thread.muted.swiftUI)
                attachmentButton
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                voiceControls
                if running {
                    Button(action: onCancel) { RoundedRectangle(cornerRadius: 1).fill().frame(width: 10, height: 10) }
                        .buttonStyle(ComposerButtonStyle(kind: .stop)).disabled(disabled)
                        .help(localized("停止 Moku")).accessibilityLabel(localized("停止 Moku"))
                }
                Button(action: onSend) { NativeIcon(name: "ArrowUp", size: 17) }
                    .buttonStyle(ComposerButtonStyle(kind: .send)).disabled(!canSend)
                    .help(localized("发送")).accessibilityLabel(localized("发送"))
            }
        }
        .padding(.init(top: 4, leading: 10, bottom: 7, trailing: 7))
        .frame(minHeight: 44)
    }
    @ViewBuilder private var attachmentButton: some View {
        Group {
            if onChooseHostFiles != nil || onChooseHostDirectory != nil {
                Menu {
                    Button(localized("从此设备导入"), action: onChooseFiles)
                    if let onChooseHostFiles { Button(localized("从主机选择文件"), action: onChooseHostFiles) }
                    if let onChooseHostDirectory { Button(localized("从主机选择目录"), action: onChooseHostDirectory) }
                } label: { NativeIcon(name: "Paperclip", size: 14) }
            } else {
                Button(action: onChooseFiles) { NativeIcon(name: "Paperclip", size: 14) }
            }
        }
        .buttonStyle(ComposerButtonStyle(kind: .tool)).disabled(disabled)
        .help(localized("添加图片或文件")).accessibilityLabel(localized("添加图片或文件"))
    }
    private var border: Color {
        if running {
            return NativePlatformPalette.blend(NativePlatformPalette.thread.accent, with: NativePlatformPalette.thread.line, fraction: 0.7).swiftUI
        }
        return (focused ? NativePlatformPalette.pair(0xb9b7ae, 0x64665c) : NativePlatformPalette.pair(0xd8d5cd, 0x4b4d44)).swiftUI
    }
    private func localized(_ text: String) -> String { composerLocalized(text, locale: locale) }
}

/// Convenience host for a shared client-owned draft. Voice remains injected by
/// the actual voice owner, preserving its audio session and permission lifecycle.
public struct NativeDraftComposerView: View {
    @State private var hostPicker: NativeComposerHostFilePicker.Mode?
    private let draft: NativeComposerDraft
    private let cwd: JSONText
    private let provider: String
    private let providerName: String?
    private let providerLogoSource: String
    private let harnessLogo: AnyView?
    private let running: Bool
    private let disabled: Bool
    private let focusEnabled: Bool
    private let focusRequestKey: Int
    private let suppressInitialFocus: Bool
    private let voiceControls: AnyView
    private let voiceBackground: AnyView
    private let onSend: (NativeComposerSubmission) async throws -> Void
    private let onCancel: () -> Void
    public init(draft: NativeComposerDraft, cwd: JSONText, provider: String, providerName: String? = nil,
                providerLogoSource: String = "", harnessLogo: AnyView? = nil, running: Bool, disabled: Bool = false, focusEnabled: Bool = true,
                focusRequestKey: Int = 0, suppressInitialFocus: Bool = false, voiceControls: AnyView = AnyView(EmptyView()),
                voiceBackground: AnyView = AnyView(EmptyView()),
                onSend: @escaping (NativeComposerSubmission) async throws -> Void, onCancel: @escaping () -> Void) {
        self.draft = draft; self.cwd = cwd; self.provider = provider; self.providerName = providerName
        self.providerLogoSource = providerLogoSource; self.running = running; self.disabled = disabled
        self.harnessLogo = harnessLogo
        self.focusEnabled = focusEnabled; self.focusRequestKey = focusRequestKey
        self.suppressInitialFocus = suppressInitialFocus; self.voiceControls = voiceControls; self.voiceBackground = voiceBackground
        self.onSend = onSend; self.onCancel = onCancel
    }
    public var body: some View {
        NativeComposerView(value: Binding(get: { draft.text }, set: { draft.text = $0 }), provider: provider,
            providerName: providerName, providerLogoSource: providerLogoSource, harnessLogo: harnessLogo, running: running,
            submitting: draft.submitting, importing: draft.importing, disabled: disabled || draft.clearing || draft.isDisposed,
            focusEnabled: focusEnabled, focusRequestKey: focusRequestKey, suppressInitialFocus: suppressInitialFocus,
            attachments: draft.attachments, directories: draft.directories, error: draft.error, voiceControls: voiceControls,
            voiceBackground: voiceBackground,
            onChooseFiles: { Task { await draft.chooseFiles(cwd: cwd) } },
            onChooseHostFiles: draft.supportsHostFiles ? { hostPicker = .files } : nil,
            onChooseHostDirectory: draft.supportsHostFiles ? { hostPicker = .directory } : nil,
            onPasteFiles: { files in Task { await draft.importFiles(files) } },
            onRemoveAttachment: { id in Task { await draft.removeAttachment(id) } },
            onRemoveDirectory: draft.removeDirectory,
            onSend: { Task { await draft.submit(onSend) } }, onCancel: onCancel)
            .sheet(item: $hostPicker) { mode in NativeComposerHostFilePicker(draft: draft, mode: mode) }
    }
}

struct ComposerButtonStyle: ButtonStyle {
    enum Kind { case tool, send, stop, remove }
    let kind: Kind
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        ComposerButtonBody(kind: kind, label: configuration.label, pressed: configuration.isPressed, enabled: enabled)
    }
}
private struct ComposerButtonBody<Label: View>: View {
    let kind: ComposerButtonStyle.Kind
    let label: Label
    let pressed, enabled: Bool
    @State private var hovered = false
    private var large: Bool { kind == .send || kind == .stop }
    var body: some View {
        // The remove target matches the attachment chip's 22pt control row.
        label.frame(width: large ? 32 : kind == .remove ? 22 : 27, height: large ? 32 : kind == .remove ? 22 : 27)
            .foregroundStyle(foreground).background(background, in: RoundedRectangle(cornerRadius: large ? 10 : 7))
            .contentShape(RoundedRectangle(cornerRadius: large ? 10 : 7))
            .opacity(enabled ? 1 : large ? 0.22 : 0.28)
            .onHover { hovered = $0 }
    }
    private var foreground: Color {
        large ? NativePlatformPalette.pair(0xffffff, 0x20211f).swiftUI
            : (hovered && enabled ? NativePlatformPalette.thread.ink : NativePlatformPalette.thread.muted).swiftUI
    }
    private var background: Color {
        if kind == .stop { return NativePlatformPalette.thread.accent.swiftUI }
        if kind == .send {
            return (hovered && enabled ? NativePlatformPalette.pair(0x0d0e0c, 0xd1d3c8) : NativePlatformPalette.thread.ink).swiftUI
        }
        if (hovered || pressed) && enabled {
            return kind == .remove ? NativePlatformPalette.pair(0x20211e, 0xe0e5da, alpha: 0.08).swiftUI : NativePlatformPalette.pair(0xf0efe9, 0x30322b).swiftUI
        }
        return .clear
    }
}

func composerLocalized(_ text: String, locale: Locale) -> String {
    guard locale.language.languageCode?.identifier != "zh" else { return text }
    return [
        "Moku 正在协调任务…": "Moku is coordinating tasks…", "让 Moku 发起、协调或汇报任务…": "Ask Moku to start, coordinate, or report on tasks…",
        "添加图片或文件": "Add images or files", "停止 Moku": "Stop Moku", "发送": "Send", "Moku 附件": "Moku attachments",
        "从此设备导入": "Import from this device", "从主机选择文件": "Choose host files", "从主机选择目录": "Choose a host directory",
        "移除目录": "Remove directory", "移除附件": "Remove attachment", "暂存中…": "Staging…",
        "附件数量不能超过 20 个": "You can attach up to 20 files", "附件正在处理中，请稍候": "Attachments are being processed. Please wait.",
        "无路径的粘贴内容不能超过 20 MB；请先保存文件后再通过回形针添加": "Pasted content without a file path cannot exceed 20 MB. Save it first, then attach it with the paperclip.",
    ][text] ?? text
}
