import SwiftUI
import AppKit

/// The source settings page owns Escape at document scope. Native text editors
/// and popup menus keep their own composing/tracking cancellation first.
struct NativeSettingsEscapeHandler: NSViewRepresentable {
    let close: () -> Void
    func makeNSView(context: Context) -> EscapeView { EscapeView(close: close) }
    func updateNSView(_ nsView: EscapeView, context: Context) { nsView.close = close }
    static func dismantleNSView(_ nsView: EscapeView, coordinator: ()) { nsView.dispose() }

    @MainActor final class EscapeView: NSView {
        var close: () -> Void
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var menus = Set<ObjectIdentifier>()
        init(close: @escaping () -> Void) {
            self.close = close
            super.init(frame: .zero)
            setAccessibilityElement(false)
            for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let menu = note.object as? NSMenu else { return }
                    let identity = ObjectIdentifier(menu), began = name == NSMenu.didBeginTrackingNotification
                    MainActor.assumeIsolated {
                        if began { self?.menus.insert(identity) }
                        else { self?.menus.remove(identity) }
                    }
                })
            }
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor,
                          event.keyCode == 53, self.menus.isEmpty,
                          (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
                    self.close()
                    return true
                }
                return handled ? nil : event
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func dispose() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll(); menus.removeAll()
        }
    }
}
