import MokuseiCore
import MokuseiPluginUI
import SwiftUI

extension EnvironmentValues {
    /// Cached workspaces can edit device-local text while host actions remain
    /// unavailable. A disabled lifecycle or archived owner still stays inert.
    @Entry var nativeOfflineDraftEditing = false
}

/// Measure the editor within its own input row, independent of menu expansion.
struct NativeMokuEditorAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The input row used by both the outside Dock and the permanently open history
/// capsule. The scene supplies authority, draft lifetime and voice ownership.
struct NativeMokuComposerInput: View {
    let draft: NativeComposerDraft
    var cwd: JSONText = ""
    var disabled = false
    var readOnly = false
    var focusEnabled = true
    var focusRequestKey = 0
    var suppressInitialFocus = false
    var maxHeight: CGFloat = 126
    var retainedText: String?
    var retainedAttachments: [NativeComposerAttachment]?
    var retainedDirectories: [NativeComposerDirectory]?
    /// Voice starts through Force Touch or its menu shortcut.
    var activeVoiceControls = AnyView(EmptyView())
    var voiceModeActive = false
    var running = false
    var onCancel: () -> Void = {}
    var availableHeight: CGFloat = 420
    var mentions: NativeMokuDirectoryMentions?
    var onMentionFrame: (CGRect?) -> Void = { _ in }
    var showsEyes = false
    var selectionRequest: NativeComposerSelectionRequest?
    var onEditorStateChange: ((NativeComposerEditorState) -> Void)?
    var onKeyDown: ((NativeComposerKeyEvent) -> Bool)?
    var onEditorSeatChange: (CGFloat) -> Void = { _ in }
    var onEscape: (() -> Void)?
    let onSend: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.nativeOfflineDraftEditing) private var offlineDraftEditing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inputHeight: CGFloat = 58
    @State private var hostPicker: NativeComposerHostFilePicker.Mode?

    private var completionVisible: Bool { mentions?.isOpen == true && !readOnly }
    private var unavailable: Bool { disabled || draft.clearing || draft.isDisposed }
    private var editingUnavailable: Bool { (disabled && !offlineDraftEditing) || draft.clearing || draft.isDisposed }
    private var voiceControlsVisible: Bool {
        voiceModeActive
    }
    private var placeholder: String {
        let directories = retainedDirectories ?? draft.directories
        guard let first = directories.first else { return "Ask Moku…" }
        let name = first.name.string
        let subject: String
        switch directories.count {
        case 1:
            subject = name
        case 2:
            let second = directories[1].name.string
            subject = localize("\(name) 和 \(second)", "\(name) and \(second)")
        default:
            subject = localize("\(name) 等 \(directories.count) 个目录", "\(name) and \(directories.count - 1) other directories")
        }
        return localize("向 Moku 询问关于 \(subject) 的问题…", "Ask Moku about \(subject)…")
    }
    var body: some View {
        VStack(spacing: 0) {
            if let mentions, completionVisible {
                NativeMokuDirectoryMentionList(mentions: mentions,
                    maxHeight: max(0, availableHeight - inputHeight - 12),
                    onChoose: { mentions.choose($0, draft: draft) })
                    .clipped()
                    .padding(.horizontal, 12).padding(.top, 12)
                    .overlay(alignment: .bottom) { Color.primary.opacity(0.08).frame(height: 1).padding(.horizontal, 18) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("native-moku-dock")) } action: { onMentionFrame($0) }
                    .onDisappear { onMentionFrame(nil) }
                    .transition(.opacity)
            }
            input
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { inputHeight = $0 }
        }.foregroundStyle(.primary).disabled(editingUnavailable || readOnly)
            .animation(.smooth(duration: 0.42, extraBounce: 0), value: completionVisible)
            .onDisappear { onMentionFrame(nil) }
            .sheet(item: $hostPicker) { mode in NativeComposerHostFilePicker(draft: draft, mode: mode) }
    }
    private var input: some View {
        VStack(spacing: 0) {
            NativeComposerAttachmentChips(attachments: retainedAttachments ?? draft.attachments,
                directories: retainedDirectories ?? draft.directories,
                containerRadius: NativeMokuCapsuleLayout.cornerRadius,
                onRemove: { id in Task { await draft.removeAttachment(id) } }, onRemoveDirectory: draft.removeDirectory)
                .disabled(unavailable || readOnly)
            HStack(spacing: 0) {
                // This leading seat belongs to Moku's eyes, which the Dock
                // paints above the editor. Keep it non-interactive now that the
                // old voice-reveal button is gone.
                Color.clear.frame(width: 43, height: 34)
                    .overlay {
                        if showsEyes {
                            NativeMokuBlinkingEyes(expression: .focus, focus: 1)
                                .frame(width: 34, height: 25).offset(x: 4.5)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .allowsHitTesting(false)
                attachmentButton
                NativeComposerTextInput(value: Binding(get: { retainedText ?? draft.text }, set: { draft.text = $0 }),
                    placeholder: placeholder, disabled: editingUnavailable, readOnly: readOnly,
                    focusEnabled: focusEnabled, focusRequestKey: focusRequestKey, focusContext: "moku-dock",
                    suppressInitialFocus: suppressInitialFocus,
                    minHeight: 58, maxHeight: maxHeight, fontSize: 14, lineHeight: 20,
                    insets: .init(top: 19, left: 6, bottom: 19, right: 6), onSubmit: { if !unavailable { onSend() } }, onEscape: onEscape,
                    onFiles: { files in if !unavailable { await draft.importFiles(files) } }, preparePaste: draft.preparePaste,
                    selectionRequest: selectionRequest, onEditorStateChange: { state in
                        onEditorStateChange?(state)
                    }, onKeyDown: onKeyDown, submitOnReturn: true)
                    .anchorPreference(key: NativeMokuEditorAnchorKey.self, value: .bounds) { $0 }
                // Keep the seat while it opens, without mounting an inactive
                // voice entry. The workspace retains the media client itself.
                ZStack {
                    if voiceControlsVisible {
                        activeVoiceControls.fixedSize(horizontal: true, vertical: true)
                            .transition(.opacity)
                    }
                }
                    .frame(width: voiceControlsVisible ? 34 : 0, height: 34)
                    .clipped()
                    .disabled(!voiceControlsVisible)
                    .allowsHitTesting(voiceControlsVisible)
                    .accessibilityHidden(!voiceControlsVisible)
                if running && !voiceModeActive {
                    Button(action: onCancel) {
                        RoundedRectangle(cornerRadius: 1).fill(.foreground).frame(width: 10, height: 10)
                            .frame(width: 32, height: 32).contentShape(Circle())
                    }.buttonStyle(.plain).disabled(unavailable || readOnly)
                        .help(localize("停止 Moku", "Stop Moku"))
                        .accessibilityLabel(localize("停止 Moku", "Stop Moku"))
                        .accessibilityIdentifier("moku-stop")
                }
                Button(action: onSend) {
                    NativeIcon(name: "ArrowUp", size: 16).frame(width: 32, height: 32)
                        .background(Color.primary.opacity(draft.canSubmit ? 0.18 : 0.06), in: Circle())
                }.buttonStyle(.plain).disabled(unavailable || !draft.canSubmit || readOnly)
                    .opacity(!unavailable && draft.canSubmit ? 1 : 0.3)
                    .accessibilityLabel(localize("发送", "Send")).accessibilityIdentifier("moku-send")
            }.padding(.leading, 6).padding(.trailing, 13)
                .animation(reduceMotion ? nil : .smooth(duration: 0.42, extraBounce: 0), value: voiceControlsVisible)
            if let error = draft.error {
                Text(composerLocalized(error, locale: locale)).font(.system(size: 11)).foregroundStyle(.red).padding(.bottom, 10)
            }
        }.foregroundStyle(.primary).disabled(editingUnavailable || readOnly)
            .backgroundPreferenceValue(NativeMokuEditorAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    let inset = anchor.map { proxy.size.height - proxy[$0].midY } ?? 29
                    Color.clear.onChange(of: inset, initial: true) { _, value in onEditorSeatChange(value) }
                }
            }
    }
    private var attachmentButton: some View {
        Group {
            if draft.supportsHostFiles {
                Menu {
                    Button(localize("从此设备导入", "Import from this device")) {
                        Task { await draft.chooseFiles(cwd: cwd) }
                    }
                    Button(localize("从主机选择文件", "Choose host files")) { hostPicker = .files }
                    Button(localize("从主机选择目录", "Choose a host directory")) { hostPicker = .directory }
                } label: { attachmentIcon }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            } else {
                Button { Task { await draft.chooseFiles(cwd: cwd) } } label: { attachmentIcon }
            }
        }
        .buttonStyle(.plain).disabled(unavailable || draft.importing || readOnly)
        .help(localize("添加图片或文件", "Add images or files"))
        .accessibilityLabel(localize("添加图片或文件", "Add images or files"))
        .accessibilityIdentifier("moku-add-attachment")
    }
    private var attachmentIcon: some View {
        NativeIcon(name: "Plus", size: 16).frame(width: 28, height: 32)
            .contentShape(Rectangle())
    }
    private func localize(_ zh: String, _ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
}

/// History owns no outside-Dock state: sending, Escape, focus changes and voice
/// transitions cannot collapse this capsule or change its supplied send route.
public struct NativeMokuHistoryComposer: View {
    public let draft: NativeComposerDraft
    public let cwd: JSONText
    public var disabled = false
    public var running = false
    public var focusEnabled = true
    public var focusRequestKey = 0
    public var suppressInitialFocus = false
    public var activeVoiceControls = AnyView(EmptyView())
    public var voiceModeActive = false
    public var voiceBackground = AnyView(EmptyView())
    public var canStartVoice: () -> Bool
    public var startVoice: () -> Void
    public var loadMentionDirectories: (() async throws -> [NativeComposerDirectory])?
    public let onSend: (NativeComposerSubmission) async throws -> Void
    public let onCancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var mentions = NativeMokuDirectoryMentions()
    @State private var availableHeight: CGFloat = 420
    @State private var hovered = false

    public init(draft: NativeComposerDraft, cwd: JSONText, disabled: Bool = false, running: Bool = false,
                focusEnabled: Bool = true, focusRequestKey: Int = 0, suppressInitialFocus: Bool = false,
                activeVoiceControls: AnyView = AnyView(EmptyView()), voiceBackground: AnyView = AnyView(EmptyView()),
                voiceModeActive: Bool = false,
                loadMentionDirectories: (() async throws -> [NativeComposerDirectory])? = nil,
                onSend: @escaping (NativeComposerSubmission) async throws -> Void, onCancel: @escaping () -> Void,
                canStartVoice: @escaping () -> Bool = { false },
                startVoice: @escaping () -> Void = {}) {
        self.draft = draft; self.cwd = cwd; self.disabled = disabled; self.running = running
        self.focusEnabled = focusEnabled; self.focusRequestKey = focusRequestKey; self.suppressInitialFocus = suppressInitialFocus
        self.activeVoiceControls = activeVoiceControls; self.voiceBackground = voiceBackground; self.voiceModeActive = voiceModeActive
        self.canStartVoice = canStartVoice; self.startVoice = startVoice
        self.loadMentionDirectories = loadMentionDirectories; self.onSend = onSend; self.onCancel = onCancel
    }
    public var body: some View {
        NativeMokuComposerInput(draft: draft, cwd: cwd, disabled: disabled,
            focusEnabled: focusEnabled, focusRequestKey: focusRequestKey, suppressInitialFocus: suppressInitialFocus,
            activeVoiceControls: activeVoiceControls, voiceModeActive: voiceModeActive, running: running, onCancel: onCancel, availableHeight: availableHeight,
            mentions: mentions, showsEyes: true,
            selectionRequest: mentions.selectionRequest, onEditorStateChange: mentions.update,
            onKeyDown: { mentions.handle($0, draft: draft) },
            onSend: { guard !disabled else { return }; Task { await draft.submit(onSend) } })
            .fixedSize(horizontal: false, vertical: true)
            .background { ZStack { NativeMokuCapsuleGlass(usesThemeTint: true).id(colorScheme); voiceBackground } }
            .clipShape(RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius))
            .shadow(color: .black.opacity(0.13), radius: hovered ? 17 : 13, y: 6)
            .overlay {
                NativeMokuForceTouchVoiceMonitor(
                    isActive: { !disabled },
                    isInside: { _ in true },
                    canStart: canStartVoice, start: startVoice)
                .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .coordinateSpace(name: "native-moku-dock")
            .onGeometryChange(for: CGFloat.self) { max(58, $0.frame(in: .global).maxY - 24) } action: { availableHeight = $0 }
            .animation(.smooth(duration: 0.42, extraBounce: 0), value: mentions.isOpen)
            .task(id: focusEnabled && !disabled) {
                await mentions.load(enabled: focusEnabled && !disabled, using: loadMentionDirectories)
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Moku")
            .accessibilityIdentifier("moku-history-capsule")
    }
}
