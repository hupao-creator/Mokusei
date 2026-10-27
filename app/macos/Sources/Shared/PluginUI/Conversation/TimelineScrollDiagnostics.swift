import AppKit
import MokuseiCore

/// Observe native scrolling and defer cursor-rectangle rebuilding while the
/// pointer stays still. Restore cursor handling immediately for pointer/keyboard
/// input, focus changes and scroll completion.
/// Native views own drawing, scrolling, selection and accessibility; the window
/// owns its refresh-rate request. In particular, never snapshot and upload the
/// entire viewport on a competing main-run-loop display link while it scrolls.
@MainActor
final class TimelineScrollDiagnostics: NSObject {
    private static let deferCursorRects = ProcessInfo.processInfo.environment["MOKUSEI_SCROLL_DEFER_CURSOR_RECTS"] != "0"
    private enum CursorRestoreReason: Int {
        case input = 1, completed, cancelled, attachment, resignedKey, sheet
        case contextChanged, disabled, detached, deinitialized, newGesture
    }
    private var cursorDeferredAt: UInt64?
    private weak var cursorWindow: NSWindow?
    private var cursorInputMonitor: Any?
    private weak var scroll: NSScrollView?
    private var isScrolling = false
    private var enabled = true
    private var lastOrigin = NSPoint.zero
    private var context: UInt64?
    private var gesture: NativePerformanceSpan?

    func attach(to scroll: NSScrollView?, enabled: Bool, context: UInt64? = nil) {
        if self.context != context || !enabled {
            finish(.cancelled, cursorReason: enabled ? .contextChanged : .disabled)
        }
        if cursorWindow !== scroll?.window { restoreCursorRects(reason: .attachment) }
        self.context = context
        self.enabled = enabled
        guard self.scroll !== scroll else { return }
        detach()
        self.scroll = scroll
        guard let scroll, let window = scroll.window else { return }
        lastOrigin = scroll.contentView.bounds.origin
        let center = NotificationCenter.default
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
            center.addObserver(self, selector: #selector(liveScroll), name: name, object: scroll)
        }
        center.addObserver(self, selector: #selector(endGesture), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        NativePerformance.event(.display, context: context, values: [
            "width": Double(scroll.contentView.bounds.width), "height": Double(scroll.contentView.bounds.height),
            "scale": Double(window.backingScaleFactor), "maximumHz": Double(window.screen?.maximumFramesPerSecond ?? 0)])
        scroll.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeBackingPropertiesNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.willMiniaturizeNotification, NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(cancel), name: name, object: window)
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            center.addObserver(self, selector: #selector(cancel), name: name, object: NSApp)
        }
        if Self.deferCursorRects {
            // Cursor-only cancellation keeps the existing gesture span scope.
            for name in [NSWindow.didResignKeyNotification, NSWindow.willBeginSheetNotification] {
                center.addObserver(self, selector: #selector(cursorWindowChanged), name: name, object: window)
            }
        }
    }

    func detach() {
        finish(.cancelled, cursorReason: .detached)
        NotificationCenter.default.removeObserver(self)
        scroll = nil
    }

    @objc private func liveScroll(_ notification: Notification) {
        guard enabled else { return }
        if !isScrolling || notification.name == NSScrollView.willStartLiveScrollNotification {
            finish(.cancelled, cursorReason: .newGesture)
            isScrolling = true
            gesture = NativePerformance.begin(.scrollGesture, context: context)
            if Self.deferCursorRects, let window = scroll?.window,
               window.areCursorRectsEnabled, NSEvent.pressedMouseButtons == 0 {
                cursorWindow = window
                cursorDeferredAt = NativePerformance.mode == .detailed ? NativePerformance.now() : nil
                window.disableCursorRects()
                recordCursorDeferral(phase: 1, reason: 0, windowNumber: window.windowNumber)
                cursorInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved,
                    .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp,
                    .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                    .keyDown, .keyUp, .flagsChanged, .magnify, .rotate]) { [weak self] event in
                    MainActor.assumeIsolated { self?.restoreCursorRects(reason: .input, event: event) }
                    return event
                }
            }
        }
    }

    @objc private func boundsChanged(_ notification: Notification) {
        guard let scroll, scroll.contentView.bounds.origin != lastOrigin else { return }
        lastOrigin = scroll.contentView.bounds.origin
        NativePerformance.event(.scrollGeometry, context: gesture?.id ?? context, values: [
            "x": Double(lastOrigin.x), "y": Double(lastOrigin.y),
            "viewport": Double(scroll.contentView.bounds.height), "document": Double(scroll.documentView?.bounds.height ?? 0)])
    }

    @objc private func endGesture(_ notification: Notification) { finish(.completed, cursorReason: .completed) }
    @objc private func cancel(_ notification: Notification) { finish(.cancelled) }
    @objc private func cursorWindowChanged(_ notification: Notification) {
        restoreCursorRects(reason: notification.name == NSWindow.willBeginSheetNotification ? .sheet : .resignedKey)
    }

    private func recordCursorDeferral(phase: Double, reason: Int, windowNumber: Int,
                                     deferredMs: Double = 0, restoreMs: Double = 0,
                                     hasStart: Bool = true, event: NSEvent? = nil) {
        guard NativePerformance.mode == .detailed else { return }
        // phase: 1 began, 2 restored. Restore reasons use CursorRestoreReason.
        // durationMs/deferredMs stop before enable/reset; restoreMs measures only
        // those two calls. Input fields never resolve event.window or query the
        // global pointer, either of which can add cursor-routing IPC to a probe.
        var values: [String: Double] = [
            "cursorDeferPhase": phase, "cursorDeferred": phase == 1 ? 1 : 0,
            "reason": Double(reason), "windowNumber": Double(windowNumber),
            "durationMs": deferredMs, "deferredMs": deferredMs, "restoreMs": restoreMs,
            "hasStart": hasStart ? 1 : 0]
        if let event {
            values["eventType"] = Double(event.type.rawValue)
            values["eventWindowNumber"] = Double(event.windowNumber)
            values["eventX"] = Double(event.locationInWindow.x)
            values["eventY"] = Double(event.locationInWindow.y)
            if event.type == .mouseMoved {
                values["eventDeltaX"] = Double(event.deltaX)
                values["eventDeltaY"] = Double(event.deltaY)
            }
        }
        NativePerformance.event(.display, context: gesture?.id ?? context, values: values)
    }

    private func restoreCursorRects(reason: CursorRestoreReason, event: NSEvent? = nil) {
        if let monitor = cursorInputMonitor { NSEvent.removeMonitor(monitor); cursorInputMonitor = nil }
        guard let window = cursorWindow else { cursorDeferredAt = nil; return }
        cursorWindow = nil
        let deferredAt = cursorDeferredAt
        cursorDeferredAt = nil
        let restoreStartedAt = NativePerformance.mode == .detailed ? NativePerformance.now() : nil
        window.enableCursorRects()
        if window.areCursorRectsEnabled { window.resetCursorRects() }
        if let restoreStartedAt {
            let restoredAt = NativePerformance.now()
            recordCursorDeferral(phase: 2, reason: reason.rawValue, windowNumber: window.windowNumber,
                deferredMs: deferredAt.map { Double(restoreStartedAt - $0) / 1_000_000 } ?? 0,
                restoreMs: Double(restoredAt - restoreStartedAt) / 1_000_000,
                hasStart: deferredAt != nil, event: event)
        }
    }

    private func finish(_ outcome: NativePerformance.Outcome, cursorReason: CursorRestoreReason = .cancelled) {
        isScrolling = false
        restoreCursorRects(reason: cursorReason)
        gesture?.end(outcome); gesture = nil
    }

    isolated deinit {
        finish(.cancelled, cursorReason: .deinitialized)
        NotificationCenter.default.removeObserver(self)
    }
}
