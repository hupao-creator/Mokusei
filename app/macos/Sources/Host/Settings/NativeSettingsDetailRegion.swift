import SwiftUI
import AppKit

/// The renderer's local Agent detail belongs to the icon row, including the
/// gap before the detail surface. Track both regions without intercepting input.
@MainActor final class SettingsDetailRegion {
    private let views = NSHashTable<NSView>.weakObjects()
    private var monitor: Any?
    private var focusObserver: NSObjectProtocol?
    private var hadRegionFocus = false
    var pinned = false
    var iconFocused = false
    var dismiss: () -> Void = {}

    func add(_ view: NSView) { views.add(view) }
    func remove(_ view: NSView) { views.remove(view) }
    func setActive(_ active: Bool) {
        if !active { stop(); return }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = event.window else { return }
                if !self.contains(window: window, point: event.locationInWindow) { self.dismiss() }
            }
            return event
        }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let inside = self.iconFocused || self.containsKeyboardFocus()
                if self.hadRegionFocus && !inside { self.dismiss() }
                self.hadRegionFocus = inside
            }
        }
    }
    func dismissAfterPointerLeave() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.monitor != nil, !self.pinned, !self.iconFocused, !self.containsKeyboardFocus() else { return }
            let inside = self.views.allObjects.contains { view in
                guard let window = view.window else { return false }
                return view.bounds.contains(view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
            }
            if !inside { self.dismiss() }
        }
    }
    func dismissAfterFocusLeave() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.monitor != nil, !self.iconFocused, !self.containsKeyboardFocus() else { return }
            self.dismiss()
        }
    }
    func focusFirstInput() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self, let window = self.views.allObjects.first?.window, let root = window.contentView else { return }
            @MainActor func inputs(_ view: NSView) -> [NSView] {
                let isInput = (view as? NSTextField)?.isEditable == true || (view as? NSTextView)?.isEditable == true
                return (isInput ? [view] : []) + view.subviews.flatMap(inputs)
            }
            if let input = inputs(root).first(where: { view in
                !view.isHiddenOrHasHiddenAncestor && self.contains(window: window, point: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
            }) { window.makeFirstResponder(input) }
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        hadRegionFocus = false
    }
    private func contains(window: NSWindow, point: NSPoint) -> Bool {
        views.allObjects.contains { $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.contains($0.convert(point, from: nil)) }
    }
    private func containsKeyboardFocus() -> Bool {
        guard let window = views.allObjects.first?.window else { return false }
        // SwiftUI buttons share a hosting view as their responder. Their focused
        // accessibility element supplies the actual control's screen rectangle.
        if let focused = window.accessibilityFocusedUIElement as? any NSAccessibilityProtocol {
            let frame = focused.accessibilityFrame()
            if !frame.isEmpty, frame.width < window.frame.width || frame.height < window.frame.height {
                return contains(window: window, point: window.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY)))
            }
        }
        guard let responder = window.firstResponder as? NSView,
              responder is NSTextView || responder is NSControl else { return false }
        return contains(window: window, point: responder.convert(CGPoint(x: responder.bounds.midX, y: responder.bounds.midY), to: nil))
    }
}

struct SettingsDetailBoundary: NSViewRepresentable {
    let region: SettingsDetailRegion
    func makeNSView(context: Context) -> Boundary {
        let view = Boundary(); view.region = region; region.add(view); return view
    }
    func updateNSView(_ nsView: Boundary, context: Context) {}
    static func dismantleNSView(_ nsView: Boundary, coordinator: ()) { nsView.region?.remove(nsView) }
    final class Boundary: NSView {
        weak var region: SettingsDetailRegion?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
