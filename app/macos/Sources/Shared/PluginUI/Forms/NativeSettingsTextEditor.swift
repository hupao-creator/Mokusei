import AppKit
import QuartzCore
import SwiftUI

/// Plain AppKit editing retains IME, selection and Undo across draft saves.
struct NativeSettingsTextEditor: NSViewRepresentable {
    var interaction = NativeSettingsEditorInteraction()
    @Binding var value: String
    @Binding var height: CGFloat
    let minimumHeight: CGFloat
    let label: String
    let description: String?
    let invalid: Bool
    let activation: NativeSettingsFieldActivation?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeSettingsTextEditing) private var editing
    @Environment(\.nativeSettingsFormPage) private var formPage

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SettingsTextEditorContainer {
        let view = SettingsTextEditorContainer()
        view.editor.delegate = context.coordinator
        view.editor.compositionChanged = { [weak coordinator = context.coordinator, weak editor = view.editor] composing in
            guard let editor else { return }
            coordinator?.compositionChanged(composing, editor: editor)
        }
        view.editor.undoChanged = { [weak coordinator = context.coordinator, weak editor = view.editor] in
            guard let coordinator, let editor,
                  !coordinator.parent.value.utf16.elementsEqual(editor.string.utf16) else { return }
            coordinator.compositionChanged(editor.hasMarkedText(), editor: editor)
            coordinator.parent.value = editor.string
        }
        return view
    }
    func updateNSView(_ view: SettingsTextEditorContainer, context: Context) {
        context.coordinator.parent = self
        context.coordinator.installEditing(editing, editor: view.editor)
        if !view.editor.hasMarkedText(), !view.editor.string.utf16.elementsEqual(value.utf16) {
            view.editor.undoManager?.removeAllActions(withTarget: view.editor)
            view.editor.string = value
        }
        view.configure(enabled: enabled, invalid: invalid, minimumHeight: minimumHeight,
                       label: label, description: description, native: formPage) { height = $0 }
        view.installActivation(activation)
        view.updateInteraction = { [weak view] in
            guard let view else { return }
            interaction.install(view.interactionLease, editor: view.editor, label: label, value: value, invalid: invalid)
        }
        view.updateInteraction?()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsTextEditorContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: max(minimumHeight, height))
    }
    static func dismantleNSView(_ view: SettingsTextEditorContainer, coordinator: Coordinator) {
        coordinator.installEditing(nil, editor: view.editor)
        view.editor.compositionChanged = nil
        view.editor.undoChanged = nil; view.editor.tracksUndo = false
        view.installActivation(nil); view.interactionLease.remove(); view.updateInteraction = nil
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeSettingsTextEditor
        private weak var editing: NativeSettingsTextEditing?
        init(_ parent: NativeSettingsTextEditor) { self.parent = parent }
        func installEditing(_ next: NativeSettingsTextEditing?, editor: NSTextView) {
            guard editing !== next else { return }
            editing?.compositionChanged(false, editor: editor)
            editing = next
            if editor.window != nil { compositionChanged(editor.hasMarkedText(), editor: editor) }
        }
        func compositionChanged(_ composing: Bool, editor: NSTextView) {
            editing?.compositionChanged(composing, editor: editor)
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            compositionChanged(editor.hasMarkedText(), editor: editor)
            parent.value = editor.string
        }
        func textDidEndEditing(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            editing?.editingEnded(editor)
        }
    }
}

@MainActor final class SettingsTextEditorContainer: NSView {
    let editor = SettingsPlainTextView()
    let interactionLease = NativeSettingsControlLease()
    var updateInteraction: (() -> Void)?
    private let scroll = NativeStyledScrollView()
    private let grip = SettingsTextAreaGrip()
    private let border = CALayer()
    private var invalid = false
    private var enabled = true
    private var focused = false
    private var native = false
    private weak var activation: NativeSettingsFieldActivation?
    private let activationOwner = UUID()
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    init() {
        super.init(frame: .zero)
        focusRingType = .none; editor.focusRingType = .none
        wantsLayer = true; border.borderWidth = 1; border.cornerRadius = 7
        layer?.addSublayer(border)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        NativeScrollbarStyle.apply(to: scroll)
        scroll.contentView.drawsBackground = false
        editor.drawsBackground = false; editor.isRichText = false; editor.allowsUndo = true
        editor.font = NativeTypography.settingsNSFont(size: 13)
        editor.textColor = NativePlatformPalette.settings.text; editor.insertionPointColor = NativePlatformPalette.settings.text
        editor.textContainerInset = NSSize(width: 10, height: 7)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18.2; paragraph.maximumLineHeight = 18.2
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: NativeTypography.settingsNSFont(size: 13),
                                   .foregroundColor: NativePlatformPalette.settings.text, .paragraphStyle: paragraph]
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.focusChanged = { [weak self] focused in
            self?.focused = focused; self?.updateBorder(animated: true); self?.needsDisplay = true
        }
        scroll.documentView = editor
        addSubview(scroll); addSubview(grip)
    }
    required init?(coder: NSCoder) { nil }

    func installActivation(_ activation: NativeSettingsFieldActivation?) {
        self.activation?.remove(owner: activationOwner)
        self.activation = activation
        activation?.install(owner: activationOwner) { [weak self] in
            guard let self, enabled else { return }
            window?.makeFirstResponder(editor)
        }
    }

    func configure(enabled: Bool, invalid: Bool, minimumHeight: CGFloat, label: String,
                   description: String?, native: Bool, resize: @escaping (CGFloat) -> Void) {
        self.enabled = enabled; self.invalid = invalid
        self.native = native
        editor.tracksUndo = native
        border.isHidden = native; grip.isHidden = native
        scroll.borderType = native ? .bezelBorder : .noBorder
        scroll.focusRingType = native ? .exterior : .none
        scroll.drawsBackground = native; scroll.contentView.drawsBackground = native
        scroll.backgroundColor = .textBackgroundColor
        editor.drawsBackground = native; editor.backgroundColor = .textBackgroundColor
        alphaValue = enabled ? 1 : 0.5
        editor.isEditable = enabled; editor.isSelectable = enabled
        if !enabled, window?.firstResponder === editor { window?.makeFirstResponder(nil); focused = false }
        editor.setAccessibilityLabel(label); editor.setAccessibilityHelp(description)
        grip.enabled = enabled; grip.minimumHeight = minimumHeight; grip.resize = resize
        updateBorder(animated: window != nil); needsDisplay = true
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 1, dy: 1)
        grip.frame = CGRect(x: max(0, bounds.width - 13), y: max(0, bounds.height - 13), width: 12, height: 12)
        CATransaction.begin(); CATransaction.setDisableActions(true); border.frame = bounds; CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); updateBorder(animated: true); needsDisplay = true
        editor.textColor = NativePlatformPalette.settings.text; editor.insertionPointColor = NativePlatformPalette.settings.text
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); updateBorder(animated: false)
        if window == nil { interactionLease.remove() } else { updateInteraction?() }
    }
    private func updateBorder(animated: Bool) {
        guard !native else { return }
        var next: CGColor!
        effectiveAppearance.performAsCurrentDrawingAppearance {
            next = (invalid ? NativePlatformPalette.settings.danger : focused && enabled ? NativePlatformPalette.settings.accent : NativePlatformPalette.settings.inputBorder).cgColor
        }
        let previous = border.presentation()?.borderColor ?? border.borderColor
        guard previous.map({ !CFEqual($0, next) }) ?? true else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true); border.borderColor = next; CATransaction.commit()
        border.removeAnimation(forKey: "settingsBorder")
        if animated, let previous {
            let change = CABasicAnimation(keyPath: "borderColor")
            change.preferredFrameRateRange = NativeFrameRate.preferredRange
            change.fromValue = previous; change.toValue = next; change.duration = 0.12
            change.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            border.add(change, forKey: "settingsBorder")
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !native else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NativePlatformPalette.settings.input.setFill(); path.fill()
        if focused, enabled {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: -3.5, dy: -3.5), xRadius: 10.5, yRadius: 10.5)
            NativePlatformPalette.color(0x426b9a, alpha: 0.22).setStroke(); outline.lineWidth = 3; outline.stroke()
        }
    }
}

@MainActor final class SettingsPlainTextView: NSTextView {
    var focusChanged: ((Bool) -> Void)?
    var compositionChanged: ((Bool) -> Void)?
    var undoChanged: (() -> Void)?
    var tracksUndo = false { didSet { updateUndoObservation() } }
    private weak var observedUndoManager: UndoManager?
    private var undoObservers: [NSObjectProtocol] = []

    private func updateUndoObservation() {
        let manager = tracksUndo && window != nil ? undoManager : nil
        guard observedUndoManager !== manager else { return }
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = []; observedUndoManager = manager
        guard let manager else { return }
        // AppKit can undo the text storage without sending the text delegate a
        // change notification. Observe the window's manager only while mounted;
        // the adapter compares exact text before writing its binding.
        undoObservers = [Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: manager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.undoChanged?() }
            }
        }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Protect the draft before AppKit emits text-change delegates while
        // installing the first marked range, then report its resulting state.
        compositionChanged?(true)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        compositionChanged?(hasMarkedText())
    }
    override func unmarkText() {
        super.unmarkText()
        compositionChanged?(hasMarkedText())
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        compositionChanged?(hasMarkedText())
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateUndoObservation()
        compositionChanged?(window != nil && hasMarkedText())
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateUndoObservation()
        if accepted { focusChanged?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }
}

@MainActor private final class SettingsTextAreaGrip: NSView {
    var enabled = true
    var minimumHeight: CGFloat = 112
    var resize: ((CGFloat) -> Void)?
    private var initialY: CGFloat = 0
    private var initialHeight: CGFloat = 0
    override var isFlipped: Bool { true }
    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .resizeUpDown) } }
    override func draw(_ dirtyRect: NSRect) {
        NativePlatformPalette.settings.muted.withAlphaComponent(0.5).setStroke()
        for offset: CGFloat in [3, 6] {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: bounds.maxX - offset - 2, y: bounds.maxY - 2))
            path.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.maxY - offset - 2))
            path.lineWidth = 1; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        initialY = event.locationInWindow.y; initialHeight = superview?.bounds.height ?? minimumHeight
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled else { return }
        resize?(max(minimumHeight, initialHeight + initialY - event.locationInWindow.y))
    }
}
