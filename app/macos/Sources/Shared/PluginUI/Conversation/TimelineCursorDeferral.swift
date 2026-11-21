import AppKit

/// Defer cursor-rectangle rebuilding while scrolling with a stationary pointer.
/// Native views keep ownership of drawing, selection and accessibility.
@MainActor
final class TimelineCursorDeferral: NSObject {
    private static let deferCursorRects = ProcessInfo.processInfo.environment["CHIEF_SCROLL_DEFER_CURSOR_RECTS"] != "0"
    private weak var cursorWindow: NSWindow?
    private var cursorInputMonitor: Any?
    private weak var scroll: NSScrollView?
    private var isScrolling = false
    private var enabled = true

    func attach(to scroll: NSScrollView?, enabled: Bool) {
        if !enabled { finish() }
        if cursorWindow !== scroll?.window { restoreCursorRects() }
        self.enabled = enabled
        guard self.scroll !== scroll else { return }
        detach()
        self.scroll = scroll
        guard let scroll, let window = scroll.window else { return }
        let center = NotificationCenter.default
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
            center.addObserver(self, selector: #selector(liveScroll), name: name, object: scroll)
        }
        center.addObserver(self, selector: #selector(finish), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeBackingPropertiesNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.willMiniaturizeNotification, NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(finish), name: name, object: window)
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            center.addObserver(self, selector: #selector(finish), name: name, object: NSApp)
        }
        if Self.deferCursorRects {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willBeginSheetNotification] {
                center.addObserver(self, selector: #selector(restoreCursorRects), name: name, object: window)
            }
        }
    }

    func detach() {
        finish()
        NotificationCenter.default.removeObserver(self)
        scroll = nil
    }

    @objc private func liveScroll(_ notification: Notification) {
        guard enabled else { return }
        if !isScrolling || notification.name == NSScrollView.willStartLiveScrollNotification {
            finish()
            isScrolling = true
            if Self.deferCursorRects, let window = scroll?.window,
               window.areCursorRectsEnabled, NSEvent.pressedMouseButtons == 0 {
                cursorWindow = window
                window.disableCursorRects()
                cursorInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved,
                    .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp,
                    .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                    .keyDown, .keyUp, .flagsChanged, .magnify, .rotate]) { [weak self] event in
                    MainActor.assumeIsolated { self?.restoreCursorRects() }
                    return event
                }
            }
        }
    }

    @objc private func restoreCursorRects() {
        if let monitor = cursorInputMonitor { NSEvent.removeMonitor(monitor); cursorInputMonitor = nil }
        guard let window = cursorWindow else { return }
        cursorWindow = nil
        window.enableCursorRects()
        if window.areCursorRectsEnabled { window.resetCursorRects() }
    }

    @objc private func finish() {
        isScrolling = false
        restoreCursorRects()
    }

    isolated deinit {
        finish()
        NotificationCenter.default.removeObserver(self)
    }
}
