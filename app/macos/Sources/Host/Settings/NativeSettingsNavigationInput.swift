import SwiftUI
import AppKit

/// Observe input without adding a focus target or intercepting the controls.
/// FocusState alone cannot distinguish page entry from Tab/arrow navigation.
struct SettingsNavigationInputObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> InputView { InputView(onChange: onChange) }
    func updateNSView(_ view: InputView, context: Context) { view.onChange = onChange }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.dispose() }

    @MainActor final class InputView: NSView {
        var onChange: (Bool) -> Void
        private var monitor: Any?
        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            dispose()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          !self.isHiddenOrHasHiddenAncestor else { return }
                    if event.type != .keyDown { self.onChange(false) }
                    else if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                            [36, 48, 49, 76, 115, 119, 123, 124, 125, 126].contains(event.keyCode) {
                        // Return, Tab, Space, Home/End and the arrow keys.
                        self.onChange(true)
                    }
                }
                return event
            }
        }
        func dispose() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}
