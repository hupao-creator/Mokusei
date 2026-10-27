// Synthetic event snapshots in the fixture's visible native window; no OS event posting.
import AppKit
import SwiftUI
import MokuseiPluginUI
@testable import MokuseiUI

/// Event snapshots are passed directly to the production bridge handler. Bare
/// NSEvent subclasses must never enter AppKit's queue/native dispatch machinery.
private final class ScrollSample: NSEvent {
    var target: NSWindow?
    var point = CGPoint.zero
    var dx = 0.0
    var dy = 0.0
    var direct: NSEvent.Phase = []
    var inertia: NSEvent.Phase = []
    var flags: NSEvent.ModifierFlags = []
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var phase: NSEvent.Phase { direct }
    override var momentumPhase: NSEvent.Phase { inertia }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

@MainActor private func scrollEvent(in window: NSWindow, location: CGPoint, x: Double, y: Double,
    phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [], flags: NSEvent.ModifierFlags = []) -> NSEvent {
    let event = ScrollSample()
    event.target = window; event.point = location; event.dx = x; event.dy = y
    event.direct = phase; event.inertia = momentum; event.flags = flags
    return event
}

private struct GestureFailure: Error { let message: String }

@MainActor func verifyOverviewGestures(state: NativeOverviewCanvasState, window: NSWindow) async throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw GestureFailure(message: message) }
    }
    func find(_ view: NSView) -> NativeOverviewScrollInput.MonitorView? {
        if let monitor = view as? NativeOverviewScrollInput.MonitorView { return monitor }
        return view.subviews.lazy.compactMap { find($0) }.first
    }
    guard let root = window.contentView, let bridge = find(root), let input = bridge.input else {
        throw GestureFailure(message: "Missing production scroll bridge")
    }
    func sample(_ x: Double, _ y: Double, at: CGPoint = CGPoint(x: 90, y: 200),
                phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [],
                flags: NSEvent.ModifierFlags = []) -> NSEvent {
        scrollEvent(in: window, location: bridge.windowPoint(at), x: x, y: y,
                    phase: phase, momentum: momentum, flags: flags)
    }
    func send(_ event: NSEvent) {
        guard let content = event.window?.contentView, let monitor = find(content) else { return }
        _ = monitor.handle(event)
    }
    let saved = state.camera.liveTransform
    let automatic = state.camera.manual
    defer {
        input.endPinch()
        state.camera.setManualTransform(saved)
        if !automatic { state.camera.returnToAuto() }
    }
    try require(bridge.canStart(at: CGPoint(x: 90, y: 200)), "Visible canvas background rejected navigation")
    let before = state.camera.liveTransform
    send(sample(0, 0, phase: .mayBegin))

    try require(state.camera.manual == automatic, "Zero/preflight scroll changed manual mode")
    send(sample(12.25, -7.5, phase: .began))
    let moved = state.camera.liveTransform
    try require(abs(moved.x - before.x - 12.25) < 1e-6 && abs(moved.y - before.y + 7.5) < 1e-6,
        "Bridge handler failed two-axis precise scroll or applied delta twice: \(before) -> \(moved)")
    try require(moved.scale == before.scale && state.camera.manual, "Pan changed scale or failed manual takeover")
    send(sample(0, 0, phase: .ended))
    // Pointer over chrome must not reassign an existing canvas momentum stream.
    send(sample(2, 3, at: CGPoint(x: 100, y: 10), momentum: .began))
    try require(abs(state.camera.liveTransform.x - moved.x - 2) < 1e-6, "Momentum lost its owner")
    let anchor = CGPoint(x: 630, y: 420)
    let old = state.camera.liveTransform
    let world = CGPoint(x: (anchor.x - old.x) / old.scale, y: (anchor.y - old.y) / old.scale)
    input.pinch(magnification: 1.1, anchor: anchor, camera: state.camera)
    let zoomed = state.camera.liveTransform
    try require(abs((anchor.x - zoomed.x) / zoomed.scale - world.x) < 1e-6
        && abs((anchor.y - zoomed.y) / zoomed.scale - world.y) < 1e-6, "Pinch moved its world anchor")
    send(sample(50, 50, momentum: .changed))
    try require(state.camera.liveTransform == zoomed, "Old momentum wrote during pinch")
    send(sample(0, 0, momentum: .ended)); input.endPinch()
    for flags: NSEvent.ModifierFlags in [.command, .control, .option] {
        send(sample(10, 10, flags: flags))
        try require(state.camera.liveTransform == zoomed, "Modified wheel moved canvas")
    }
    send(sample(10, 10, at: CGPoint(x: 100, y: 10), phase: .began))
    send(sample(10, 10, phase: .changed))
    send(sample(0, 0, phase: .ended))
    try require(state.camera.liveTransform == zoomed, "Native chrome sequence changed owner")

    // Additional visible hosts check actual transformed NSView coordinates and a
    // SwiftUI scroll region, without disturbing the main replay's scene identity.
    for scale in [0.5, 2.0] {
        let fixtureState = NativeOverviewCanvasState()
        let fixtureInput = NativeOverviewNavigationInput()
        let camera = fixtureState.camera
        camera.cutTo(content: .init(left: 0, top: 0, width: 360, height: 200),
                     viewport: .init(width: 600, height: 400, toolbarBottom: 58))
        let host = NSHostingView(rootView:
            ZStack(alignment: .topLeading) {
                Color.clear
                NativeScrollProbe().frame(width: 140, height: 100).offset(x: 440, y: 260)
                ScrollView { Text(String(repeating: "Native reading\n", count: 100)) }
                    .frame(width: 180, height: 160).nativeCanvasNavigationRegion().offset(x: 220, y: 120)
            }
            .frame(width: 600, height: 400)
            .background { NativeOverviewScrollInput(input: fixtureInput, size: CGSize(width: 600, height: 400),
                toolbarBottom: 58, identity: "zoom", contentScale: scale, enabled: { true },
                pan: { camera.pan(deltaX: $0.width, deltaY: $0.height) }) }
            .environment(\.nativeCanvasInputRegions, fixtureInput.regions)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: 600 * scale, height: 400 * scale, alignment: .topLeading))
        let testWindow = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 600 * scale, height: 400 * scale),
            styleMask: [.titled], backing: .buffered, defer: false)
        testWindow.isReleasedWhenClosed = false
        testWindow.contentView = host; testWindow.makeKeyAndOrderFront(nil)
        defer { testWindow.close(); camera.dispose() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        guard let testBridge = find(host), let factor = testBridge.canvasPerWindowPoint else {
            throw GestureFailure(message: "Missing transformed bridge")
        }
        try require(abs(factor.width * scale - 1) < 1e-6 && abs(factor.height * scale - 1) < 1e-6,
            "Window zoom conversion incorrect: \(scale), \(factor)")
        try require(!testBridge.canStart(at: CGPoint(x: 270, y: 180)), "SwiftUI reading region did not retain input")
        try require(testBridge.canStart(at: CGPoint(x: 100, y: 200)), "Reading exclusion leaked beyond its bounds")
        try require(!testBridge.canStart(at: CGPoint(x: 480, y: 300)), "Native NSScrollView fallback lost input")
        let native = scrollEvent(in: testWindow, location: testBridge.windowPoint(CGPoint(x: 270, y: 180)),
                                 x: 0, y: -12, phase: .began)
        let prior = camera.liveTransform
        try require(testBridge.handle(native) === native && camera.liveTransform == prior, "Native region scroll was consumed")
        fixtureInput.pinch(magnification: 1.2, anchor: CGPoint(x: 270, y: 180), camera: camera)
        try require(camera.liveTransform == prior, "Native region pinch moved canvas")
        fixtureInput.endPinch()
        func nativeScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.identifier?.rawValue == "native-scroll-probe" { return scroll }
            return view.subviews.lazy.compactMap { nativeScroll(in: $0) }.first
        }
        guard let scroll = nativeScroll(in: host) else { throw GestureFailure(message: "Missing native reading probe") }
        let nativeEvent = scrollEvent(in: testWindow, location: testBridge.windowPoint(CGPoint(x: 480, y: 300)),
                                     x: 0, y: -12, phase: .began)
        try require(testBridge.handle(nativeEvent) === nativeEvent, "Native reading event was swallowed")
        let originalOffset = scroll.contentView.bounds.origin.y
        // A real CGEvent-backed NSEvent is safe for the native child's responder.
        // The snapshot above is used only by the bridge, never AppKit dispatch.
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -12, wheel2: 0, wheel3: 0)!
        scroll.scrollWheel(with: NSEvent(cgEvent: cg)!)
        try await Task.sleep(for: .milliseconds(60))
        try require(scroll.contentView.bounds.origin.y > originalOffset && camera.liveTransform == prior,
                    "Native child failed to scroll independently")
        _ = testBridge.handle(scrollEvent(in: testWindow, location: native.locationInWindow, x: 0, y: 0, phase: .ended))
        let diagonal = scrollEvent(in: testWindow, location: testBridge.windowPoint(CGPoint(x: 100, y: 200)),
                                   x: 10, y: -8, phase: .began)
        send(diagonal)
        try require(abs((camera.liveTransform.x - prior.x) * scale - 10) < 1e-6
            && abs((camera.liveTransform.y - prior.y) * scale + 8) < 1e-6, "Scaled native window pan distance changed")
        // Public mouse factories produce real window-associated AppKit events.
        // Exercise monitor installation/callback delivery without placing the
        // synthetic scroll snapshots into AppKit's native event storage.
        let stopped = camera.liveTransform
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: diagonal.locationInWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: testWindow.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        NSApp.postEvent(mouse(.leftMouseUp), atStart: true)
        NSApp.postEvent(mouse(.leftMouseDown), atStart: true)
        for mask: NSEvent.EventTypeMask in [.leftMouseDown, .leftMouseUp] {
            if let event = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        let inertia = scrollEvent(in: testWindow, location: diagonal.locationInWindow, x: 10, y: -8, momentum: .changed)
        try require(testBridge.handle(inertia) == nil && camera.liveTransform == stopped, "Mouse monitor failed to suppress old momentum")
        send(diagonal)
        let resigned = camera.liveTransform
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: testWindow)
        try require(testBridge.handle(inertia) == nil && camera.liveTransform == resigned, "Resigned window retained momentum")
    }
    window.makeKeyAndOrderFront(nil)
}

private struct NativeScrollProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.identifier = NSUserInterfaceItemIdentifier("native-scroll-probe")
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 140, height: 2000))
        text.string = String(repeating: "Native reading\n", count: 100)
        text.isEditable = false
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}
