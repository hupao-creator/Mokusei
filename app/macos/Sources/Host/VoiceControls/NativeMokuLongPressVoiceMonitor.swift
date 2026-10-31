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
        /// The hold threshold the user is promised. The timer, not AppKit's
        /// press recognizer, enforces it.
        private static let pressDuration: TimeInterval = 0.5
        private static let allowableMovement: CGFloat = 4

        private var press: NSPressGestureRecognizer?
        private var resignObserver: NSObjectProtocol?
        private var eventMonitor: Any?
        private var deadline: Timer?
        private var downPoint: NSPoint?
        private var started = false
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
            if !enabled { cancelHold() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window, let content = window.contentView else { return }
            let press = NSPressGestureRecognizer(target: self, action: #selector(held(_:)))
            press.minimumPressDuration = Self.pressDuration
            press.allowableMovement = Self.allowableMovement
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
            // The recognizer only cancels. Its own press timer shares the run
            // loop with the editor's nested selection loop and began 263-393ms
            // after its threshold on the hosted runner, so a release could win
            // the race and the hold silently did nothing. These events are
            // monitored so this view can own the deadline itself.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.observe(event) }
                return event
            }
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        NativeLongPressTrace.log("resignKey state=\(self.press?.state.rawValue ?? -1)")
                        self.cancelHold()
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
            cancelHold()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
            if let press { press.view?.removeGestureRecognizer(press); self.press = nil }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        }

        /// Owns the hold deadline. The local monitor sees the press and release
        /// even while the editor is inside its nested selection loop, which is
        /// what starves `NSPressGestureRecognizer`'s internal timer.
        private func observe(_ event: NSEvent) {
            guard event.window === window, isActive(), canStart(), !isHiddenOrHasHiddenAncestor else {
                cancelHold()
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                guard event.clickCount == 1, window?.isKeyWindow == true, NSApp.isActive,
                      bounds.contains(point),
                      event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
                else { return }
                arm(at: point)
            case .leftMouseDragged:
                guard let downPoint,
                      hypot(point.x - downPoint.x, point.y - downPoint.y) <= Self.allowableMovement
                else { cancelHold(); return }
            case .leftMouseUp:
                cancelHold()
            default:
                break
            }
        }

        private func arm(at point: NSPoint) {
            cancelHold()
            downPoint = point
            started = false
            let timer = Timer(timeInterval: Self.pressDuration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire() }
            }
            // The editor's nested loop only services `.eventTracking`, and it owns
            // the run loop for the whole press. A default-mode timer would fire
            // long after a 0.5s hold already released.
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
            deadline = timer
            NativeLongPressTrace.log("armed session")
        }

        private func fire() {
            deadline = nil
            guard !started, isActive(), canStart() else { return }
            started = true
            NativeLongPressTrace.log("deadline fired")
            // Release belongs to the gesture, not the workspace media lifetime.
            start()
        }

        private func cancelHold() {
            if deadline != nil { NativeLongPressTrace.log("cancelled") }
            deadline?.invalidate(); deadline = nil
            downPoint = nil
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
            // The deadline timer owns the trigger, so a `.began` that lands after
            // the release has already fired it must not start the entry twice.
            if recognizer.state != .began { cancelHold() }
        }
    }
}
