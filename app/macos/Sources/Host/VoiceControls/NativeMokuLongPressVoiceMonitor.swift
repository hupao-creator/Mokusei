import AppKit
import SwiftUI

/// A passive observer over only the editor, so attachment/send controls and
/// native text selection retain their ordinary mouse-down ownership.
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

    @MainActor final class MonitorView: NSView {
        private var monitor: Any?
        private var timer: Timer?
        private var origin: CGPoint?
        private var deadline: TimeInterval = 0
        private var isActive: () -> Bool = { false }
        private var canStart: () -> Bool = { false }
        private var start: () -> Void = {}

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(isActive: @escaping () -> Bool, canStart: @escaping () -> Bool, start: @escaping () -> Void) {
            self.isActive = isActive; self.canStart = canStart; self.start = start
            if !isActive() || !canStart() { cancelPress() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.receive(event) }
                return event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { stop() }
            super.viewWillMove(toWindow: newWindow)
        }

        func stop() {
            cancelPress()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }

        private func cancelPress() {
            timer?.invalidate(); timer = nil; origin = nil
        }

        func receive(_ event: NSEvent) {
            switch event.type {
            case .leftMouseDown:
                cancelPress()
                guard event.window === window, event.clickCount == 1,
                      event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty,
                      !isHiddenOrHasHiddenAncestor, isActive(), canStart(),
                      visibleRect.contains(convert(event.locationInWindow, from: nil)),
                      let window else { return }
                origin = window.convertPoint(toScreen: event.locationInWindow)
                deadline = ProcessInfo.processInfo.systemUptime + 0.5
                // NSTextView can run a nested tracking loop during mouseDown.
                // Sampling in both modes catches movement/release even when that
                // loop takes events before the local event monitor sees them.
                let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.sample(at: NSEvent.mouseLocation, pressed: NSEvent.pressedMouseButtons & 1 != 0,
                            now: ProcessInfo.processInfo.systemUptime)
                    }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .eventTracking)
            case .leftMouseDragged:
                cancelPress()
            case .leftMouseUp, .keyDown, .scrollWheel:
                cancelPress()
            default: break
            }
        }

        func sample(at point: CGPoint, pressed: Bool, now: TimeInterval) {
            guard let origin else { return }
            guard pressed, let window, window.isKeyWindow, NSApp.isActive,
                  !isHiddenOrHasHiddenAncestor, isActive(), canStart(),
                  hypot(point.x - origin.x, point.y - origin.y) <= 4,
                  visibleRect.contains(convert(window.convertPoint(fromScreen: point), from: nil)) else {
                cancelPress(); return
            }
            guard now >= deadline else { return }
            // Clear before starting: presentation can synchronously retire this
            // editor. Release never stops the workspace-owned voice session.
            cancelPress()
            start()
        }
    }
}
