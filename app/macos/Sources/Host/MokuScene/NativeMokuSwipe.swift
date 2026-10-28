import SwiftUI
import AppKit

enum NativeMokuSwipeAction { case note }

/// Physical finger deltas use the same threshold and direction dominance on
/// the Mac trackpad. Each contact can request one action only.
private struct NativeMokuSwipeIntent {
    static let minimumDistance: CGFloat = 24
    private var upward: CGFloat = 0
    private var horizontalTravel: CGFloat = 0
    private(set) var triggered = false

    mutating func sample(_ delta: CGPoint) -> NativeMokuSwipeAction? {
        upward -= delta.y
        horizontalTravel += abs(delta.x)
        guard !triggered else { return nil }
        let action: NativeMokuSwipeAction?
        if upward >= Self.minimumDistance && upward > horizontalTravel * 1.5 { action = .note }
        else { action = nil }
        if action != nil { triggered = true }
        return action
    }
}

enum NativeMokuSwipeTarget {
    static func contains(_ point: CGPoint, row: CGRect, showingMessage: Bool,
                         excluding controls: [CGRect] = []) -> Bool {
        let region = showingMessage
            ? CGRect(x: row.minX + 9, y: row.midY - 18, width: 46, height: 36) : row
        return region.contains(point) && !controls.contains { $0.contains(point) }
    }
}

/// Touch begins inside Moku, then may leave the short control row while moving
/// upward. Starting elsewhere never acquires Moku on the way across it.
struct NativeMokuTouchSwipeSequence {
    private var origin: CGPoint?
    private var previous: CGPoint?
    private var intent = NativeMokuSwipeIntent()
    var isTracking: Bool { previous != nil }
    private(set) var hasClaimedDrag = false

    mutating func begin(at point: CGPoint, eligible: Bool, inside: Bool) -> Bool {
        cancel()
        guard eligible, inside, point.x.isFinite, point.y.isFinite else { return false }
        origin = point; previous = point
        return true
    }
    mutating func move(to point: CGPoint, eligible: Bool) -> NativeMokuSwipeAction? {
        guard let previous else { return nil }
        guard eligible, point.x.isFinite, point.y.isFinite else { cancel(); return nil }
        self.previous = point
        if let origin, hypot(point.x - origin.x, point.y - origin.y) >= NativeMokuSwipeIntent.minimumDistance {
            // Any deliberate drag must cancel the underlying button's click,
            // even if its direction has no Moku action. Keep that ownership
            // through a reversal or a return to the original touch point.
            hasClaimedDrag = true
        }
        return intent.sample(CGPoint(x: point.x - previous.x, y: point.y - previous.y))
    }
    mutating func cancel() { origin = nil; previous = nil; intent = .init(); hasClaimedDrag = false }
}


/// A gesture belongs to its starting target. Never acquire a scroll already in
/// progress elsewhere, or let the opening gesture scroll the expanded note.
struct NativeMokuSwipeSequence {
    private var owned: Bool?
    typealias Action = NativeMokuSwipeAction
    private var intent = NativeMokuSwipeIntent()

    mutating func reset() { self = Self() }

    mutating func route(x: CGFloat, y: CGFloat, phase: NSEvent.Phase,
                        momentum: NSEvent.Phase, precise: Bool, inverted: Bool,
                        eligible: Bool, inside: Bool) -> (consume: Bool, action: Action?) {
        if phase.contains(.began) || phase.contains(.mayBegin) { reset() }
        if !momentum.isEmpty {
            let consume = owned == true
            if momentum.contains(.ended) || momentum.contains(.cancelled) { reset() }
            return (consume, nil)
        }
        // Phased precision events identify direct trackpad contact; wheel
        // ticks and orphan momentum cannot open the note.
        guard precise, !phase.isEmpty, x.isFinite, y.isFinite else {
            reset(); return (false, nil)
        }
        if phase.contains(.mayBegin) { return (false, nil) }
        if owned == nil {
            guard phase.contains(.began) || phase.contains(.changed) else { return (false, nil) }
            owned = eligible && inside
        }
        guard owned == true else { return (false, nil) }
        if phase.contains(.cancelled) { reset(); return (true, nil) }
        if !intent.triggered && (!eligible || !inside) {
            owned = false; return (true, nil)
        }
        // Natural Scrolling changes event signs, not the physical gesture.
        let action = intent.sample(CGPoint(x: inverted ? x : -x, y: inverted ? y : -y))
        // Retain ownership through the ended → momentum handoff. The next
        // direct began/mayBegin starts a fresh gesture.
        return (true, action)
    }
}

struct NativeMokuSwipeMonitor: NSViewRepresentable {
    var isActive: () -> Bool
    var isInside: (CGPoint) -> Bool
    var openNote: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.isActive = isActive; view.isInside = isInside
        view.openNote = openNote
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    @MainActor final class MonitorView: NSView {
        var isActive: () -> Bool = { false }
        var isInside: (CGPoint) -> Bool = { _ in false }
        var openNote: () -> Void = {}
        private var monitor: Any?
        private var sequence = NativeMokuSwipeSequence()
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return event }
            if event.type != .scrollWheel { sequence.reset(); return event }
            let modified = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            let result = sequence.route(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                phase: event.phase, momentum: event.momentumPhase,
                precise: event.hasPreciseScrollingDeltas, inverted: event.isDirectionInvertedFromDevice,
                eligible: isActive() && window.isVisible && !modified && NSEvent.pressedMouseButtons == 0,
                inside: isInside(convert(event.locationInWindow, from: nil)))
            switch result.action {
            case .note: openNote()
            case nil: break
            }
            return result.consume ? nil : event
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return consumed ? nil : event
            }
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { stop() }
            super.viewWillMove(toWindow: newWindow)
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            sequence.reset()
        }
    }
}
