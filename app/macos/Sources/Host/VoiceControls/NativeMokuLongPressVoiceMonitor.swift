import AppKit
import SwiftUI

/// `MOKUSEI_DIAG_LONG_PRESS=1` records why a mounted hold does or does not
/// begin. It is off by default and never feeds back into recognition, so the
/// trace stays inert in every other run.
enum NativeLongPressTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["MOKUSEI_DIAG_LONG_PRESS"] == "1"
    private static let origin = Date()

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print("LONGPRESS +\(String(format: "%.3f", Date().timeIntervalSince(origin)))s \(message())")
    }
}

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
            let enabled = isActive() && canStart()
            if let press, press.isEnabled != enabled { NativeLongPressTrace.log("update enabled=\(enabled)") }
            press?.isEnabled = enabled
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
            NativeLongPressTrace.log("installed enabled=\(press.isEnabled) active=\(isActive()) canStart=\(canStart()) key=\(window.isKeyWindow) appActive=\(NSApp.isActive)")
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        NativeLongPressTrace.log("resignKey state=\(self.press?.state.rawValue ?? -1)")
                        self.press?.isEnabled = false
                        self.press?.isEnabled = self.isActive() && self.canStart()
                        NativeLongPressTrace.log("resignKey re-enabled=\(self.press?.isEnabled ?? false)")
                    }
                }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { stop() }
            super.viewWillMove(toWindow: newWindow)
        }

        func stop() {
            if press != nil { NativeLongPressTrace.log("stop state=\(press?.state.rawValue ?? -1)") }
            if let press { press.view?.removeGestureRecognizer(press); self.press = nil }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
            let down = event.type == .leftMouseDown
            let sameWindow = event.window === window
            let single = event.clickCount == 1
            let plain = event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
            let visible = !isHiddenOrHasHiddenAncestor
            let active = isActive()
            let canStart = canStart()
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            let allowed = down && sameWindow && single && plain && visible && active && canStart && inside
            NativeLongPressTrace.log("attempt down=\(down) window=\(sameWindow) single=\(single) plain=\(plain)"
                + " visible=\(visible) active=\(active) canStart=\(canStart) inside=\(inside)"
                + " enabled=\(gestureRecognizer.isEnabled) state=\(gestureRecognizer.state.rawValue) -> \(allowed)")
            return allowed
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            let key = window?.isKeyWindow == true
            let app = NSApp.isActive
            let visible = !isHiddenOrHasHiddenAncestor
            let active = isActive()
            let canStart = canStart()
            let inside = bounds.contains(gestureRecognizer.location(in: self))
            let allowed = key && app && visible && active && canStart && inside
            NativeLongPressTrace.log("shouldBegin key=\(key) app=\(app) visible=\(visible) active=\(active)"
                + " canStart=\(canStart) inside=\(inside) -> \(allowed)")
            return allowed
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }

        @objc private func held(_ recognizer: NSPressGestureRecognizer) {
            NativeLongPressTrace.log("held state=\(recognizer.state.rawValue) active=\(isActive()) canStart=\(canStart())")
            guard recognizer.state == .began, isActive(), canStart() else { return }
            // Release belongs to the gesture, not the workspace media lifetime.
            start()
        }
    }
}
