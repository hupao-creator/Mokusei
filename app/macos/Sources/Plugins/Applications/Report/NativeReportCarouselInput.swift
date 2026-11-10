import AppKit
import SwiftUI

/// Confines native scroll/drag handling to the cover. No global event monitor.
struct NativeReportCarouselInput: NSViewRepresentable {
    var step: (Int) -> Void
    var open: () -> Void
    var interacting: (Bool) -> Void
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.step = step; view.open = open; view.interacting = interacting
    }
    final class Surface: NSView {
        var step: (Int) -> Void = { _ in }
        var open: () -> Void = {}
        var interacting: (Bool) -> Void = { _ in }
        private var start: NSPoint?
        private var travel: CGFloat = 0
        private var consumed = false
        private var lastScroll: TimeInterval = 0
        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil); interacting(true)
        }
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            defer { start = nil; interacting(false) }
            guard let start else { return }
            let point = convert(event.locationInWindow, from: nil)
            let dx = point.x - start.x, dy = point.y - start.y
            if abs(dx) > 48, abs(dx) > abs(dy) { step(dx < 0 ? 1 : -1) }
            else if hypot(dx, dy) < 8 { open() }
        }
        override func scrollWheel(with event: NSEvent) {
            // A gesture owns at most one page; momentum cannot trigger a second.
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.began) || event.timestamp - lastScroll > 0.3 {
                travel = 0; consumed = false
            }
            lastScroll = event.timestamp
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                interacting(false); return
            }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
                super.scrollWheel(with: event); return
            }
            if !event.phase.isEmpty { interacting(true) }
            travel += event.scrollingDeltaX
            if !consumed, abs(travel) > 48 {
                consumed = true; step(travel < 0 ? 1 : -1)
            }
        }
        override func viewDidMoveToWindow() {
            if window == nil { interacting(false); start = nil }
        }
    }
}
