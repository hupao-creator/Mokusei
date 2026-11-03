import AppKit
import QuartzCore
import SwiftUI

struct NativeReadingPanelTransition: Equatable {
    let generation: Int
    let closing: Bool
    let duration: TimeInterval
    let emphasized: Bool
    var thread = false
}

/// The compositor owns panel travel. The reader is admitted only after opening
/// completes, so neither its first projection nor TextKit can delay that travel.
struct NativeReadingPanelViewport<Content: View>: NSViewRepresentable {
    let target: CGRect
    let source: CGRect?
    let open: Bool
    let transition: NativeReadingPanelTransition?
    let contentReady: Bool
    var identity: NativeThreadIdentityVisit? = nil
    let onCompletion: (Int, Bool) -> Void
    let content: Content

    func makeNSView(context: Context) -> ReadingPanelView { ReadingPanelView() }

    func updateNSView(_ view: ReadingPanelView, context: Context) {
        view.configure(target: target, source: source, open: open, transition: transition,
            contentReady: contentReady, identity: identity,
            paperColor: NativePalette.thread.canvas.swiftUI.resolve(in: context.environment).cgColor,
            content: AnyView(content.environment(\.self, context.environment)),
            onCompletion: onCompletion)
    }

    static func dismantleNSView(_ view: ReadingPanelView, coordinator: ()) { view.retire() }
}

@MainActor
final class ReadingPanelView: NSView, CAAnimationDelegate {
    private let surface = ReadingPanelSurfaceView()
    private let aperture = CAShapeLayer()
    private let paper = CALayer()
    private var hosting: NSHostingView<AnyView>?
    private var target = CGRect.zero
    private var source = CGRect.zero
    private var command: NativeReadingPanelTransition?
    private var startedGeneration: Int?
    private var completedGeneration: Int?
    private var onCompletion: ((Int, Bool) -> Void)?
    private var acceptsInput = false
    private var identity: NativeThreadIdentityVisit?
    private var flight: NativeThreadIdentityFlight?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        surface.wantsLayer = true
        // AppKit backs flipped views with an origin anchor. Keep that native
        // coordinate system when animating layer positions directly.
        surface.layer!.anchorPoint = .zero
        addSubview(surface)
        surface.layer!.addSublayer(paper)
        surface.layer!.mask = aperture
    }

    required init?(coder: NSCoder) { nil }

    func configure(target: CGRect, source: CGRect?, open: Bool,
                   transition: NativeReadingPanelTransition?, contentReady: Bool, identity: NativeThreadIdentityVisit? = nil,
                   paperColor: CGColor, content: AnyView, onCompletion: @escaping (Int, Bool) -> Void) {
        if self.identity !== identity { flight?.retire(); flight = nil; self.identity = identity }
        if identity?.pending != true { flight?.retire(); flight = nil }
        let resized = self.target != target
        self.target = target
        self.source = source ?? target.insetBy(dx: min(24, target.width / 4), dy: min(24, target.height / 4))
        self.onCompletion = onCompletion
        command = transition
        acceptsInput = open && transition == nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Reader updates during a close must not restore the layer's model
        // position to the open frame; removing the animation would snap back.
        if resized {
            surface.frame = CGRect(x: target.minX, y: target.minY, width: target.width + 76, height: target.height)
        }
        paper.frame = CGRect(origin: .zero, size: target.size)
        paper.backgroundColor = paperColor
        if contentReady {
            if let hosting { hosting.rootView = content }
            else {
                let view = NSHostingView(rootView: content)
                view.wantsLayer = true
                hosting = view
                // The lightweight identity ink remains above the newly admitted
                // opaque reader until its measured heading takes ownership.
                surface.addSubview(view, positioned: .below, relativeTo: nil)
            }
            hosting?.frame = surface.bounds
        }
        if transition?.closing != true {
            hosting?.layer?.opacity = 1
            hosting?.layer?.transform = CATransform3DIdentity
        }
        CATransaction.commit()
        if let transition {
            if resized && startedGeneration == transition.generation {
                // The stack will settle resize in the same update; do not retime
                // the old motion against a different viewport in the meantime.
                return
            }
            startIfReady()
        } else {
            startedGeneration = nil
            completedGeneration = nil
            surface.layer?.removeAllAnimations()
            aperture.removeAllAnimations()
            hosting?.layer?.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.layer?.opacity = 1
            surface.layer?.mask = open ? nil : aperture
            aperture.path = path(self.source.size)
            surface.layer?.position = open ? target.origin : self.source.origin
            paper.isHidden = open && contentReady
            CATransaction.commit()
        }
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); startIfReady() }
    override func layout() { super.layout(); startIfReady() }

    private func startIfReady() {
        guard window != nil, bounds.width > 0, bounds.height > 0,
              let command, startedGeneration != command.generation, let layer = surface.layer else { return }
        if command.closing { flight?.retire(); flight = nil }
        else if flight == nil, let identity, identity.pending {
            flight = NativeThreadIdentityFlight(visit: identity, surface: surface, source: source)
        }
        let wasMoving = startedGeneration != nil
        let fromPosition = wasMoving ? layer.presentation()?.position ?? layer.position : (command.closing ? target.origin : source.origin)
        let fromPath = wasMoving ? aperture.presentation()?.path ?? aperture.path : path(command.closing ? target.size : source.size)
        let fromOpacity = hosting?.layer?.presentation()?.opacity ?? 1
        let fromTransform = hosting?.layer?.presentation()?.transform ?? CATransform3DIdentity
        let fromSurfaceOpacity = layer.presentation()?.opacity ?? 1
        startedGeneration = command.generation
        completedGeneration = nil
        let destination = command.closing ? source : target
        let timing = command.emphasized ? NativeReadingPageTiming.emphasizedOpening
            : command.thread ? CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
                : CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        aperture.removeAllAnimations()
        layer.mask = aperture
        paper.isHidden = false
        layer.position = destination.origin
        aperture.path = path(destination.size)
        CATransaction.commit()

        let travel = CABasicAnimation(keyPath: "position")
        travel.fromValue = NSValue(point: fromPosition)
        travel.toValue = NSValue(point: layer.position)
        travel.duration = command.duration
        travel.timingFunction = timing
        travel.setValue(command.generation, forKey: "generation")
        travel.delegate = self
        let clip = CABasicAnimation(keyPath: "path")
        clip.fromValue = fromPath
        clip.toValue = aperture.path
        clip.duration = command.duration
        clip.timingFunction = timing
        if command.closing, let contentLayer = hosting?.layer {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = command.thread ? [fromOpacity, 0, 0] : [fromOpacity, fromOpacity, 0, 0]
            fade.keyTimes = command.thread ? [0, 0.8, 1] : [0, 0.2, 0.8, 1]
            fade.duration = command.duration
            fade.timingFunction = command.thread ? CAMediaTimingFunction(name: .easeOut) : timing
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.opacity = 0
            CATransaction.commit()
            contentLayer.add(fade, forKey: "reading.fade")
            if command.thread {
                let scale = source.width / max(1, target.width)
                let transform = CATransform3DMakeScale(scale, scale, 1)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                contentLayer.anchorPoint = .zero
                contentLayer.transform = transform
                layer.opacity = 0
                CATransaction.commit()
                let shrink = CABasicAnimation(keyPath: "transform")
                shrink.fromValue = NSValue(caTransform3D: fromTransform)
                shrink.toValue = NSValue(caTransform3D: transform)
                shrink.duration = command.duration; shrink.timingFunction = timing
                contentLayer.add(shrink, forKey: "reading.content.scale")
                // The retained Overview is already refreshed. Expose its card
                // from 65% of travel instead of holding an empty white shell.
                let handoff = CAKeyframeAnimation(keyPath: "opacity")
                handoff.values = [fromSurfaceOpacity, fromSurfaceOpacity, 0]
                handoff.keyTimes = [0, 0.65, 1]; handoff.duration = command.duration
                handoff.timingFunction = CAMediaTimingFunction(name: .linear)
                layer.add(handoff, forKey: "reading.card.handoff")
            }
        }
        layer.add(travel, forKey: "reading.travel")
        aperture.add(clip, forKey: "reading.aperture")
    }

    // Delegate delivery may be delayed by unrelated main-thread work. Only this
    // generation may admit content or close the route; the layers already finish
    // on the compositor even while that delivery is waiting.
    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag, let generation = anim.value(forKey: "generation") as? Int else { return }
        Task { @MainActor [weak self] in
            guard let self, let command, command.generation == generation,
                  completedGeneration != generation else { return }
            completedGeneration = generation
            onCompletion?(generation, command.closing)
        }
    }

    private func path(_ size: CGSize) -> CGPath {
        CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 22, cornerHeight: 22, transform: nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsInput, let hit = super.hitTest(point), hit !== self, hit !== surface else { return nil }
        return hit
    }

    func retire() {
        command = nil
        flight?.retire(); flight = nil; identity = nil
        onCompletion = nil
        surface.layer?.removeAllAnimations()
        aperture.removeAllAnimations()
        hosting?.layer?.removeAllAnimations()
        hosting?.removeFromSuperview()
        hosting = nil
    }
}

private final class ReadingPanelSurfaceView: NSView {
    override var isFlipped: Bool { true }
}
