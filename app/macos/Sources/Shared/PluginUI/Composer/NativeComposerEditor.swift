import AppKit
import SwiftUI

/// The native input session owns text and selection while marked text exists.
struct NativeComposerEditor: NSViewRepresentable {
    @Binding var value: String
    @Binding var selection: NSRange?
    @Binding var focused: Bool
    var selectionRequest: NativeComposerSelectionRequest?
    var initialSelection: NSRange?
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
    var singleLine = false
    var emphasizedInsertionPoint = false
    var reduceCaretMotion = false
    var onPaste: (([NSItemProvider], NSRange) -> Void)? = nil
    var textInsets = EdgeInsets()

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = singleLine ? SingleLineComposerScrollView() : NativeStyledScrollView()
        if singleLine { scroll.contentView = SingleLineComposerClipView() }
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        let editor = ComposerTextView()
        editor.isRichText = false
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.focusRingType = .none
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 5
        if singleLine {
            // Search-style fields scroll horizontally instead of wrapping; the
            // document view grows past the viewport and stays one line high.
            editor.isVerticallyResizable = false
            editor.isHorizontallyResizable = true
            editor.autoresizingMask = [.height]
            editor.textContainer?.widthTracksTextView = false
            editor.textContainer?.heightTracksTextView = true
            editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 0)
        } else {
            editor.isVerticallyResizable = true
            editor.isHorizontallyResizable = false
            editor.autoresizingMask = [.width]
            editor.textContainer?.widthTracksTextView = true
        }
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
        context.coordinator.pendingSelection = initialSelection
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
        if coordinator.lastModel?.utf16.elementsEqual(value.utf16) != true {
            coordinator.lastModel = value
            if !editor.hasMarkedText(), !editor.string.utf16.elementsEqual(value.utf16) {
                let oldSelection = editor.selectedRange()
                editor.string = value
                replacedText = true
                editor.setSelectedRange(coordinator.clamped(oldSelection))
            }
        }
        // A remounted editor restores the draft before applying the caret saved
        // by the previous surface. Completion requests below still take priority.
        if let pending = coordinator.pendingSelection, !editor.hasMarkedText() {
            coordinator.pendingSelection = nil
            editor.setSelectedRange(coordinator.clamped(pending))
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
        editor.pasteAttachments = unavailable ? nil : onPaste
        editor.isEditable = !unavailable
        editor.isSelectable = !unavailable
        editor.singleLine = singleLine
        editor.emphasizedInsertionPoint = emphasizedInsertionPoint
        editor.reduceCaretMotion = reduceCaretMotion
        if singleLine {
            // The document must be at least as wide as its text or late caret
            // positions cannot be scrolled into view. It also stays at least as
            // wide as the field, keeping the empty area clickable.
            let viewport = NSSize(width: max(1, scroll.contentSize.width),
                                  height: max(1, scroll.contentSize.height))
            editor.minSize = viewport
            var used: CGFloat = 0
            if let container = editor.textContainer, let layout = editor.layoutManager {
                layout.ensureLayout(for: container)
                used = layout.usedRect(for: container).width
            }
            let width = max(viewport.width, ceil(used) + editor.textContainerInset.width * 2 + 10)
            if editor.frame.width != width || editor.frame.height != viewport.height {
                editor.setFrameSize(NSSize(width: width, height: viewport.height))
                editor.scrollRangeToVisible(editor.selectedRange())
            }
            // No horizontal scroller: legacy scrollbar styles would reserve a
            // row inside the one-line field. The native editor still brings the
            // caret into view and scrolls with the trackpad.
            scroll.hasHorizontalScroller = false
            scroll.hasVerticalScroller = false
        } else {
            scroll.hasVerticalScroller = showsScroller
        }
        coordinator.applySelectionRequest()
        if let window = editor.window {
            if focused && focusEnabled && !unavailable && window.firstResponder !== editor { window.makeFirstResponder(editor) }
            // A mouse click can make AppKit first responder before the next
            // SwiftUI focus report. Only explicit availability changes may blur it.
            else if (!focusEnabled || unavailable) && window.firstResponder === editor { window.makeFirstResponder(nil) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerEditor
        weak var editor: ComposerTextView?
        var updating = false
        var lastModel: String?
        var fontSize: CGFloat?
        var spacing: CGFloat?
        var pendingSelection: NSRange?
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
            if synchronizeText, parent.singleLine, !editor.hasMarkedText(), let storage = editor.textStorage {
                // Normalize at the editor boundary even if the resulting model
                // value is unchanged and SwiftUI therefore does not rerender.
                // Each newline occupies one UTF-16 unit, preserving selection.
                let text = storage.string as NSString
                for index in (0..<text.length).reversed() {
                    if let scalar = UnicodeScalar(text.character(at: index)), CharacterSet.newlines.contains(scalar) {
                        storage.replaceCharacters(in: NSRange(location: index, length: 1), with: " ")
                    }
                }
            }
            let state = NativeComposerEditorState(text: editor.string, selection: editor.selectedRange(),
                focused: editor.window?.firstResponder === editor, composing: editor.hasMarkedText())
            // Passive rerenders/focus reports must not overwrite a model update
            // that arrived before SwiftUI has applied it to the native editor.
            if synchronizeText {
                lastModel = state.text
                if !parent.value.utf16.elementsEqual(state.text.utf16) { parent.value = state.text }
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
                // A single-line field owns no submission and must not insert a
                // break for any Return variant.
                if parent.singleLine { return true }
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
    var pasteAttachments: (([NSItemProvider], NSRange) -> Void)?
    var emphasizedInsertionPoint = false {
        didSet {
            guard emphasizedInsertionPoint != oldValue else { return }
            if emphasizedInsertionPoint { wantsLayer = true }
            caret.remove()
            needsDisplay = true
        }
    }
    var reduceCaretMotion = false { didSet { caret.reduceMotion = reduceCaretMotion } }
    /// Shift/Option-Return bypass `handle` and reach the native bindings, so
    /// the editor itself must also refuse line breaks in a single-line field.
    var singleLine = false
    override func insertNewline(_ sender: Any?) {
        if !singleLine { super.insertNewline(sender) }
    }
    override func insertLineBreak(_ sender: Any?) {
        if !singleLine { super.insertLineBreak(sender) }
    }
    private let caret = NativeComposerCaret()
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
    private func editing(_ operation: () -> Void) {
        operationDepth += 1
        operation()
        operationDepth -= 1
        if operationDepth == 0 { changed?() }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        caret.remove()
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
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard emphasizedInsertionPoint, !hasMarkedText() else {
            caret.remove()
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        guard shouldDrawInsertionPoint, window?.isKeyWindow == true,
              window?.occlusionState.contains(.visible) == true,
              selectedRange().length == 0, !isHiddenOrHasHiddenAncestor, rect.intersects(visibleRect) else {
            caret.remove()
            return
        }
        // Off callbacks also erase the old insertion rectangle during movement.
        // Keep the breathing layer alive, but only position it on an on callback.
        if flag { caret.show(at: rect, in: self) }
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
        if ranges.count != 1 || selectedRange().length != 0 { caret.remove() }
    }
    override func viewDidHide() {
        super.viewDidHide()
        caret.remove()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        caret.remove()
        if let window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(caretWindowChanged), name: name, object: window)
            }
        }
    }
    @objc private func caretWindowChanged() {
        if window?.isKeyWindow != true || window?.occlusionState.contains(.visible) != true { caret.remove() }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // CALayer colors are resolved values; refresh even without an edit.
        caret.remove()
        needsDisplay = true
        if emphasizedInsertionPoint { updateInsertionPointStateAndRestartTimer(true) }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { caret.remove(); focusChanged?() }
        return accepted
    }
}

/// SwiftUI can resize the one-line viewport after AppKit has centered a
/// shorter initial document. Keep vertical scrolling pinned as it grows, while
/// preserving the horizontal position used for long queries.
@MainActor private final class SingleLineComposerScrollView: NativeStyledScrollView {
    override func layout() {
        super.layout()
        guard let documentView else { return }
        let viewport = contentView.bounds
        if documentView.frame.height != viewport.height {
            documentView.setFrameSize(NSSize(width: documentView.frame.width, height: viewport.height))
        }
        if contentView.bounds.origin.y != 0 {
            contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: 0))
            reflectScrolledClipView(contentView)
        }
    }
}

/// AppKit also constrains the clip while caret scrolling or text sizing occurs,
/// outside the scroll view's layout pass. Single-line fields have no vertical
/// scroll range, even while their document is temporarily shorter than the clip.
@MainActor private final class SingleLineComposerClipView: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: newOrigin.x, y: 0))
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        constrained.origin.y = 0
        return constrained
    }
}
