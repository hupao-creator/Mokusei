import AppKit
import SwiftUI

/// The native input session owns text and selection while marked text exists.
struct NativeComposerEditor: NSViewRepresentable {
    struct FocusRequest: Equatable {
        let key: Int
        let context: String
    }

    @Binding var value: String
    var draft: NativeComposerDraft?
    @Binding var selection: NSRange?
    @Binding var focused: Bool
    var pasteOwnerID: UUID
    var focusRequest: FocusRequest?
    var onFocusRequestAcquired: ((Int, NSTextView) -> Void)?
    var selectionRequest: NativeComposerSelectionRequest?
    var initialSelection: NSRange?
    var preservesSelection = false
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
    var emphasizedInsertionPoint = false
    var onPaste: (([NSItemProvider], NSRange) -> Void)? = nil
    var textInsets = EdgeInsets()

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NativeStyledScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        let editor = ComposerTextView()
        editor.pasteOwnerID = pasteOwnerID
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
        editor.changed = { [weak coordinator = context.coordinator] edited in
            coordinator?.publish(synchronizeText: true, nativeEdit: edited)
        }
        editor.focusChanged = { [weak coordinator = context.coordinator] in coordinator?.schedulePublish() }
        editor.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.applyFocusRequest() }
        editor.handleKey = { [weak coordinator = context.coordinator] event in coordinator?.handle(event) ?? false }
        scroll.documentView = editor
        context.coordinator.editor = editor
        context.coordinator.pendingSelection = initialSelection
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.parent.draft !== draft { coordinator.parent.draft?.editors.remove(coordinator) }
        draft?.editors.add(coordinator)
        coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        coordinator.updating = true
        defer {
            coordinator.updating = false
            coordinator.schedulePublish()
        }
        let active = focusEnabled && !unavailable
        // Closing keeps the native view alive during travel. Capture before
        // AppKit disables selection or resigns focus, not from a later report.
        if preservesSelection, coordinator.active == true, !active, !editor.hasMarkedText() {
            coordinator.suspendedSelection = (editor.string, editor.selectedRange())
        }
        if preservesSelection, coordinator.active == false, active,
           let saved = coordinator.suspendedSelection {
            coordinator.pendingSelection = saved.text.utf16.elementsEqual(value.utf16)
                ? saved.range : NSRange(location: value.utf16.count, length: 0)
            coordinator.suspendedSelection = nil
        }
        coordinator.active = active
        var restoredSelection = false
        var replacedText = false
        // Remember ignored model updates too: they must not be replayed after commit.
        if coordinator.lastModel?.utf16.elementsEqual(value.utf16) != true {
            coordinator.lastModel = value
            if !editor.hasMarkedText(), !editor.string.utf16.elementsEqual(value.utf16) {
                let oldSelection = editor.selectedRange()
                editor.string = value
                replacedText = true
                editor.setSelectedRange(coordinator.clamped(oldSelection))
            }
        }
        editor.isEditable = !unavailable
        editor.isSelectable = !unavailable
        // A remounted editor restores the draft before applying the caret saved
        // by the previous surface. Completion requests below still take priority.
        if let pending = coordinator.pendingSelection, !editor.hasMarkedText(), !preservesSelection || active {
            coordinator.pendingSelection = nil
            editor.setSelectedRange(coordinator.clamped(pending))
            restoredSelection = true
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
        editor.composerTextInsets = textInsets
        editor.pasteOwnerID = pasteOwnerID
        editor.pasteAttachments = unavailable ? nil : onPaste
        editor.emphasizedInsertionPoint = emphasizedInsertionPoint
        scroll.hasVerticalScroller = showsScroller
        coordinator.applySelectionRequest()
        if active { coordinator.applyFocusRequest() }
        // Availability can end editing. The focus binding reports AppKit's
        // responder and stays out of the acquisition path.
        else if let window = editor.window, window.firstResponder === editor {
            window.makeFirstResponder(nil)
        }
        if restoredSelection { editor.scrollRangeToVisible(editor.selectedRange()) }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerEditor
        weak var editor: ComposerTextView?
        var updating = false
        var lastModel: String?
        var fontSize: CGFloat?
        var spacing: CGFloat?
        var pendingSelection: NSRange?
        var active: Bool?
        var suspendedSelection: (text: String, range: NSRange)?
        private var lastRequest: UUID?
        private var appliedFocusRequest: FocusRequest?
        private var lastState: NativeComposerEditorState?
        private var publishScheduled = false
        init(_ parent: NativeComposerEditor) { self.parent = parent }

        /// Sends and receipts change the editing buffer between AppKit events.
        /// Install the projection before another native edit can publish stale text.
        func applyDraft(_ draft: NativeComposerDraft) {
            guard parent.draft === draft, !parent.unavailable, parent.focusEnabled,
                  let editor, !editor.hasMarkedText() else { return }
            let old = editor.string as NSString, value = draft.inputText as NSString
            guard !editor.string.utf16.elementsEqual(draft.inputText.utf16) else { return }
            let wasUpdating = updating
            updating = true
            var selection = editor.selectedRange()
            let offset = value.length - old.length
            if offset >= 0, value.compare(old as String, options: .literal,
                    range: NSRange(location: offset, length: old.length)) == .orderedSame {
                selection.location += offset
            }
            lastModel = draft.inputText
            editor.string = draft.inputText
            editor.setSelectedRange(clamped(selection))
            // Invalidate native checking/completion for the previous buffer.
            editor.didChangeText()
            updating = wasUpdating
            schedulePublish()
        }

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
        func applyFocusRequest() {
            guard active == true, let editor, let window = editor.window,
                  let request = parent.focusRequest, request != appliedFocusRequest else { return }
            // A request made before attachment waits for this editor's window.
            // A non-key window can set its own responder without taking foreground.
            // Respect AppKit's refusal and any later user focus change.
            appliedFocusRequest = request
            if window.firstResponder !== editor { window.makeFirstResponder(editor) }
            if window.firstResponder === editor { parent.onFocusRequestAcquired?(request.key, editor) }
            schedulePublish()
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
        func publish(synchronizeText: Bool = false, nativeEdit: Bool = false) {
            guard let editor, editor.operationDepth == 0 else { return }
            guard !updating else { schedulePublish(); return }
            applySelectionRequest()
            let state = NativeComposerEditorState(text: editor.string, selection: editor.selectedRange(),
                focused: editor.window?.firstResponder === editor, composing: editor.hasMarkedText())
            // Passive rerenders/focus reports must not overwrite a model update
            // that arrived before SwiftUI has applied it to the native editor.
            if synchronizeText {
                lastModel = state.text
                if (nativeEdit && parent.draft != nil) || !parent.value.utf16.elementsEqual(state.text.utf16) {
                    parent.value = state.text
                }
            }
            if parent.selection != state.selection { parent.selection = state.selection }
            if parent.focused != state.focused { parent.focused = state.focused }
            if state != lastState { lastState = state; parent.onState?(state) }
        }
        func textDidChange(_ notification: Notification) { publish(synchronizeText: true, nativeEdit: true) }
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
                guard !event.isARepeat else { return true }
                parent.onSubmit()
                return true
            }
            if key == .escape, let escape = parent.onEscape { escape(); return true }
            return false
        }
    }
}

@MainActor final class ComposerTextView: NativeCaretTextView {
    var pasteOwnerID: UUID?
    var changed: ((Bool) -> Void)?
    var focusChanged: (() -> Void)?
    var windowChanged: (() -> Void)?
    var handleKey: ((NSEvent) -> Bool)?
    var pasteAttachments: (([NSItemProvider], NSRange) -> Void)?
    var composerTextInsets = EdgeInsets() {
        didSet {
            guard composerTextInsets != oldValue else { return }
            textContainerInset = NSSize(width: (composerTextInsets.leading + composerTextInsets.trailing) / 2,
                                       height: (composerTextInsets.top + composerTextInsets.bottom) / 2)
            needsDisplay = true
        }
    }
    override var textContainerOrigin: NSPoint {
        // AppKit sizes with symmetric insets; shift the origin to retain the
        // composer's asymmetric line-spacing allowance without changing height.
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x + (composerTextInsets.leading - composerTextInsets.trailing) / 2,
                       y: origin.y + (composerTextInsets.top - composerTextInsets.bottom) / 2)
    }
    private(set) var operationDepth = 0
    // AppKit may replace selected text with identical characters. Carry its
    // edit notification through the outer input call, including IME callbacks.
    private var editedDuringInput = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?()
    }
    override func didChangeText() {
        if operationDepth > 0 { editedDuringInput = true }
        super.didChangeText()
    }
    private func editing(_ operation: () -> Void) {
        operationDepth += 1
        operation()
        operationDepth -= 1
        if operationDepth == 0 {
            let edited = editedDuringInput
            editedDuringInput = false
            changed?(edited)
        }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        editing { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange) }
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        editing { super.insertText(string, replacementRange: replacementRange) }
    }
    override func unmarkText() { editing { super.unmarkText() } }
    override func paste(_ sender: Any?) {
        let providers = NativeComposerPaste.attachmentProviders(from: .general)
        if !hasMarkedText(), !providers.isEmpty, let pasteAttachments {
            pasteAttachments(providers, selectedRange())
        } else { super.paste(sender) }
    }
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
