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

struct SettingsTextButton: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(NativeTypography.settings(size: 11, weight: 580)).padding(.horizontal, 13).frame(height: 32)
            .foregroundStyle(hovered ? NativeAppKitPalette.overview.ink.swiftUI : NativeAppKitPalette.overview.muted.swiftUI)
            .background(hovered ? NativeAppKitPalette.pair(0x20211e, 0xe0e5da, alpha: 0.05).swiftUI : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
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

struct SettingsActionButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var danger = false
    var confirming = false
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        let filled = danger && (confirming || (hovered && enabled))
        configuration.label.font(NativeTypography.settings(size: 12, weight: danger ? 580 : 400)).padding(.horizontal, danger ? 13 : 12).frame(minHeight: 32)
            .foregroundStyle(filled ? NativeAppKitPalette.pair(0xffffff, 0x20211f).swiftUI : danger ? NativeAppKitPalette.overview.danger.swiftUI : NativeAppKitPalette.settings.text.swiftUI)
            .background(filled ? NativeAppKitPalette.overview.danger.swiftUI : danger ? NativeAppKitPalette.pair(0xfbf4f3, 0x38332f).swiftUI : NativeAppKitPalette.settings.input.swiftUI, in: RoundedRectangle(cornerRadius: danger ? 8 : 6))
            .overlay(RoundedRectangle(cornerRadius: danger ? 8 : 6).stroke(filled ? NativeAppKitPalette.overview.danger.swiftUI : danger ? NativeAppKitPalette.pair(0xd0a9a1, 0x85675e).swiftUI : NativeAppKitPalette.settings.inputBorder.swiftUI))
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }
}

struct SettingsSpinner: View {
    var icon = "LoaderCircle"
    var size: CGFloat = 14
    var body: some View {
        TimelineView(.animation(minimumInterval: NativeFrameRate.interval)) { clock in
            NativeIcon(name: icon, size: size, strokeWidth: 2)
                .rotationEffect(.degrees(clock.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360))
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct SettingsTextAreaResizeGrip: View {
    var body: some View {
        Canvas { context, _ in
            for inset in [CGFloat(4), 7, 10] {
                var line = Path(); line.move(to: CGPoint(x: inset, y: 12)); line.addLine(to: CGPoint(x: 12, y: inset))
                context.stroke(line, with: .color(NativeAppKitPalette.settings.muted.swiftUI.opacity(0.5)), lineWidth: 1)
            }
        }.frame(width: 14, height: 14).contentShape(Rectangle()).accessibilityHidden(true)
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
        scroll.scrollerStyle = .overlay; scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        scroll.focusRingType = .none
        let view = Editor()
        view.drawsBackground = false; view.focusRingType = .none; view.allowsUndo = true
        view.isRichText = false; view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.font = .systemFont(ofSize: 13); view.textColor = NativeAppKitPalette.settings.text
        view.insertionPointColor = NativeAppKitPalette.settings.text
        view.backgroundColor = NativeAppKitPalette.settings.input
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
        view.focusChanged = { [weak scroll] focused in scroll?.focused = focused }
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
        if !view.hasMarkedText(), view.string != text { view.string = text }
        scroll.alphaValue = isEnabled ? 1 : 0.5
        (scroll as? Surface)?.invalid = invalid
        (scroll as? Surface)?.enabled = isEnabled
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
    final class Surface: NSScrollView {
        let interactionLease = NativeSettingsControlLease()
        var updateInteraction: (() -> Void)?
        private let border = CALayer()
        var invalid = false { didSet { updateBorder(animated: window != nil); needsDisplay = true } }
        var enabled = true { didSet { updateBorder(animated: window != nil); needsDisplay = true } }
        var focused = false { didSet { updateBorder(animated: window != nil); needsDisplay = true } }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true; border.cornerRadius = 7; border.borderWidth = 1; layer?.addSublayer(border)
        }
        required init?(coder: NSCoder) { nil }
        override var wantsDefaultClipping: Bool { false }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true); border.frame = bounds; CATransaction.commit()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); updateBorder(animated: false)
            if window == nil { interactionLease.remove() } else { updateInteraction?() }
        }
        private func updateBorder(animated: Bool) {
            var next: CGColor!
            effectiveAppearance.performAsCurrentDrawingAppearance {
                next = (invalid ? NativeAppKitPalette.settings.danger : focused && enabled ? NativeAppKitPalette.settings.accent : NativeAppKitPalette.settings.inputBorder).cgColor
            }
            let previous = border.presentation()?.borderColor ?? border.borderColor
            guard previous.map({ !CFEqual($0, next) }) ?? true else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true); border.borderColor = next; CATransaction.commit()
            border.removeAnimation(forKey: "settingsBorder")
            if animated, let previous {
                let animation = CABasicAnimation(keyPath: "borderColor")
                animation.preferredFrameRateRange = NativeFrameRate.preferredRange
                animation.fromValue = previous; animation.toValue = next; animation.duration = 0.12
                animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                border.add(animation, forKey: "settingsBorder")
            }
        }
        override func draw(_ dirtyRect: NSRect) {
            let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NativeAppKitPalette.settings.input.setFill(); background.fill()
            super.draw(dirtyRect)
            if focused && enabled {
                let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: -3.5, dy: -3.5), xRadius: 10.5, yRadius: 10.5)
                NativeAppKitPalette.color(0x426b9a, alpha: 0.22).setStroke(); outline.lineWidth = 3; outline.stroke()
            }
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance(); updateBorder(animated: true); needsDisplay = true
            if let editor = documentView as? NSTextView {
                editor.textColor = NativeAppKitPalette.settings.text; editor.insertionPointColor = NativeAppKitPalette.settings.text
            }
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
        var focusChanged: ((Bool) -> Void)?
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
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { focusChanged?(true) }
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { focusChanged?(false) }
            return accepted
        }
    }
}
