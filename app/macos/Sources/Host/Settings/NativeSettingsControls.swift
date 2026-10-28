import AppKit
import MokuseiPluginUI
import SwiftUI

// Keep the settings shell on the same primitives as contributed Harness forms.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var description: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View { NativeSettingsGroup(title: title, description: description, content: content) }
}

struct SettingsRow<Content: View>: View {
    var label: String
    var description: String? = nil
    var error: String? = nil
    var stacked = false
    var inlineControl = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        NativeSettingsRow(label: label, description: description, error: error, layout: stacked ? .stacked : .inline,
                          inlineControl: inlineControl, content: content)
    }
}

struct SettingsNotice<Content: View>: View {
    var error = false
    var text: String
    @ViewBuilder var actions: () -> Content
    init(_ text: String, error: Bool = false, @ViewBuilder actions: @escaping () -> Content = { EmptyView() }) {
        self.text = text; self.error = error; self.actions = actions
    }
    var body: some View {
        NativeSettingsNotice(message: text, kind: error ? .error : .info,
                             action: Content.self == EmptyView.self ? nil : AnyView(actions()))
            .accessibilityElement(children: .contain)
    }
}

struct SettingsAgentParagraph: ViewModifier {
    var error = false
    func body(content: Content) -> some View {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 12))
        let extra = max(0, 19.2 - lineHeight)
        content.font(.system(size: 12)).lineSpacing(extra).padding(.vertical, extra / 2)
            .foregroundStyle(error ? NativeAppKitPalette.pair(0xac583e, 0xefa47e).swiftUI : NativeAppKitPalette.settings.muted.swiftUI)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Keep programmatic entry focus without presenting it as keyboard navigation.
struct SettingsNavigationFocusRing: ViewModifier {
    let visible: Bool
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content.focusEffectDisabled().overlay {
            if visible && enabled {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(NativeAppKitPalette.settings.accent.swiftUI, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct SettingsSpinner: View {
    var size: CGFloat = 14
    var body: some View {
        ProgressView().controlSize(.small).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// AppKit's editing delegate is needed for IME composition: marked text must not
/// be sent to persistence or permit a page dismissal midway through composition.
struct SettingsTextArea: NSViewRepresentable {
    var interaction = NativeSettingsEditorInteraction()
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.nativeSettingsFieldActivation) private var fieldActivation
    @Environment(\.nativeSettingsTextEditing) private var editing
    @Binding var text: String
    var accessibilityLabel: String
    var placeholder: String? = nil
    var invalid = false
    var focusRequest = 0
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Surface()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        NativeScrollbarStyle.apply(to: scroll); scroll.borderType = .bezelBorder
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        scroll.contentInsets = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        scroll.focusRingType = .exterior
        let view = Editor()
        view.drawsBackground = true; view.allowsUndo = true
        view.isRichText = false; view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.font = .systemFont(ofSize: 13); view.textColor = NativeAppKitPalette.settings.text
        view.insertionPointColor = NativeAppKitPalette.settings.text
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 10, height: 7)
        view.textContainer?.lineFragmentPadding = 0
        let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 18.2; paragraph.maximumLineHeight = 18.2
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NativeAppKitPalette.settings.text, .paragraphStyle: paragraph]
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.minSize = NSSize(width: 0, height: 0); view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        view.compositionChanged = { [weak coordinator = context.coordinator, weak view] composing in
            guard let view else { return }
            coordinator?.compositionChanged(composing, editor: view)
        }
        view.escape = { [weak coordinator = context.coordinator] in coordinator?.parent.onEscape() }
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? Editor else { return }
        context.coordinator.installEditing(editing, editor: view)
        view.setAccessibilityLabel(accessibilityLabel)
        view.placeholder = placeholder
        view.isEditable = isEnabled; view.isSelectable = isEnabled
        context.coordinator.installActivation(fieldActivation, editor: view)
        if !view.hasMarkedText(), !view.string.utf16.elementsEqual(text.utf16) {
            // External replacements start a new editing history; stale native
            // undo ranges must never be applied to a different document.
            view.undoManager?.removeAllActions(withTarget: view)
            view.string = text
        }
        scroll.alphaValue = isEnabled ? 1 : 0.5
        if let surface = scroll as? Surface {
            surface.updateInteraction = { [weak surface, weak view] in
                guard let surface, let view else { return }
                interaction.install(surface.interactionLease, editor: view, label: accessibilityLabel, value: text, invalid: invalid)
            }
            surface.updateInteraction?()
        }
        if focusRequest != context.coordinator.lastFocus {
            context.coordinator.lastFocus = focusRequest
            if focusRequest > 0 { DispatchQueue.main.async { [weak view] in if let view { view.window?.makeFirstResponder(view) } } }
        }
    }
    final class Surface: NativeStyledScrollView {
        let interactionLease = NativeSettingsControlLease()
        var updateInteraction: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { interactionLease.remove() } else { updateInteraction?() }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.removeActivation()
        if let view = scroll.documentView as? Editor {
            coordinator.installEditing(nil, editor: view)
            view.compositionChanged = nil
        }
        (scroll as? Surface)?.interactionLease.remove(); (scroll as? Surface)?.updateInteraction = nil
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SettingsTextArea
        var lastFocus = 0
        private weak var activation: NativeSettingsFieldActivation?
        private weak var editing: NativeSettingsTextEditing?
        private let activationOwner = UUID()
        init(_ parent: SettingsTextArea) { self.parent = parent }
        func installActivation(_ next: NativeSettingsFieldActivation?, editor: NSTextView) {
            removeActivation(); activation = next
            next?.install(owner: activationOwner) { [weak editor] in
                guard let editor, editor.isEditable else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
        func removeActivation() { activation?.remove(owner: activationOwner); activation = nil }
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
            guard let view = notification.object as? NSTextView else { return }
            compositionChanged(view.hasMarkedText(), editor: view); parent.text = view.string
        }
        func textDidEndEditing(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            editing?.editingEnded(view)
        }
    }
    final class Editor: NSTextView {
        var compositionChanged: ((Bool) -> Void)?
        var escape: (() -> Void)?
        var placeholder: String? { didSet { if oldValue != placeholder { needsDisplay = true } } }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !hasMarkedText(), let placeholder else { return }
            let text = NSAttributedString(string: placeholder, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NativeAppKitPalette.settings.muted.withAlphaComponent(0.7)
            ])
            text.draw(in: CGRect(x: textContainerInset.width, y: textContainerInset.height,
                                 width: max(0, bounds.width - 2 * textContainerInset.width), height: max(0, bounds.height - 2 * textContainerInset.height)))
        }
        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            compositionChanged?(true)
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            compositionChanged?(hasMarkedText())
        }
        override func unmarkText() { super.unmarkText(); compositionChanged?(hasMarkedText()) }
        override func insertText(_ string: Any, replacementRange: NSRange) {
            super.insertText(string, replacementRange: replacementRange)
            compositionChanged?(hasMarkedText())
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            compositionChanged?(window != nil && hasMarkedText())
        }
        override func cancelOperation(_ sender: Any?) {
            if hasMarkedText() { super.cancelOperation(sender) } else { escape?() }
        }
    }
}
