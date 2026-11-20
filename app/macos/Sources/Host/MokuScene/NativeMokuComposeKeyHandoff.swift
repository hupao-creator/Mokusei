import AppKit

/// Keeps ordinary typing ordered while an explicit Compose opening attaches
/// its native editor. All events stay in the shortcut's original key window.
@MainActor final class NativeMokuComposeKeyHandoff {
    let key: Int
    private weak var window: NSWindow?
    private weak var editor: NSTextView?
    private var monitor: Any?
    private var keyObserver: NSObjectProtocol?
    private var events: [NSEvent] = []

    init?(key: Int) {
        guard NSApp.currentEvent?.type == .keyDown, NSApp.isActive, NSApp.modalWindow == nil, let window = NSApp.keyWindow,
              window.firstResponder === window, window.attachedSheet == nil else { return nil }
        self.key = key
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] event in
            let held = MainActor.assumeIsolated { self?.hold(event) == true }
            return held ? nil : event
        }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
    }

    isolated deinit { cancel() }

    private func hold(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
              window.firstResponder === window || window.firstResponder === editor,
              event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
              }), events.count < 64 else {
            cancel()
            return false
        }
        events.append(event)
        return true
    }

    func focused(_ editor: NSTextView) {
        guard monitor != nil, let window, editor.window === window else { return }
        self.editor = editor
        // The focus request can resolve inside updateNSView. Deliver after
        // that update so ordinary key handling can write the SwiftUI draft.
        DispatchQueue.main.async { [weak self, weak editor, weak window] in
            guard let self, let window, let editor, window.isKeyWindow,
                  window.attachedSheet == nil, window.firstResponder === editor else {
                self?.cancel()
                return
            }
            let events = self.events
            cancel()
            for event in events where window.isKeyWindow && window.firstResponder === editor {
                window.sendEvent(event)
            }
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver); self.keyObserver = nil }
        events.removeAll()
    }
}
