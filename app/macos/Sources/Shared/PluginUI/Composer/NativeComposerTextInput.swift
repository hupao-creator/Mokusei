import Foundation
import CoreText
import UniformTypeIdentifiers
import SwiftUI

/// UTF-16 offsets match the native text system and the composer contract.
public struct NativeComposerEditorState: Equatable, Sendable {
    public let text: String
    public let selection: NSRange
    public let focused: Bool
    public let composing: Bool
    public init(text: String, selection: NSRange, focused: Bool, composing: Bool) {
        self.text = text; self.selection = selection; self.focused = focused; self.composing = composing
    }
}

public struct NativeComposerSelectionRequest: Equatable, Sendable {
    public let id: UUID
    public let range: NSRange
    public let focus: Bool
    public init(id: UUID = UUID(), range: NSRange, focus: Bool = true) {
        self.id = id; self.range = range; self.focus = focus
    }
}

public struct NativeComposerKeyEvent: Sendable {
    public enum Key: Sendable { case up, down, enter, tab, escape }
    public let key: Key
    public let shift: Bool
    public let command: Bool
    public let option: Bool
    public let control: Bool
    public init(key: Key, shift: Bool = false, command: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key; self.shift = shift; self.command = command; self.option = option; self.control = control
    }
}

/// SwiftUI multiline editor shared by Moku and conversation sidecards.
/// The platform editor owns marked text and selection; SwiftUI owns the draft.
public struct NativeComposerTextInput: View {
    @Binding private var value: String
    private let placeholder: String
    private let disabled: Bool
    private let readOnly: Bool
    private let focusEnabled: Bool
    private let automaticFocus: Bool
    private let focusRequestKey: Int
    private let focusContext: String
    private let suppressInitialFocus: Bool
    private let minHeight: CGFloat
    private let maxHeight: CGFloat
    private let fontSize: CGFloat
    private let lineHeight: CGFloat
    private let insets: NativeComposerInsets
    private let selectionRequest: NativeComposerSelectionRequest?
    private let onSubmit: () -> Void
    private let onEscape: (() -> Void)?
    private let onFiles: (([NativeComposerFile]) -> Void)?
    private let onFocusChange: ((Bool) -> Void)?
    private let onEditorStateChange: ((NativeComposerEditorState) -> Void)?
    private let onKeyDown: ((NativeComposerKeyEvent) -> Bool)?
    private let submitOnReturn: Bool
    @State private var focused = false
    @State private var selection: NSRange?
    @State private var measuredHeight: CGFloat
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var environmentEnabled
    private var unavailable: Bool { disabled || readOnly || !environmentEnabled }

    public init(value: Binding<String>, placeholder: String, disabled: Bool = false, readOnly: Bool = false,
                focusEnabled: Bool = true, automaticFocus: Bool = true,
                focusRequestKey: Int = 0, focusContext: String = "", suppressInitialFocus: Bool = false,
                minHeight: CGFloat = 54, maxHeight: CGFloat = 180, fontSize: CGFloat = 13.5,
                lineHeight: CGFloat = 20.925,
                insets: NativeComposerInsets = NativeComposerInsets(top: 15, left: 16, bottom: 8, right: 16),
                onSubmit: @escaping () -> Void, onEscape: (() -> Void)? = nil,
                onFiles: (([NativeComposerFile]) -> Void)? = nil, onFocusChange: ((Bool) -> Void)? = nil,
                selectionRequest: NativeComposerSelectionRequest? = nil,
                onEditorStateChange: ((NativeComposerEditorState) -> Void)? = nil,
                onKeyDown: ((NativeComposerKeyEvent) -> Bool)? = nil,
                submitOnReturn: Bool = false) {
        _value = value; self.placeholder = placeholder; self.disabled = disabled; self.readOnly = readOnly
        self.focusEnabled = focusEnabled
        self.automaticFocus = automaticFocus
        self.focusRequestKey = focusRequestKey; self.focusContext = focusContext
        self.suppressInitialFocus = suppressInitialFocus
        self.minHeight = minHeight; self.maxHeight = max(minHeight, maxHeight)
        self.fontSize = fontSize; self.lineHeight = lineHeight; self.insets = insets
        self.selectionRequest = selectionRequest
        self.onSubmit = onSubmit; self.onEscape = onEscape; self.onFiles = onFiles; self.onFocusChange = onFocusChange
        self.onEditorStateChange = onEditorStateChange; self.onKeyDown = onKeyDown
        self.submitOnReturn = submitOnReturn
        _measuredHeight = State(initialValue: minHeight)
    }

    public var body: some View {
        NativeComposerEditor(value: $value, selection: $selection, focused: $focused,
            selectionRequest: selectionRequest, focusEnabled: focusEnabled, unavailable: unavailable,
            fontSize: fontSize, spacing: spacing, showsScroller: measuredHeight > maxHeight,
            onState: onEditorStateChange, onKeyDown: onKeyDown, onSubmit: onSubmit, onEscape: onEscape,
            submitOnReturn: submitOnReturn, onPaste: nativePaste)
            // Split the trailing line spacing around the glyphs to center a single line.
            .padding(EdgeInsets(top: insets.top + spacing / 2, leading: insets.left,
                               bottom: max(0, insets.bottom - spacing / 2), trailing: insets.right))
            .background(alignment: .topLeading) {
                if value.isEmpty {
                    Text(placeholder).font(.system(size: fontSize)).foregroundStyle(Color.primary.opacity(0.85))
                        .padding(.leading, insets.left + 5).padding(.top, insets.top + spacing / 2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .background {
                Text(value.isEmpty ? " " : value + " ")
                    .font(.system(size: fontSize)).lineSpacing(spacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // Text omits spacing after its last line; the editor reserves it.
                    .padding(EdgeInsets(top: insets.top, leading: insets.left + 5,
                                        bottom: insets.bottom + spacing, trailing: insets.right + 5))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeight = $0 }
                    .hidden().allowsHitTesting(false).accessibilityHidden(true)
            }
            .frame(height: min(maxHeight, max(minHeight, measuredHeight)))
            .help(submitOnReturn
                ? (locale.language.languageCode?.identifier == "zh" ? "Enter 发送，⌘Enter 或 Shift+Enter 换行" : "Enter to send, ⌘Enter or Shift+Enter for a new line")
                : (locale.language.languageCode?.identifier == "zh" ? "Enter 换行，⌘Enter 发送" : "Enter for a new line, ⌘Enter to send"))
            .disabled(unavailable)
            .background {
                NativeComposerPasteShortcut(enabled: !unavailable && onFiles != nil) { providers, range in
                    paste(providers, selection: range)
                }
            }
            .onPasteCommand(of: [.fileURL, .png, .tiff]) { providers in
                paste(providers)
            }
            .onChange(of: focused) { _, value in onFocusChange?(value) }
            .task(id: FocusRequest(key: focusRequestKey, context: focusContext)) {
                if focusEnabled && !unavailable && (focusRequestKey > 0 || automaticFocus && !suppressInitialFocus) { focused = true }
            }
            .onChange(of: unavailable) { _, unavailable in if unavailable { focused = false } }
            .onChange(of: focusEnabled) { _, enabled in if !enabled { focused = false } }
            .dropDestination(for: URL.self) { urls, _ in
                guard !unavailable, let onFiles else { return false }
                let files = urls.filter(\.isFileURL).map(NativeComposerFile.init(url:))
                guard !files.isEmpty else { return false }; onFiles(files); return true
            }
            .accessibilityLabel(placeholder)
    }
    private var nativePaste: (([NSItemProvider], NSRange) -> Void)? {
        guard onFiles != nil else { return nil }
        return { providers, range in paste(providers, selection: range) }
    }
    private func paste(_ providers: [NSItemProvider], selection nativeSelection: NSRange? = nil) {
        guard !unavailable, let onFiles else { return }
        let original = value
        let replacement: NSRange
        if let nativeSelection { replacement = nativeSelection }
        else if let selection { replacement = selection }
        else { replacement = NSRange(location: original.utf16.count, length: 0) }
        Task { @MainActor in
            let content = await NativeComposerPaste.load(providers)
            guard !unavailable else { return }
            if let text = content.text {
                if value == original { value = content.replacingText(in: value, selection: replacement) }
                else { value += text }
            }
            if !content.files.isEmpty { onFiles(content.files) }
        }
    }
    private struct FocusRequest: Equatable { let key: Int; let context: String }
    private var spacing: CGFloat {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
        return max(0, lineHeight - ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)))
    }
}

public struct NativeComposerInsets: Sendable {
    public var top, left, bottom, right: CGFloat
    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
}
