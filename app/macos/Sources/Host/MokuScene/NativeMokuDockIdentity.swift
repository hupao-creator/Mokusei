import AppKit
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import Observation
import QuartzCore
import SwiftUI

/// Only the passive mark flips. The editor, its layout seat and native input
/// lifecycle are independent of Thread/Harness identity changes.
struct NativeMokuDockIdentity<Face: View>: View {
    let harness: AnyHarnessPlugin?
    let showsHarness: Bool
    let entranceReady: Bool
    let generation: UUID
    let motion: Bool
    let onSettled: () -> Void
    @ViewBuilder var face: Face
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NativeMokuIdentitySurface(identity: showsHarness ? .harness(harness?.descriptor.id) : .moku,
            entranceReady: entranceReady, composer: generation,
            immediate: reduceMotion || !motion || scenePhase != .active,
            face: AnyView(face), logo: AnyView(logo), onSettled: onSettled)
            .frame(width: NativeMokuFaceLayout.seat.width, height: NativeMokuFaceLayout.seat.height)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var logo: some View {
        if let harness { harness.logo(size: 24) }
        else { Image(systemName: "terminal").font(.system(size: 22)) }
    }
}

private enum MokuDockIdentity: Equatable {
    case moku, harness(JSONText?)
    var isHarness: Bool { if case .harness = self { true } else { false } }
}

private struct NativeMokuIdentitySurface: NSViewRepresentable {
    let identity: MokuDockIdentity
    let entranceReady: Bool
    let composer: UUID
    let immediate: Bool
    let face: AnyView
    let logo: AnyView
    let onSettled: () -> Void

    func makeNSView(context: Context) -> MokuIdentityView { MokuIdentityView() }
    func updateNSView(_ view: MokuIdentityView, context: Context) {
        view.configure(identity: identity, entranceReady: entranceReady, composer: composer,
            immediate: immediate,
            face: AnyView(face.environment(\.self, context.environment)),
            logo: AnyView(logo.environment(\.self, context.environment)),
            transaction: context.transaction, onSettled: onSettled)
    }
    static func dismantleNSView(_ view: MokuIdentityView, coordinator: ()) { view.retire() }
}

@MainActor private final class MokuIdentityView: NSView, CAAnimationDelegate {
    private struct Receipt: Equatable {
        let identity: MokuDockIdentity
        let composer: UUID
    }
    private var incoming: MokuIdentitySeat?
    private var outgoing: MokuIdentitySeat?
    private var generation = 0
    private var flipping = false
    private var receipt: Receipt?
    private var delivered: Receipt?
    private var onSettled: (() -> Void)?
    private var layoutSize: CGSize?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = false
    }
    required init?(coder: NSCoder) { nil }

    func configure(identity: MokuDockIdentity, entranceReady: Bool, composer: UUID,
                   immediate: Bool, face: AnyView, logo: AnyView, transaction: Transaction,
                   onSettled: @escaping () -> Void) {
        let nextReceipt = identity.isHarness && entranceReady ? Receipt(identity: identity, composer: composer) : nil
        if receipt != nextReceipt { delivered = nil }
        receipt = nextReceipt
        self.onSettled = onSettled
        let seats = [incoming, outgoing].compactMap { $0 }
        for seat in seats {
            if seat.identity == .moku { seat.update(face, transaction: transaction) }
            else if seat.identity == identity { seat.update(logo, transaction: transaction) }
        }
        // Keep the currently targeted mark through travel, including an Agent
        // continuation. A replacement composer borrows an unfinished same-mark
        // flip but cannot infer completion from that target alone.
        let target = identity.isHarness && !entranceReady ? incoming?.identity ?? .moku : identity
        if incoming?.identity == target {
            if flipping && (immediate || window == nil) { settle() }
            else if !flipping { reportCompletion() }
            return
        }

        generation += 1
        let token = generation
        let visible = seats.max { $0.pose.opacity < $1.pose.opacity }
        let next = seats.first { $0.identity == target }
            ?? MokuIdentitySeat(identity: target, content: target == .moku ? face : logo)
        let previousPose = visible?.pose
        for seat in seats where seat !== next && seat !== visible { seat.removeFromSuperview() }
        if next.superview == nil { addSubview(next) }
        next.frame = bounds
        incoming = next
        outgoing = visible === next ? nil : visible

        guard let visible, let previousPose, !immediate, window != nil else { settle(); return }
        flipping = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let outgoing {
            outgoing.layer?.removeAllAnimations()
            let animation = outgoing.prepareAnimation(from: previousPose, incoming: false, phased: true)
            outgoing.layer?.add(animation, forKey: "moku-identity")
        }
        next.layer?.removeAllAnimations()
        let pose = visible === next ? previousPose : MokuIdentitySeat.Pose(
            transform: MokuIdentitySeat.rotation(.pi / 2), opacity: 0)
        let animation = next.prepareAnimation(from: pose, incoming: true, phased: visible !== next)
        animation.delegate = self
        animation.setValue(token, forKey: "generation")
        next.layer?.add(animation, forKey: "moku-identity")
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for seat in [incoming, outgoing].compactMap({ $0 }) { seat.frame = bounds }
        CATransaction.commit()
        if let layoutSize, layoutSize != bounds.size { settle() }
        layoutSize = bounds.size
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Detach invalidates queued native delivery. Reattachment starts with
        // the settled target rather than reviving an offscreen animation.
        if window == nil { settle() }
        else { reportCompletion() }
    }

    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag, let token = anim.value(forKey: "generation") as? Int else { return }
        Task { @MainActor [weak self] in
            guard let self, generation == token else { return }
            settle()
        }
    }

    private func settle() {
        generation += 1
        flipping = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        incoming?.layer?.removeAllAnimations()
        incoming?.layer?.transform = CATransform3DIdentity
        incoming?.layer?.opacity = 1
        incoming?.startPose = nil
        outgoing?.layer?.removeAllAnimations()
        outgoing?.removeFromSuperview(); outgoing = nil
        CATransaction.commit()
        reportCompletion()
    }

    private func reportCompletion() {
        guard !flipping, window != nil, let receipt, incoming?.identity == receipt.identity,
              delivered != receipt else { return }
        let token = generation
        // Native and immediate completions share deferred, generation-fenced
        // delivery so updateNSView/layout cannot publish composer state.
        Task { @MainActor [weak self] in
            guard let self, generation == token, !flipping, window != nil,
                  self.receipt == receipt, delivered != receipt else { return }
            delivered = receipt
            onSettled?()
        }
    }

    func retire() {
        generation += 1; receipt = nil; onSettled = nil
        incoming?.layer?.removeAllAnimations(); incoming?.removeFromSuperview(); incoming = nil
        outgoing?.layer?.removeAllAnimations(); outgoing?.removeFromSuperview(); outgoing = nil
    }
}

@MainActor private final class MokuIdentitySeat: NSView {
    struct Pose { let transform: CATransform3D; let opacity: Float }
    let identity: MokuDockIdentity
    private let content: MokuIdentityContentState
    private let hosting: NSHostingView<MokuIdentityContent>
    var startPose: Pose?
    var pose: Pose {
        if let presented = layer?.presentation() {
            return Pose(transform: presented.transform, opacity: presented.opacity)
        }
        // A second route update can precede the first compositor commit.
        return startPose ?? Pose(transform: layer!.transform, opacity: layer!.opacity)
    }
    override var isFlipped: Bool { true }

    init(identity: MokuDockIdentity, content: AnyView) {
        self.identity = identity
        self.content = MokuIdentityContentState(content)
        hosting = NSHostingView(rootView: MokuIdentityContent(state: self.content))
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        layer?.isDoubleSided = false
        hosting.sizingOptions = []; hosting.safeAreaRegions = []
        hosting.clipsToBounds = false
        addSubview(hosting)
    }
    required init?(coder: NSCoder) { nil }

    func update(_ view: AnyView, transaction: Transaction) {
        withTransaction(transaction) { content.view = view }
    }
    override func layout() {
        super.layout()
        if hosting.frame != bounds { hosting.frame = bounds }
    }

    static func rotation(_ angle: CGFloat) -> CATransform3D {
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 120
        return CATransform3DRotate(perspective, angle, 1, 0, 0)
    }

    func prepareAnimation(from pose: Pose, incoming: Bool, phased: Bool) -> CAAnimationGroup {
        let target = incoming ? CATransform3DIdentity : Self.rotation(-.pi / 2)
        let transform = CAKeyframeAnimation(keyPath: "transform")
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        let from = NSValue(caTransform3D: pose.transform), to = NSValue(caTransform3D: target)
        if phased {
            transform.values = incoming ? [from, from, to] : [from, to, to]
            opacity.values = [pose.opacity, incoming ? Float(1) : Float(0), incoming ? Float(1) : Float(0)]
            transform.keyTimes = [0, 0.5, 1]; opacity.keyTimes = [0, 0.5, 1]
            opacity.calculationMode = .discrete
        } else {
            transform.values = [from, to]; opacity.values = [pose.opacity, Float(1)]
        }
        transform.duration = NativeReadingPageTiming.duration
        opacity.duration = NativeReadingPageTiming.duration
        let animation = CAAnimationGroup()
        animation.animations = [transform, opacity]
        animation.duration = NativeReadingPageTiming.duration
        animation.timingFunction = NativeReadingPageTiming.emphasizedOpening
        startPose = pose
        layer?.transform = target; layer?.opacity = incoming ? 1 : 0
        return animation
    }
}

@MainActor @Observable private final class MokuIdentityContentState {
    var view: AnyView
    init(_ view: AnyView) { self.view = view }
}

private struct MokuIdentityContent: View {
    let state: MokuIdentityContentState
    var body: some View { state.view }
}
