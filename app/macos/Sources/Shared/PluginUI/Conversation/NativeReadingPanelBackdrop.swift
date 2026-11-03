import AppKit
import SwiftUI

/// Owns only the blank margin behind the front's controls. Panel contents and
/// Sidecard dividers never share an ancestor dismissal gesture with this view.
struct NativeReadingPanelBackdrop: NSViewRepresentable {
    let panel: CGRect
    let onDismiss: (() -> Void)?

    func makeNSView(context: Context) -> BackdropView { BackdropView() }
    func updateNSView(_ view: BackdropView, context: Context) {
        view.panel = panel; view.onDismiss = onDismiss
    }
    static func dismantleNSView(_ view: BackdropView, coordinator: ()) { view.dispose() }

    final class BackdropView: NSView {
        var panel = CGRect.zero
        var onDismiss: (() -> Void)?
        private var pressed = false
        private var blockedPress: TimeInterval?
        private var mouseMonitor: Any?
        private var popoverObserver: NSObjectProtocol?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { false }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard window != nil else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return }
                    if !self.canDismiss { self.blockedPress = event.timestamp }
                }
                return event
            }
            popoverObserver = NotificationCenter.default.addObserver(forName: NSPopover.willCloseNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let event = NSApp.currentEvent, event.window === self.window,
                          event.type == .leftMouseDown else { return }
                    // AppKit can close the child window before delivering the
                    // forwarded press to this view or its local event monitor.
                    self.blockedPress = event.timestamp
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return onDismiss != nil && bounds.contains(local) && !panel.contains(local) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            // A transient picker may forward its dismissing click to the owner.
            // That press must not also retire the reading route beneath it.
            pressed = canDismiss && blockedPress != event.timestamp
        }
        override func mouseDragged(with event: NSEvent) { pressed = false }
        override func mouseUp(with event: NSEvent) {
            let accepted = pressed
            pressed = false
            let point = convert(event.locationInWindow, from: nil)
            if accepted && canDismiss && bounds.contains(point) && !panel.contains(point) { onDismiss?() }
        }
        private var canDismiss: Bool {
            guard let window else { return false }
            return onDismiss != nil && !isHiddenOrHasHiddenAncestor && window.attachedSheet == nil
                && NSApp.modalWindow == nil && !(window.childWindows ?? []).contains { $0.isVisible }
        }
        private func removeObservers() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
            if let popoverObserver { NotificationCenter.default.removeObserver(popoverObserver); self.popoverObserver = nil }
            pressed = false; blockedPress = nil
        }
        func dispose() { onDismiss = nil; removeObservers() }
    }
}
