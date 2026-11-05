import AppKit
import MokuseiPluginUI
import Observation
import QuartzCore
import SwiftUI

/// Only an accepted Report continuation requests this transition. A route UUID,
/// rather than catalog/content revisions, owns its single presentation.
@MainActor @Observable
final class NativeExecutionRouteSlideRequest {
    var destinationRoute: UUID?
}

struct NativeExecutionRouteSlide<Content: View>: NSViewRepresentable {
    let route: UUID
    let requestedRoute: UUID?
    let ready: Bool
    let enabled: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    func makeNSView(context: Context) -> ExecutionRouteSlideView { ExecutionRouteSlideView() }
    func updateNSView(_ view: ExecutionRouteSlideView, context: Context) {
        view.update(content: AnyView(content), environment: context.environment, route: route,
            requested: requestedRoute == route, ready: ready,
            animated: enabled && !reduceMotion && scenePhase == .active)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ExecutionRouteSlideView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
    static func dismantleNSView(_ view: ExecutionRouteSlideView, coordinator: ()) { view.retire() }
}

/// Retain the real Report/WebKit surface while the new production Agent workspace
/// prepares. Both cards share one native seat, so their spacing and text widths
/// stay fixed during compositor travel. No captured bitmap or second renderer.
@MainActor final class ExecutionRouteSlideView: NSView {
    private var current = ExecutionRouteSlideSeat()
    private var outgoing: ExecutionRouteSlideSeat?
    private var route: UUID?
    private var travelling = false
    private var ready = false
    private var animated = false
    private var content: AnyView?
    private var environment = EnvironmentValues()
    private var startScheduled = false
    private var generation = 0

    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(current)
    }
    required init?(coder: NSCoder) { nil }

    func update(content: AnyView, environment: EnvironmentValues, route: UUID,
                requested: Bool, ready: Bool, animated: Bool) {
        if self.route != route {
            settle()
            if self.route != nil, requested, bounds.width > 0, bounds.height > 0 {
                outgoing = current
                // Keep its exact root and native document alive, but revoke
                // reader interaction without changing the retained layout.
                outgoing?.deactivate()
                current = ExecutionRouteSlideSeat()
                addSubview(current)
            }
            self.route = route
        }
        self.content = content; self.environment = environment
        self.ready = ready; self.animated = animated
        refreshCurrent()
        layoutSeats()
        if outgoing != nil {
            if !animated, ready || travelling { settle() }
            else { scheduleTravel() }
        }
    }

    private func refreshCurrent() {
        guard let content else { return }
        current.update(content: content, environment: environment, active: outgoing == nil)
    }

    override func layout() {
        super.layout()
        // A new viewport invalidates the translation distance; never animate
        // obsolete geometry across a resize or a workspace zoom.
        if outgoing != nil, current.frame.size != bounds.size { settle() }
        layoutSeats()
        scheduleTravel()
    }

    private func layoutSeats() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        current.frame = bounds
        outgoing?.frame = bounds
        current.alphaValue = outgoing == nil || travelling ? 1 : 0
        CATransaction.commit()
    }

    private func scheduleTravel() {
        guard outgoing != nil, ready, animated, !travelling, !startScheduled else { return }
        startScheduled = true
        let token = generation
        // Readiness is a SwiftUI layout commitment. Let that native host finish
        // layout before revealing it; never mutate the workspace during update.
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == token else { return }
            startScheduled = false
            guard outgoing != nil, ready, animated, !travelling else { return }
            current.layoutSubtreeIfNeeded()
            startTravel(token)
        }
    }

    private func startTravel(_ token: Int) {
        guard let outgoing, let oldLayer = outgoing.layer, let newLayer = current.layer else { settle(); return }
        travelling = true
        layoutSeats()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == token else { return }
                settle()
            }
        }
        translate(oldLayer, from: 0, to: -bounds.width)
        translate(newLayer, from: bounds.width, to: 0)
        CATransaction.commit()
    }

    private func translate(_ layer: CALayer, from: CGFloat, to: CGFloat) {
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = from; animation.toValue = to
        animation.duration = NativeReadingPageTiming.duration
        animation.timingFunction = NativeReadingPageTiming.replacementTimingFunction
        animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "execution.route.slide")
    }

    private func settle() {
        generation += 1; startScheduled = false; travelling = false
        current.layer?.removeAnimation(forKey: "execution.route.slide")
        outgoing?.removeFromSuperview(); outgoing = nil
        refreshCurrent()
        layoutSeats()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { outgoing == nil ? super.hitTest(point) : nil }
    override func accessibilityChildren() -> [Any]? { outgoing == nil ? super.accessibilityChildren() : [] }
    func retire() {
        settle(); content = nil
        current.host.rootView = AnyView(EmptyView())
    }
}

@MainActor private final class ExecutionRouteSlideSeat: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var content: AnyView?
    private var environment = EnvironmentValues()
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        host.sizingOptions = []; host.safeAreaRegions = []
        addSubview(host)
    }
    required init?(coder: NSCoder) { nil }
    func update(content: AnyView, environment: EnvironmentValues, active: Bool) {
        self.content = content; self.environment = environment
        var environment = environment
        environment.nativeReadingInteractionActive = environment.nativeReadingInteractionActive && active
        host.rootView = AnyView(content.allowsHitTesting(active).accessibilityHidden(!active)
            .environment(\.self, environment))
    }
    func deactivate() {
        if let content { update(content: content, environment: environment, active: false) }
    }
    override func layout() { super.layout(); host.frame = bounds }
}
