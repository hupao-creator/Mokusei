import AppKit
import SwiftUI

/// The native input session owns text and selection while marked text exists.
struct NativeComposerEditor: NSViewRepresentable {
    @Binding var value: String
    @Binding var selection: NSRange?
    @Binding var focused: Bool
    var selectionRequest: NativeComposerSelectionRequest?
    var focusEnabled: Bool
    var unavailable: Bool
    var fontSize: CGFloat
    var spacing: CGFloat
    var showsScroller: Bool
    var onState: ((NativeComposerEditorState) -> Void)?
    var onKeyDown: ((NativeComposerKeyEvent) -> Bool)?
    var onSubmit: () -> Void
    var onEscape: (() -> Void)?
    var submitOnReturn = false
    var onPaste: (([NSItemProvider], NSRange) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = ComposerTextView()
        editor.isRichText = false
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.focusRingType = .none
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 5
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.layoutManager?.allowsNonContiguousLayout = false
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.delegate = context.coordinator
        editor.changed = { [weak coordinator = context.coordinator] in coordinator?.publish(synchronizeText: true) }
        editor.focusChanged = { [weak coordinator = context.coordinator] in coordinator?.schedulePublish() }
        editor.handleKey = { [weak coordinator = context.coordinator] event in coordinator?.handle(event) ?? false }
        scroll.documentView = editor
        context.coordinator.editor = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        coordinator.updating = true
        defer {
            coordinator.updating = false
            coordinator.schedulePublish()
        }
        var replacedText = false
        // Remember ignored model updates too: they must not be replayed after commit.
        if coordinator.lastModel != value {
            coordinator.lastModel = value
            if !editor.hasMarkedText(), editor.string != value {
                let oldSelection = editor.selectedRange()
                editor.string = value
                replacedText = true
                editor.setSelectedRange(coordinator.clamped(oldSelection))
            }
        }
        // Caret/focus rerenders must not invalidate glyph layout after scrolling.
        if !editor.hasMarkedText(), replacedText || coordinator.fontSize != fontSize || coordinator.spacing != spacing {
            coordinator.fontSize = fontSize; coordinator.spacing = spacing
            let font = NSFont.systemFont(ofSize: fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ]
            editor.font = font
            editor.defaultParagraphStyle = paragraph
            editor.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: editor.string.utf16.count))
            editor.typingAttributes = attributes
            editor.textColor = .labelColor
            editor.insertionPointColor = .labelColor
        }
        editor.isEditable = !unavailable
        editor.isSelectable = !unavailable
        scroll.hasVerticalScroller = showsScroller
        coordinator.applySelectionRequest()
        if let window = editor.window {
            if focused && focusEnabled && !unavailable && window.firstResponder !== editor { window.makeFirstResponder(editor) }
            else if (!focused || !focusEnabled || unavailable) && window.firstResponder === editor { window.makeFirstResponder(nil) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerEditor
        weak var editor: ComposerTextView?
        var updating = false
        var lastModel: String?
        var fontSize: CGFloat?
        var spacing: CGFloat?
        private var lastRequest: UUID?
        private var lastState: NativeComposerEditorState?
        private var publishScheduled = false
        init(_ parent: NativeComposerEditor) { self.parent = parent }

        func clamped(_ range: NSRange) -> NSRange {
            let length = editor?.string.utf16.count ?? 0
            let location = min(max(0, range.location), length)
            return NSRange(location: location, length: min(max(0, range.length), length - location))
        }
        func applySelectionRequest() {
            guard let editor, !editor.hasMarkedText(),
                  let request = parent.selectionRequest, request.id != lastRequest else { return }
            lastRequest = request.id
            editor.setSelectedRange(clamped(request.range))
            if request.focus && parent.focusEnabled && !parent.unavailable { editor.window?.makeFirstResponder(editor) }
        }
        func schedulePublish() {
            guard !publishScheduled else { return }
            publishScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                publishScheduled = false
                publish()
            }
        }
        func publish(synchronizeText: Bool = false) {
            guard let editor, editor.operationDepth == 0 else { return }
            guard !updating else { schedulePublish(); return }
            applySelectionRequest()
            let state = NativeComposerEditorState(text: editor.string, selection: editor.selectedRange(),
                focused: editor.window?.firstResponder === editor, composing: editor.hasMarkedText())
            // Passive rerenders/focus reports must not overwrite a model update
            // that arrived before SwiftUI has applied it to the native editor.
            if synchronizeText {
                lastModel = state.text
                if parent.value != state.text { parent.value = state.text }
            }
            if parent.selection != state.selection { parent.selection = state.selection }
            if parent.focused != state.focused { parent.focused = state.focused }
            if state != lastState { lastState = state; parent.onState?(state) }
        }
        func textDidChange(_ notification: Notification) { publish(synchronizeText: true) }
        func textViewDidChangeSelection(_ notification: Notification) { publish() }
        func textDidBeginEditing(_ notification: Notification) { publish() }
        func textDidEndEditing(_ notification: Notification) { publish() }
        func handle(_ event: NSEvent) -> Bool {
            guard !parent.unavailable, let editor, !editor.hasMarkedText() else { return false }
            publish()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let returnModifiers = flags.intersection([.command, .shift, .option, .control])
            let key: NativeComposerKeyEvent.Key
            switch event.keyCode {
            case 126: key = .up
            case 125: key = .down
            case 48: key = .tab
            case 53: key = .escape
            case 36, 76:
                if parent.submitOnReturn, returnModifiers == .command {
                    editor.insertText("\n", replacementRange: editor.selectedRange())
                    return true
                }
                // Shift-Return and macOS Control/Option bindings remain native.
                guard returnModifiers.isEmpty || returnModifiers == .command else { return false }
                key = .enter
            default: return false
            }
            if parent.onKeyDown?(.init(key: key, shift: flags.contains(.shift), command: flags.contains(.command),
                option: flags.contains(.option), control: flags.contains(.control))) == true { return true }
            if key == .enter {
                guard parent.submitOnReturn || returnModifiers == .command else { return false }
                parent.onSubmit()
                return true
            }
            if key == .escape, let escape = parent.onEscape { escape(); return true }
            return false
        }
    }
}

@MainActor final class ComposerTextView: NSTextView {
    var changed: (() -> Void)?
    var focusChanged: (() -> Void)?
    var handleKey: ((NSEvent) -> Bool)?
    private(set) var operationDepth = 0
    private func editing(_ operation: () -> Void) {
        operationDepth += 1
        operation()
        operationDepth -= 1
        if operationDepth == 0 { changed?() }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        editing { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange) }
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        editing { super.insertText(string, replacementRange: replacementRange) }
    }
    override func unmarkText() { editing { super.unmarkText() } }
    override func keyDown(with event: NSEvent) {
        if hasMarkedText() || handleKey?(event) != true { super.keyDown(with: event) }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?() }
        return accepted
    }
}
