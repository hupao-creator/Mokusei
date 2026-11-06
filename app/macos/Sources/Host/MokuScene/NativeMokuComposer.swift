import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

extension EnvironmentValues {
    /// Cached workspaces can edit device-local text while host actions remain
    /// unavailable. A disabled lifecycle or archived owner still stays inert.
    @Entry var nativeOfflineDraftEditing = false
}

/// Shared completion chrome. The Dock mounts it above the fixed input row so
/// insertion cannot animate the editor separately from its persistent face.
struct NativeMokuComposerCompletion: View {
    let mentions: NativeMokuDirectoryMentions
    let draft: NativeComposerDraft
    let maxHeight: CGFloat
    var onFrame: (CGRect?) -> Void = { _ in }

    var body: some View {
        NativeMokuDirectoryMentionList(mentions: mentions, maxHeight: maxHeight,
            onChoose: { mentions.choose($0, draft: draft) })
            .clipped()
            .padding(.horizontal, 12).padding(.top, 12)
            .overlay(alignment: .bottom) { Color.primary.opacity(0.08).frame(height: 1).padding(.horizontal, 18) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("native-moku-dock")) } action: { onFrame($0) }
            .onDisappear { onFrame(nil) }
    }
}

/// Reflows the four persistent seats without replacing the native editor at a
/// width breakpoint; focus, selection and marked text belong to that same view.
private struct NativeMokuComposerRowLayout: Layout {
    var compact: Bool

    private func sizes(_ subviews: Subviews, width: CGFloat) -> [CGSize] {
        let eye = subviews[0].sizeThatFits(.unspecified)
        let attachment = subviews[1].sizeThatFits(.unspecified)
        let actions = subviews[3].sizeThatFits(.unspecified)
        let editorWidth = max(0, width - attachment.width - (compact ? 0 : eye.width + actions.width))
        let editor = subviews[2].sizeThatFits(.init(width: editorWidth, height: nil))
        return [eye, attachment, CGSize(width: editorWidth, height: editor.height), actions]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 560
        let seats = sizes(subviews, width: width)
        let height = compact ? max(seats[1].height, seats[2].height) + 40
            : seats.map(\.height).max()!
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let seats = sizes(subviews, width: bounds.width)
        if compact {
            let upper = max(seats[1].height, seats[2].height)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + upper + 17),
                anchor: .leading, proposal: .init(seats[0]))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + upper / 2),
                anchor: .leading, proposal: .init(seats[1]))
            subviews[2].place(at: CGPoint(x: bounds.minX + seats[1].width, y: bounds.minY + upper / 2),
                anchor: .leading, proposal: .init(seats[2]))
            subviews[3].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + upper + 17),
                anchor: .trailing, proposal: .init(seats[3]))
        } else {
            var x = bounds.minX
            for index in seats.indices {
                subviews[index].place(at: CGPoint(x: x, y: bounds.midY),
                    anchor: .leading, proposal: .init(seats[index]))
                x += seats[index].width
            }
        }
    }
}

/// The input row used by both the outside Dock and the permanently open history
/// capsule. The scene supplies authority, draft lifetime and voice ownership.
struct NativeMokuComposerInput: View {
    let draft: NativeComposerDraft
    var cwd: JSONText = ""
    var disabled = false
    var busy = false
    var threadTitle: String?
    var superThreadContext = false
    var sidecardComposer: SidecardComposerRequest?
    var placeholderIcon: AnyView?
    var readOnly = false
    var focusEnabled = true
    var automaticFocus = true
    var focusRequestKey = 0
    var suppressInitialFocus = false
    var maxHeight: CGFloat = 126
    var landing = false
    var compact = false
    var retainedText: String?
    var retainedAttachments: [NativeComposerAttachment]?
    var retainedDirectories: [NativeComposerDirectory]?
    /// Voice starts by holding the native editor; the workspace owns the session.
    var canStartVoice: () -> Bool = { false }
    var startVoice: () -> Void = {}
    var activeVoiceControls = AnyView(EmptyView())
    var voiceModeActive = false
    var running = false
    var onCancel: () -> Void = {}
    var availableHeight: CGFloat = 420
    var mentions: NativeMokuDirectoryMentions?
    var includesCompletion = true
    var onMentionFrame: (CGRect?) -> Void = { _ in }
    var showsEyes = false
    var selectionRequest: NativeComposerSelectionRequest?
    var initialSelection: NSRange?
    var onEditorStateChange: ((NativeComposerEditorState) -> Void)?
    var onKeyDown: ((NativeComposerKeyEvent) -> Bool)?
    var onEditorSeatChange: (CGFloat) -> Void = { _ in }
    var onEscape: (() -> Void)?
    let onSend: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.nativeOfflineDraftEditing) private var offlineDraftEditing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inputHeight: CGFloat = 58
    @State private var editorRowHeight: CGFloat = 58
    @State private var errorHeight: CGFloat = 0
    @State private var hostPicker: NativeComposerHostFilePicker.Mode?

    private var completionVisible: Bool { mentions?.isOpen == true && !readOnly }
    private var unavailable: Bool { disabled || draft.clearing || draft.isDisposed }
    private var editingUnavailable: Bool { (disabled && !offlineDraftEditing) || draft.clearing || draft.isDisposed }
    private var voiceControlsVisible: Bool {
        voiceModeActive
    }
    private var hasInput: Bool {
        !NativeComposerSubmissionPolicy.trimmedText(retainedText ?? draft.text).isEmpty
            || !(retainedAttachments ?? draft.attachments).isEmpty
            || !(retainedDirectories ?? draft.directories).isEmpty
    }
    private var placeholder: String {
        if let sidecardComposer { return sidecardComposer.placeholder }
        if let threadTitle {
            return localize("发送给「\(threadTitle)」…", "Message \(threadTitle)…")
        }
        if superThreadContext {
            return localize("向 Moku 提问，附带当前 Super Thread…", "Ask Moku with this Super Thread…")
        }
        let directories = retainedDirectories ?? draft.directories
        guard let first = directories.first else {
            return localize("向 Moku 提问，或长按说话…", "Ask Moku… or hold to speak")
        }
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
        return localize("向 Moku 询问关于 \(subject) 的问题，或长按说话…", "Ask Moku about \(subject)… or hold to speak")
    }
    var body: some View {
        VStack(spacing: 0) {
            if includesCompletion, let mentions, completionVisible {
                NativeMokuComposerCompletion(mentions: mentions, draft: draft,
                    maxHeight: max(0, availableHeight - inputHeight - 12), onFrame: onMentionFrame)
                    .transition(.opacity)
            }
            input
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { inputHeight = $0 }
        }.foregroundStyle(.primary).disabled(editingUnavailable || readOnly)
            .animation(reduceMotion ? nil : .smooth(duration: 0.42, extraBounce: 0), value: includesCompletion && completionVisible)
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
            NativeMokuComposerRowLayout(compact: compact) {
                eyeSeat
                if let sidecardComposer {
                    Button(action: sidecardComposer.cancel) {
                        NativeIcon(name: "X", size: 16).frame(width: 28, height: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help(localize("取消标注", "Cancel annotation"))
                        .accessibilityLabel(localize("取消标注", "Cancel annotation"))
                        .accessibilityIdentifier("moku-cancel-annotation")
                } else { attachmentButton }
                editor
                HStack(spacing: 0) { actions }
            }.padding(.leading, 6).padding(.trailing, 13)
                .onGeometryChange(for: CGFloat.self) { compact ? 34 : $0.size.height } action: { editorRowHeight = $0 }
                .animation(reduceMotion ? nil : .smooth(duration: 0.42, extraBounce: 0), value: voiceControlsVisible)
            if let error = draft.error {
                Text(sidecardComposer == nil ? composerLocalized(error, locale: locale)
                    : NativePluginLocalization.localize(error, locale: locale))
                    .font(.system(size: 11)).foregroundStyle(.red).padding(.bottom, 10)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { errorHeight = $0 }
                    .onDisappear { errorHeight = 0 }
            }
        }.foregroundStyle(.primary).disabled(editingUnavailable || readOnly)
            // Sizes are local to the row. Resolving an editor anchor through
            // an animating ancestor also includes its transient translation,
            // which must not be fed back into the face's bottom inset.
            .onChange(of: editorRowHeight / 2 + errorHeight + (compact ? 6 : 0), initial: true) { _, inset in
                onEditorSeatChange(inset)
            }
    }
    // At high zoom/narrow widths the editor gets its own line. Fixed action
    // seats must never consume its entire width or compress native text to zero.
    private var eyeSeat: some View {
        Color.clear.frame(width: 43, height: 34)
            .overlay {
                if showsEyes {
                    NativeMokuBlinkingEyes(expression: .focus, focus: 1)
                        .frame(width: 34, height: 25).offset(x: 4.5)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .allowsHitTesting(false)
    }
    private var editor: some View {
        NativeComposerTextInput(value: Binding(get: { retainedText ?? draft.text }, set: { draft.text = $0 }),
            placeholder: placeholder, placeholderIcon: placeholderIcon, placeholderLineLimit: 1,
            disabled: editingUnavailable || busy, readOnly: readOnly || busy,
            focusEnabled: focusEnabled, automaticFocus: automaticFocus,
            focusRequestKey: focusRequestKey, focusContext: "moku-dock",
            suppressInitialFocus: suppressInitialFocus,
            minHeight: compact ? 32 : (landing ? 76 : 58), maxHeight: compact ? max(32, maxHeight - 40) : maxHeight,
            fontSize: landing ? 16 : 14, lineHeight: landing ? 24 : 20,
            insets: .init(top: compact ? 6 : (landing ? 26 : 19), left: 6,
                         bottom: compact ? 6 : (landing ? 26 : 19), right: 6),
            onSubmit: { if !unavailable && (sidecardComposer?.ready ?? true) { onSend() } }, onEscape: onEscape,
            onFiles: importFiles, preparePaste: preparePaste,
            selectionRequest: selectionRequest, initialSelection: initialSelection, onEditorStateChange: { state in
                onEditorStateChange?(state)
            }, onKeyDown: onKeyDown, submitOnReturn: true, emphasizedInsertionPoint: true)
            .overlay {
                NativeMokuLongPressVoiceMonitor(
                    isActive: { threadTitle == nil && focusEnabled && !unavailable && !readOnly && !voiceModeActive },
                    canStart: canStartVoice, start: startVoice)
                    .allowsHitTesting(false)
            }
            .help(editorHelp)
            .accessibilityActions {
                if threadTitle == nil {
                    Button(localize("开始语音", "Start voice")) {
                        if focusEnabled && !unavailable && !readOnly && !voiceModeActive && canStartVoice() { startVoice() }
                    }
                }
            }
    }
    private var importFiles: (([NativeComposerFile]) async -> Void)? {
        guard sidecardComposer == nil else { return nil }
        return { files in if !unavailable { await draft.importFiles(files) } }
    }
    private var preparePaste: (() -> NativeComposerPastePreparation?)? {
        guard sidecardComposer == nil else { return nil }
        return draft.preparePaste
    }
    private var editorHelp: String {
        if sidecardComposer != nil {
            return localize("描述当前网页选区；Return 发送，Shift+Return 换行，Esc 取消标注", "Describe the selected page area; Return sends, Shift+Return adds a line, Escape cancels annotation")
        }
        return threadTitle == nil
            ? localize("长按 0.5 秒开始语音，松开后继续对话", "Hold for 0.5 seconds to start voice; release to keep talking")
            : localize("输入内容将直接发送给此 Thread", "Input is sent directly to this thread")
    }
    @ViewBuilder private var actions: some View {
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
                .help(stopLabel)
                .accessibilityLabel(stopLabel)
                .accessibilityIdentifier("moku-stop")
        }
        // Retain the editor's width when the first/last character
        // changes, but mount no button or background for an empty draft.
        ZStack {
            if hasInput {
                Button(action: onSend) {
                    NativeIcon(name: "ArrowUp", size: 16).frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.18), in: Circle())
                }.buttonStyle(.plain).disabled(unavailable || !draft.canSubmit || readOnly || !(sidecardComposer?.ready ?? true))
                    .opacity(!unavailable && draft.canSubmit && (sidecardComposer?.ready ?? true) ? 1 : 0.3)
                    .accessibilityLabel(sidecardComposer == nil ? localize("发送", "Send") : localize("发送批注", "Send annotation")).accessibilityIdentifier("moku-send")
            }
        }.frame(width: 32, height: 32)
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
    private var stopLabel: String {
        threadTitle == nil ? localize("停止 Moku", "Stop Moku") : localize("停止此 Thread", "Stop this thread")
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
            canStartVoice: canStartVoice, startVoice: startVoice,
            activeVoiceControls: activeVoiceControls, voiceModeActive: voiceModeActive, running: running, onCancel: onCancel, availableHeight: availableHeight,
            mentions: mentions, showsEyes: true,
            selectionRequest: mentions.selectionRequest, onEditorStateChange: mentions.update,
            onKeyDown: { mentions.handle($0, draft: draft) },
            onSend: { guard !disabled else { return }; Task { await draft.submit(onSend) } })
            .fixedSize(horizontal: false, vertical: true)
            .background { ZStack { NativeMokuCapsuleGlass(); voiceBackground } }
            .clipShape(RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius))
            .shadow(color: .black.opacity(0.13), radius: hovered ? 17 : 13, y: 6)
            .onHover { hovered = $0 }
            .coordinateSpace(name: "native-moku-dock")
            .onGeometryChange(for: CGFloat.self) { max(58, $0.frame(in: .global).maxY - 24) } action: { availableHeight = $0 }
            .animation(.smooth(duration: 0.42, extraBounce: 0), value: mentions.isOpen)
            .task(id: focusEnabled && !disabled) {
                await mentions.load(enabled: focusEnabled && !disabled, using: loadMentionDirectories)
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Moku")
            .accessibilityIdentifier("moku-history-capsule")
            .environment(\.colorScheme, .dark)
    }
}
