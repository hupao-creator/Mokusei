import AppKit
import MokuseiPluginUI
import Observation
import QuartzCore
import SwiftUI

struct NativeMokuHorizontalDestination: Equatable {
    let offset: CGFloat
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
        let visibleOffset = (layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
        guard previous != next else { return }

        let immediate = previous == nil || next.reduced || next.dragging || previous?.viewport != next.viewport
        if !immediate, previous?.offset == next.offset, travelling { return }
        generation += 1
        let current = generation
        let delta = visibleOffset + (previous?.offset ?? next.offset) - next.offset
        layer.removeAnimation(forKey: "moku-horizontal")
        travelling = !immediate && abs(delta) > 0.01
        guard travelling else {
            deliverCompletion(generation: current)
            return
        }

        let animation: CABasicAnimation
        if previous?.frame != next.frame, next.frame != nil {
            let spring = CASpringAnimation(keyPath: "transform.translation.x")
            let frequency = 2 * Double.pi / 0.62
            spring.mass = 1; spring.stiffness = frequency * frequency
            spring.damping = 2 * 0.78 * frequency
            spring.duration = spring.settlingDuration
            animation = spring
        } else {
            animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.duration = previous?.frame != next.frame ? 0.38 : 0.42
            animation.timingFunction = previous?.frame != next.frame
                ? CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                : next.reading ? NativeReadingPageTiming.emphasizedOpening : CAMediaTimingFunction(name: .easeInEaseOut)
        }
        animation.fromValue = delta; animation.toValue = 0
        animation.delegate = self; animation.setValue(current, forKey: "generation")
        layer.add(animation, forKey: "moku-horizontal")
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
            let offset = (surface.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
            return hitRects.contains(where: { $0.contains(local) || $0.offsetBy(dx: offset, dy: 0).contains(local) }) ? self : nil
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
