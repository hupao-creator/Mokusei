import AppKit
import SwiftUI

/// The native recognizer observes the editor without taking its hit testing.
struct NativeMokuLongPressVoiceMonitor: NSViewRepresentable {
    var isActive: () -> Bool
    var canStart: () -> Bool
    var start: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.update(isActive: isActive, canStart: canStart, start: start)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.update(isActive: isActive, canStart: canStart, start: start)
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    @MainActor final class MonitorView: NSView, NSGestureRecognizerDelegate {
        private var press: NSPressGestureRecognizer?
        private var resignObserver: NSObjectProtocol?
        private var isActive: () -> Bool = { false }
        private var canStart: () -> Bool = { false }
        private var start: () -> Void = {}

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(isActive: @escaping () -> Bool, canStart: @escaping () -> Bool, start: @escaping () -> Void) {
            self.isActive = isActive; self.canStart = canStart; self.start = start
            press?.isEnabled = isActive() && canStart()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window, let content = window.contentView else { return }
            let press = NSPressGestureRecognizer(target: self, action: #selector(held(_:)))
            press.minimumPressDuration = 0.5
            press.allowableMovement = 4
            press.buttonMask = 1
            // Keep AppKit's press delay: a short click or drag fails the
            // recognizer and forwards the original events to the text editor.
            // Otherwise NSTextView can consume drag/release in its nested
            // selection loop before the recognizer can cancel the hold.
            press.delegate = self
            press.isEnabled = isActive() && canStart()
            content.addGestureRecognizer(press)
            self.press = press
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.press?.isEnabled = false
                        self.press?.isEnabled = self.isActive() && self.canStart()
                    }
                }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { stop() }
            super.viewWillMove(toWindow: newWindow)
        }

        func stop() {
            if let press { press.view?.removeGestureRecognizer(press); self.press = nil }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
            event.type == .leftMouseDown && event.window === window && event.clickCount == 1
                && event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
                && !isHiddenOrHasHiddenAncestor && isActive() && canStart()
                && bounds.contains(convert(event.locationInWindow, from: nil))
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            window?.isKeyWindow == true && NSApp.isActive && !isHiddenOrHasHiddenAncestor
                && isActive() && canStart() && bounds.contains(gestureRecognizer.location(in: self))
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }

        @objc private func held(_ recognizer: NSPressGestureRecognizer) {
            guard recognizer.state == .began, isActive(), canStart() else { return }
            // Release belongs to the gesture, not the workspace media lifetime.
            start()
        }
    }
}
