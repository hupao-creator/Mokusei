import AppKit
import MokuseiPluginUI
import Observation
import QuartzCore
import SwiftUI

struct NativeMokuHorizontalDestination: Equatable {
    let offset: CGFloat
    let verticalOffset: CGFloat
    let frame: CGRect?
    let revision: Int
    let viewport: CGSize
    let dragging: Bool
    let reduced: Bool
    let composer: UUID
    let reading: Bool
}

@MainActor final class NativeMokuHorizontalTravelHandle {
    weak var view: MokuHorizontalTravelView?
}

extension EnvironmentValues {
    @Entry var nativeMokuHorizontalTravel: NativeMokuHorizontalTravelHandle? = nil
}

/// Preserve the Dock's hosting root and update its observable content. Replacing
/// rootView during an outer update can settle the shell's layout while its face
/// is still animating in the previous coordinate space.
/// The compositor owns column travel and the compact reading-seat descent;
/// SwiftUI retains shell resizing, composer expansion and identity animation.
struct NativeMokuHorizontalTravel<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content
    func makeNSView(context: Context) -> MokuHorizontalTravelView { MokuHorizontalTravelView() }
    func updateNSView(_ view: MokuHorizontalTravelView, context: Context) {
        view.updateContent(AnyView(content.environment(\.nativeMokuHorizontalTravel, view.handle)
            .environment(\.self, context.environment)), transaction: context.transaction)
    }
    static func dismantleNSView(_ view: MokuHorizontalTravelView, coordinator: ()) { view.retire() }
}

struct NativeMokuHorizontalTravelCommand: NSViewRepresentable {
    let destination: NativeMokuHorizontalDestination
    let hitRects: [CGRect]
    let onSettled: (NativeMokuHorizontalDestination) -> Void
    @Environment(\.nativeMokuHorizontalTravel) private var handle
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        handle?.view?.configure(destination: destination, hitRects: hitRects, onSettled: onSettled)
    }
}

@MainActor final class MokuHorizontalTravelView: NSView, CAAnimationDelegate {
    private let surface = MokuHorizontalSurfaceView()
    private var hosting: NSHostingView<MokuHorizontalContent>?
    private var contentState: MokuHorizontalContentState?
    private var destination: NativeMokuHorizontalDestination?
    let handle = NativeMokuHorizontalTravelHandle()
    private var hitRects: [CGRect] = []
    private var onSettled: ((NativeMokuHorizontalDestination) -> Void)?
    private var generation = 0
    private var travelling = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        surface.wantsLayer = true
        addSubview(surface)
        handle.view = self
    }
    required init?(coder: NSCoder) { nil }

    func updateContent(_ content: AnyView, transaction: Transaction) {
        if let contentState { withTransaction(transaction) { contentState.content = content } }
        else {
            let state = MokuHorizontalContentState(content: content)
            contentState = state
            let host = NSHostingView(rootView: MokuHorizontalContent(state: state))
            host.sizingOptions = []; host.safeAreaRegions = []; host.wantsLayer = true
            hosting = host; surface.addSubview(host)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if surface.frame != bounds { surface.frame = bounds }
        if hosting?.frame != surface.bounds { hosting?.frame = surface.bounds }
        CATransaction.commit()
    }

    func configure(destination next: NativeMokuHorizontalDestination, hitRects: [CGRect],
                   onSettled: @escaping (NativeMokuHorizontalDestination) -> Void) {
        let previous = destination
        self.hitRects = hitRects; self.onSettled = onSettled; destination = next
        let layer = surface.layer!
        let visible = layer.presentation()?.transform ?? CATransform3DIdentity
        guard previous != next else { return }

        let immediate = previous == nil || next.reduced || next.dragging || previous?.viewport != next.viewport
        if !immediate, previous?.offset == next.offset,
           previous?.verticalOffset == next.verticalOffset, travelling { return }
        generation += 1
        let current = generation
        let delta = CGPoint(x: visible.m41 + (previous?.offset ?? next.offset) - next.offset,
            y: visible.m42 + (previous?.verticalOffset ?? next.verticalOffset) - next.verticalOffset)
        layer.removeAnimation(forKey: "moku-travel")
        travelling = !immediate && (abs(delta.x) > 0.01 || abs(delta.y) > 0.01)
        guard travelling else {
            deliverCompletion(generation: current)
            return
        }

        let duration: TimeInterval = previous?.frame != next.frame ? 0.38 : 0.42
        let timing = previous?.frame != next.frame
            ? CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            : abs(delta.y) > 0.01 ? CAMediaTimingFunction(name: .easeInEaseOut)
            : next.reading ? NativeReadingPageTiming.emphasizedOpening : CAMediaTimingFunction(name: .easeInEaseOut)
        let horizontal: CAPropertyAnimation
        if abs(delta.x) >= 12 {
            let rebound = CAKeyframeAnimation(keyPath: "transform.translation.x")
            // A single bounded overshoot gives arrival a small settling beat.
            // Tiny geometry corrections keep their ordinary monotone curve.
            let overshoot = -copysign(min(6, abs(delta.x) * 0.025), delta.x)
            rebound.values = [delta.x, overshoot, 0]
            rebound.keyTimes = [0, 0.76, 1]
            rebound.timingFunctions = [
                CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.28, 1),
                CAMediaTimingFunction(name: .easeInEaseOut)
            ]
            rebound.duration = 0.52
            horizontal = rebound
        } else {
            let travel = CABasicAnimation(keyPath: "transform.translation.x")
            travel.fromValue = delta.x; travel.toValue = 0
            travel.duration = duration; travel.timingFunction = timing
            horizontal = travel
        }
        // Keep the 12–16pt descent monotone and on its existing schedule even
        // when the column move is still completing its horizontal rebound.
        let vertical = CABasicAnimation(keyPath: "transform.translation.y")
        vertical.fromValue = delta.y; vertical.toValue = 0
        vertical.duration = duration; vertical.timingFunction = timing
        let animation = CAAnimationGroup()
        animation.animations = [horizontal, vertical]
        animation.duration = max(horizontal.duration, vertical.duration)
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.delegate = self; animation.setValue(current, forKey: "generation")
        layer.add(animation, forKey: "moku-travel")
    }

    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag, let generation = anim.value(forKey: "generation") as? Int else { return }
        Task { @MainActor [weak self] in self?.deliverCompletion(generation: generation) }
    }

    private func deliverCompletion(generation expected: Int) {
        // Native delivery can arrive after a reversal, resize or route replacement.
        // Defer immediate receipts too: never publish scene state during updateNSView.
        Task { @MainActor [weak self] in
            guard let self, generation == expected, let destination else { return }
            travelling = false
            onSettled?(destination)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if travelling {
            // The controls already have destination coordinates. Absorb presses
            // on both seats so a moving bar cannot click the reading backdrop.
            let visible = surface.layer?.presentation()?.transform ?? CATransform3DIdentity
            return hitRects.contains(where: {
                $0.contains(local) || $0.offsetBy(dx: visible.m41, dy: visible.m42).contains(local)
            }) ? self : nil
        }
        guard hitRects.contains(where: { $0.contains(local) }),
              let hit = super.hitTest(point), hit !== self, hit !== surface else { return nil }
        return hit
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    func retire() {
        generation += 1; destination = nil; onSettled = nil; handle.view = nil
        surface.layer?.removeAllAnimations()
        hosting?.removeFromSuperview(); hosting = nil; contentState = nil
    }
}

private final class MokuHorizontalSurfaceView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor @Observable private final class MokuHorizontalContentState {
    var content: AnyView
    init(content: AnyView) { self.content = content }
}

private struct MokuHorizontalContent: View {
    let state: MokuHorizontalContentState
    var body: some View {
        // The nested host occupies the complete logical workspace viewport.
        // Named SwiftUI spaces do not cross an NSHostingView boundary.
        state.content.coordinateSpace(name: "workspace")
    }
}
