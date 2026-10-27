import MokuseiPluginUI
import SwiftUI
import AppKit

/// Precision determines units; phases determine ownership, independently of the
/// device type. There is no axis lock, synthetic inertia or Retina conversion.
enum NativeOverviewScrollGeometry {
    static func delta(x: Double, y: Double, precise: Bool, shift: Bool,
                      canvasPerWindowPoint: CGSize) -> CGSize? {
        guard x.isFinite, y.isFinite, canvasPerWindowPoint.width.isFinite,
              canvasPerWindowPoint.height.isFinite, canvasPerWindowPoint.width > 0,
              canvasPerWindowPoint.height > 0 else { return nil }
        let unit = precise ? 1.0 : 40.0
        let horizontal = !precise && shift && x == 0
        let result = CGSize(width: (horizontal ? y : x) * unit * canvasPerWindowPoint.width,
                            height: (horizontal ? 0 : y) * unit * canvasPerWindowPoint.height)
        guard result.width.isFinite, result.height.isFinite else { return nil }
        return result
    }
}

/// Routing only: the camera remains the sole owner of transforms.
struct NativeOverviewScrollSequence {
    enum Owner { case canvas, native, discarded }
    enum Stage { case idle, direct, awaitingMomentum, momentum }
    private(set) var owner: Owner?
    private(set) var stage = Stage.idle
    private var endedAt = 0.0

    mutating func interrupt() {
        if owner == .canvas { owner = .discarded }
    }
    mutating func reset() { owner = nil; stage = .idle }

    /// nil means native dispatch, canvas means apply once, discarded means swallow.
    mutating func route(phase: NSEvent.Phase, momentum: NSEvent.Phase, hasDelta: Bool,
                        candidate: Owner, now: Double) -> Owner? {
        if !momentum.isEmpty {
            guard let owner, stage != .idle else { return nil }
            // An ended direct sequence may be followed by system inertia. Never
            // acquire orphan momentum, even when the pointer is over the canvas.
            if stage == .awaitingMomentum && now - endedAt > 0.25 { reset(); return nil }
            stage = .momentum
            if momentum.contains(.ended) || momentum.contains(.cancelled) { reset() }
            return owner
        }
        if phase.isEmpty {
            reset() // Phase-less wheels are independent events, never latched.
            return hasDelta ? candidate : nil
        }
        if phase.contains(.mayBegin) { return nil }
        if phase.contains(.began) || stage == .awaitingMomentum || stage == .momentum { reset() }
        if owner == nil, hasDelta { owner = candidate; stage = .direct }
        let result = owner
        if phase.contains(.cancelled) { reset() }
        else if phase.contains(.ended), owner != nil { stage = .awaitingMomentum; endedAt = now }
        return result
    }
}

/// SwiftUI supplies cumulative magnification. Store every valid sample, including
/// samples beyond a clamp, so reversing direction responds immediately.
struct NativeOverviewPinchSamples {
    private(set) var previous = 1.0
    mutating func ratio(_ magnification: Double) -> Double? {
        guard magnification.isFinite, magnification > 0 else { return nil }
        defer { previous = magnification }
        let value = magnification / previous
        return value.isFinite && value > 0 ? value : nil
    }
}

@MainActor final class NativeOverviewNavigationInput {
    let regions: NativeCanvasInputRegions
    init(regions: NativeCanvasInputRegions = .init()) { self.regions = regions }
    weak var view: NativeOverviewScrollInput.MonitorView?
    private var pinchSamples: NativeOverviewPinchSamples?
    private var pinchAllowed = false
    private var pinchAnchor = CGPoint.zero
    private(set) var pinching = false
    private var pinchCancelled = false

    func pinch(magnification: Double, anchor: CGPoint, camera: NativeOverviewCamera) {
        guard let view else { return }
        if !pinching {
            pinching = true; pinchCancelled = false
            pinchSamples = .init(); pinchAnchor = anchor
            pinchAllowed = view.canStart(at: anchor)
            view.interrupt()
        }
        guard !pinchCancelled, pinchAllowed, view.enabled() else { return }
        guard let ratio = pinchSamples?.ratio(magnification), ratio != 1 else { return }
        let live = camera.liveTransform
        camera.setManualTransform(NativeOverviewCameraGeometry.zoom(live, cursor: pinchAnchor,
            nextScale: min(camera.maximumScale, live.scale * ratio), minimumScale: camera.minimumScale), anchor: pinchAnchor)
    }
    func endPinch() { pinching = false; pinchSamples = nil; pinchAllowed = false; pinchCancelled = false }
    func cancel() { if pinching { pinchCancelled = true }; view?.interrupt() }
}

/// Transparent geometry/lifecycle anchor, never a hit target or first responder.
/// A local monitor also sees events above SwiftUI's semantic card subviews.
struct NativeOverviewScrollInput: NSViewRepresentable {
    var input: NativeOverviewNavigationInput
    var size: CGSize
    var toolbarBottom: Double
    var identity: String
    var contentScale: CGFloat
    var enabled: () -> Bool
    var pan: (CGSize) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        let geometry = Configuration(size: size, toolbarBottom: toolbarBottom, identity: identity, contentScale: contentScale)
        if view.configuration != geometry { view.cancelSequence(); view.configuration = geometry }
        view.input = input; input.view = view
        view.enabled = enabled; view.pan = pan
        if !enabled() { view.cancelSequence() }
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    struct Configuration: Equatable {
        var size: CGSize
        var toolbarBottom: Double
        var identity: String
        var contentScale: CGFloat
    }

    @MainActor final class MonitorView: NSView {
        var configuration = Configuration(size: .zero, toolbarBottom: 0, identity: "", contentScale: 1)
        weak var input: NativeOverviewNavigationInput?
        var enabled: () -> Bool = { false }
        var pan: (CGSize) -> Void = { _ in }
        var sequence = NativeOverviewScrollSequence()
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var requiresNewSequence = false
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // Convert a pair of window points rather than dividing by camera scale,
        // backingScaleFactor or an assumed SwiftUI/AppKit zoom convention.
        var canvasPerWindowPoint: CGSize? {
            guard bounds.width > 0, bounds.height > 0, configuration.size.width > 0,
                  configuration.size.height > 0 else { return nil }
            let a = convert(CGPoint.zero, from: nil), b = convert(CGPoint(x: 1, y: 1), from: nil)
            return CGSize(width: abs(b.x - a.x) * configuration.size.width / bounds.width,
                          height: abs(b.y - a.y) * configuration.size.height / bounds.height)
        }
        func canvasPoint(_ point: CGPoint) -> CGPoint {
            let local = convert(point, from: nil)
            return CGPoint(x: (local.x - bounds.minX) * configuration.size.width / bounds.width,
                           y: (local.y - bounds.minY) * configuration.size.height / bounds.height)
        }
        func windowPoint(_ point: CGPoint) -> CGPoint {
            convert(CGPoint(x: bounds.minX + point.x * bounds.width / configuration.size.width,
                            y: bounds.minY + point.y * bounds.height / configuration.size.height), to: nil)
        }
        func canStart(at point: CGPoint) -> Bool {
            guard enabled(), let window, window.isVisible,
                  !isHiddenOrHasHiddenAncestor, bounds.width > 0, bounds.height > 0,
                  point.x.isFinite, point.y.isFinite,
                  CGRect(origin: .zero, size: configuration.size).contains(point),
                  point.y >= configuration.toolbarBottom,
                  NSEvent.pressedMouseButtons == 0 else { return false }
            let location = windowPoint(point)
            guard bounds.intersection(visibleRect).contains(convert(location, from: nil)),
                  input?.regions.contains(location, in: window) != true else { return false }
            // Public AppKit fallback for native editors/embedded scrolling views.
            guard let content = window.contentView else { return false }
            let hitPoint = content.superview?.convert(location, from: nil) ?? location
            var target = content.hitTest(hitPoint)
            while let current = target {
                if current is NSScrollView || current is NSTextView { return false }
                target = current.superview
            }
            return true
        }

        /// Called by the local monitor; exposed internally for window-level replays.
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                cancelSequence(); return event
            }
            guard event.type == .scrollWheel else { return event }
            guard enabled(), window.isVisible, !isHiddenOrHasHiddenAncestor else {
                cancelSequence(); return event
            }
            let modified = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            guard !modified, let factor = canvasPerWindowPoint,
                  let delta = NativeOverviewScrollGeometry.delta(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas, shift: event.modifierFlags.contains(.shift),
                    canvasPerWindowPoint: factor) else { cancelSequence(); return event }
            let hasDelta = delta.width != 0 || delta.height != 0
            let directStart = event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty)
            if directStart { requiresNewSequence = false }
            if event.phase.contains(.mayBegin) {
                sequence.reset(); requiresNewSequence = false
                return event
            }
            if requiresNewSequence {
                guard sequence.owner == .discarded else { return event }
                let owner = sequence.route(phase: event.phase, momentum: event.momentumPhase, hasDelta: hasDelta,
                    candidate: .discarded, now: event.timestamp)
                return owner == .discarded ? nil : event
            }
            let candidate: NativeOverviewScrollSequence.Owner = canStart(at: canvasPoint(event.locationInWindow))
                && input?.pinching != true ? .canvas : .native
            if input?.pinching == true || NSEvent.pressedMouseButtons != 0 { sequence.interrupt() }
            let owner = sequence.route(phase: event.phase, momentum: event.momentumPhase, hasDelta: hasDelta,
                candidate: candidate, now: event.timestamp)
            switch owner {
            case .canvas:
                if hasDelta { pan(delta) }
                return nil
            case .discarded: return nil
            default: return event
            }
        }
        func cancelSequence() {
            sequence.interrupt(); requiresNewSequence = true; input?.cancel()
        }
        func interrupt() { sequence.interrupt() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            // Allow a first changed event (some devices omit began) on mounting.
            requiresNewSequence = false
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return consumed ? nil : event
            }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if name == NSWindow.willCloseNotification { self?.stop() }
                        else { self?.cancelSequence() }
                    }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: NSApp, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancelSequence() }
                })
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { stop() }
            super.viewWillMove(toWindow: newWindow)
        }
        func stop() {
            cancelSequence()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
    }
}
