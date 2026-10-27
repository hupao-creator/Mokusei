import SwiftUI
import AppKit

/// Settings top insets are window-drag regions; the shared window navigation
/// capsule sits above this background and owns its own control hit targets.
struct SettingsHeaderDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let point = convert(point, from: superview)
            guard !isHiddenOrHasHiddenAncestor, bounds.contains(point) else { return nil }
            return self
        }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
