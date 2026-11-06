import AppKit
import MokuseiPluginUI
import QuartzCore
import SwiftUI

/// Retain the actual outgoing reader, including its scroll position, while a
/// second production reader acquires the completed execution. Only the incoming
/// host survives landing; no image capture or duplicate transcript renderer.
struct NativeExecutionHandoffReader<Content: View>: NSViewRepresentable {
    let handoff: NativeSidecardExecutionHandoff?
    let destinationSize: CGSize
    let workspaceSize: CGSize
    let reduceMotion: Bool
    let onComplete: (UUID) -> Void
    let onInputTargetChange: (ThreadConversationInputTarget?) -> Void
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> ExecutionHandoffReaderView { ExecutionHandoffReaderView() }
    func updateNSView(_ view: ExecutionHandoffReaderView, context: Context) {
        view.update(content: AnyView(content), environment: context.environment,
            handoff: handoff, destinationSize: destinationSize, workspaceSize: workspaceSize,
            reduced: reduceMotion, onComplete: onComplete, onInputTargetChange: onInputTargetChange)
    }
    static func dismantleNSView(_ view: ExecutionHandoffReaderView, coordinator: ()) { view.retire() }
}

@MainActor final class ExecutionHandoffReaderView: NSView {
    private var current = ExecutionHandoffReaderSeat()
    private var outgoing: ExecutionHandoffReaderSeat?
    private var currentContent: AnyView?
    private var outgoingContent: AnyView?
    private var preparation: NativeReadingContentPreparation?
    private var handoffID: UUID?
    private var pageStarted = false
    private var landed = false
    private var resized = false
    private var workspaceSize = CGSize.zero
    private var destinationSize = CGSize.zero
    private var sourceSize = CGSize.zero
    private var onComplete: ((UUID) -> Void)?
    private var onInputTargetChange: ((ThreadConversationInputTarget?) -> Void)?
    private var environment = EnvironmentValues()

    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(current)
    }
    required init?(coder: NSCoder) { nil }

    func update(content: AnyView, environment: EnvironmentValues, handoff: NativeSidecardExecutionHandoff?,
                destinationSize: CGSize, workspaceSize: CGSize, reduced: Bool,
                onComplete: @escaping (UUID) -> Void,
                onInputTargetChange: @escaping (ThreadConversationInputTarget?) -> Void) {
        self.onComplete = onComplete
        self.onInputTargetChange = onInputTargetChange
        self.environment = environment
        if self.workspaceSize != .zero, self.workspaceSize != workspaceSize, handoffID != nil { resized = true }
        self.workspaceSize = workspaceSize
        self.destinationSize = destinationSize
        if handoffID != handoff?.id {
            if let handoff {
                cancel()
                sourceSize = current.frame.size
                outgoing = current
                outgoingContent = currentContent
                current = ExecutionHandoffReaderSeat()
                addSubview(current)
                preparation = NativeReadingContentPreparation()
                handoffID = handoff.id
            } else {
                cancel()
            }
        }
        currentContent = content
        current.host.rootView = root(content, seat: current, active: handoff == nil || landed, preparation: preparation)
        // Refresh appearance and gate retained controls without replacing the
        // outgoing document, reading request or scroll model.
        if let outgoing, let outgoingContent { outgoing.host.rootView = root(outgoingContent, seat: outgoing, active: false) }
        layoutSeats()
        if let handoff, handoff.travelComplete, handoff.contentReady, !landed {
            if reduced || resized { finish(handoff.id) }
            else if !pageStarted { turnPage(handoff.id) }
        }
    }

    private func root(_ content: AnyView, seat: ExecutionHandoffReaderSeat, active: Bool,
                      preparation: NativeReadingContentPreparation? = nil) -> AnyView {
        // Keep this exact root structure during gating/landing. Dropping an
        // environment modifier would recreate the reader and its scroll state.
        var environment = environment
        environment.nativeReadingInteractionActive = environment.nativeReadingInteractionActive && active
        environment.nativeReadingContentPreparation = preparation
        return AnyView(content.allowsHitTesting(active).accessibilityHidden(!active)
            .onPreferenceChange(ThreadConversationInputTargetKey.self) { [weak self, weak seat] target in
                guard let self, let seat else { return }
                seat.inputTarget = target
                // Both hosts coexist through handoff. Retiring content may
                // still publish, but only the current native seat owns input.
                guard current === seat else { return }
                onInputTargetChange?(target)
            }
            .environment(\.self, environment))
    }

    override func layout() { super.layout(); layoutSeats() }
    private func layoutSeats() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if handoffID != nil {
            // Each document takes one width. The shell can widen without
            // proposing intermediate TextKit widths on every animation tick.
            let oldSize = resized ? CGSize(width: min(sourceSize.width, destinationSize.width), height: bounds.height) : sourceSize
            outgoing?.frame = CGRect(x: (bounds.width - oldSize.width) / 2, y: 0,
                width: oldSize.width, height: oldSize.height)
            current.frame = CGRect(x: (bounds.width - destinationSize.width) / 2, y: 0,
                width: destinationSize.width, height: destinationSize.height)
            // Keep the model viewport onscreen; only the compositor translates
            // pages vertically, otherwise TextKit can cull ink before arrival.
            current.alphaValue = pageStarted || landed ? 1 : 0
        } else {
            current.frame = bounds
            current.alphaValue = 1
        }
        CATransaction.commit()
    }

    private func turnPage(_ id: UUID) {
        guard bounds.height > 0, let outgoing else { return }
        pageStarted = true
        layoutSeats()
        let distance = bounds.height
        animate(outgoing.layer!, from: 0, to: -distance)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, handoffID == id, pageStarted, !landed else { return }
                finish(id)
            }
        }
        animate(current.layer!, from: distance, to: 0)
        CATransaction.commit()
    }

    private func animate(_ layer: CALayer, from: CGFloat, to: CGFloat) {
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = from; animation.toValue = to
        animation.duration = NativeReadingPageTiming.duration
        animation.timingFunction = NativeReadingPageTiming.replacementTimingFunction
        animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "execution.handoff.page")
    }

    private func finish(_ id: UUID) {
        guard handoffID == id, !landed else { return }
        landed = true
        current.layer?.removeAllAnimations()
        outgoing?.removeFromSuperview(); outgoing = nil
        outgoingContent = nil
        preparation?.cancel(); preparation = nil
        if let currentContent { current.host.rootView = root(currentContent, seat: current, active: true) }
        layoutSeats()
        // Never publish a workspace mutation during a hosting/layout update.
        DispatchQueue.main.async { [weak self] in
            guard let self, handoffID == id, landed else { return }
            onComplete?(id)
        }
    }

    private func cancel() {
        handoffID = nil; pageStarted = false; landed = false; resized = false
        preparation?.cancel(); preparation = nil
        current.layer?.removeAllAnimations()
        // Interrupted preparation/absorption keeps the original main reader.
        // An interruption after landing already owns the incoming host.
        if let outgoing {
            current.removeFromSuperview()
            current = outgoing; self.outgoing = nil
            currentContent = outgoingContent; outgoingContent = nil
            current.layer?.removeAllAnimations()
            // Restoring a retained host does not change its preference value.
            // Republish its target, fenced against another replacement/teardown.
            DispatchQueue.main.async { [weak self, weak outgoing] in
                guard let self, let outgoing, current === outgoing else { return }
                onInputTargetChange?(outgoing.inputTarget)
            }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        handoffID != nil && !landed ? nil : super.hitTest(point)
    }
    override func accessibilityChildren() -> [Any]? {
        handoffID != nil && !landed ? [] : super.accessibilityChildren()
    }
    func retire() {
        cancel(); onComplete = nil; onInputTargetChange = nil; currentContent = nil
        current.host.rootView = AnyView(EmptyView())
    }
}

private final class ExecutionHandoffReaderSeat: NSView {
    var inputTarget: ThreadConversationInputTarget?
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        host.sizingOptions = []; host.safeAreaRegions = []
        addSubview(host)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); host.frame = bounds }
}
