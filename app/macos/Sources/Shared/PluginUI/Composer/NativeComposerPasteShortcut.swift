import AppKit
import SwiftUI

/// NSTextView consumes paste before SwiftUI's onPasteCommand/onKeyPress.
/// Intercept only attachment shortcuts over this editor, leaving native text
/// editing and marked text with the system's input context.
struct NativeComposerPasteShortcut: NSViewRepresentable {
    var enabled: Bool
    var onPaste: ([NSItemProvider], NSRange) -> Void

    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }
    func updateNSView(_ view: ShortcutView, context: Context) {
        view.enabled = enabled; view.onPaste = onPaste
    }
    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.detach() }

    final class ShortcutView: NSView {
        var enabled = false
        var onPaste: (([NSItemProvider], NSRange) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) == true }
                return handled ? nil : event
            }
        }
        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        private func handle(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard enabled, !isHiddenOrHasHiddenAncestor, event.window === window,
                  modifiers == .command || modifiers == .control,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let editor = window?.firstResponder as? NSTextView,
                  editor.isEditable, !editor.hasMarkedText() else { return false }
            guard owns(editor) else { return false }
            let providers = NativeComposerPaste.attachmentProviders(from: .general)
            guard !providers.isEmpty, let onPaste else { return false }
            onPaste(providers, editor.selectedRange())
            return true
        }
        private func owns(_ editor: NSTextView) -> Bool {
            // Find the editor in the nearest shared native container. Geometry
            // alone would also claim an unrelated editor overlaying Moku.
            func candidate(in view: NSView) -> NSTextView? {
                if let text = view as? NSTextView {
                    let viewport = text.enclosingScrollView ?? text
                    let center = NSPoint(x: viewport.bounds.midX, y: viewport.bounds.midY)
                    return bounds.contains(convert(center, from: viewport)) ? text : nil
                }
                return view.subviews.lazy.compactMap { candidate(in: $0) }.first
            }
            var container = superview
            while let view = container {
                if let text = candidate(in: view) { return text === editor }
                container = view.superview
            }
            return false
        }
    }
}
