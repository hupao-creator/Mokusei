import AppKit
import Observation
import MokuseiCore
import SwiftUI

@MainActor @Observable
public final class NativeReadingPageMotion {
    private final class WeakMotion { weak var value: NativeReadingPageMotion?; init(_ value: NativeReadingPageMotion) { self.value = value } }
    private static var registry: [WeakMotion] = []
    public fileprivate(set) var active = false
    fileprivate var replacementDirection: CGFloat = 1
    @ObservationIgnored fileprivate var closeAction: (() -> Void)?
    @ObservationIgnored fileprivate var cancelAction: ((Bool) -> Void)?
    public init() { Self.registry.removeAll { $0.value == nil }; Self.registry.append(WeakMotion(self)) }
    public func close() { closeAction?() }
    public func cancel(finishingClose: Bool = false) { cancelAction?(finishingClose) }
    public static func cancelAll(finishingClose: Bool = false) {
        registry.forEach { $0.value?.cancel(finishingClose: finishingClose) }
    }
}

public struct NativeReadingPageStack<Parent: View, Front: View>: View {
    public let open: Bool
    public let identity: JSONText
    public let motion: NativeReadingPageMotion
    public var enabled: Bool
    public var focusBlur: Bool
    public var stationaryParent: Bool
    public var panel: Bool
    public var panelSource: CGRect?
    public var panelIdentity: NativeThreadIdentityVisit?
    public var threadPanelMotion: Bool
    public var emphasizedOpening: Bool
    public var duration: TimeInterval
    public var axis: Axis
    public var direction: CGFloat
    public var onClose: () -> Void
    public var onParentPresentationChange: ((Bool) -> Void)?
    public var prepareParent: (() async -> Void)?
    public var onPanelOutsideClick: (() -> Void)?
    private let parent: Parent
    private let front: Front

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0
    @State private var panelTransition: NativeReadingPanelTransition?
    @State private var panelContentReady = false
    @State private var closing = false
    @State private var preparingClose = false
    @State private var replacing = false
    @State private var generation = 0
    @State private var mountedIdentity: JSONText?
    @State private var animationTask: Task<Void, Never>?
    @State private var geometry = NativeReadingPageGeometry()

    public init(open: Bool, identity: JSONText, motion: NativeReadingPageMotion,
                enabled: Bool = true, focusBlur: Bool = false, stationaryParent: Bool = false,
                emphasizedOpening: Bool = false, panel: Bool = false, panelSource: CGRect? = nil,
                panelIdentity: NativeThreadIdentityVisit? = nil, threadPanelMotion: Bool = false, duration: TimeInterval = NativeReadingPageTiming.duration,
                axis: Axis = .horizontal,
                direction: CGFloat = 1,
                onParentPresentationChange: ((Bool) -> Void)? = nil,
                prepareParent: (() async -> Void)? = nil,
                onPanelOutsideClick: (() -> Void)? = nil,
                onClose: @escaping () -> Void,
                @ViewBuilder parent: () -> Parent, @ViewBuilder front: () -> Front) {
        self.open = open; self.identity = identity; self.motion = motion; self.enabled = enabled
        self.focusBlur = focusBlur; self.stationaryParent = stationaryParent
        self.emphasizedOpening = emphasizedOpening; self.duration = duration
        self.panel = panel; self.panelSource = panelSource
        self.panelIdentity = panelIdentity; self.threadPanelMotion = threadPanelMotion
        self.axis = axis
        self.direction = direction
        self.onParentPresentationChange = onParentPresentationChange; self.prepareParent = prepareParent
        self.onPanelOutsideClick = onPanelOutsideClick
        self.onClose = onClose; self.parent = parent(); self.front = front()
    }
    public var body: some View {
        GeometryReader { bounds in
            let geometryContext = NativeReadingPageGeometry.Context(identity: identity, axis: axis,
                direction: direction, size: bounds.size)
            // Observe replacement state even while motion is idle.
            let openingOrClosing = !replacing && motion.active
            let panelBounds = NativeReadingPanelGeometry.frame(in: bounds.size)
            ZStack {
                parent
                    .overlay { Color.black.opacity(axis == .horizontal ? 0.14 * progress : 0).allowsHitTesting(false) }
                    .blur(radius: panel ? 5 * progress : axis == .horizontal && focusBlur && motion.active ? 16 * progress : 0)
                    .offset(x: stationaryParent || axis == .vertical ? 0 : -0.25 * bounds.size.width * progress * direction,
                            y: stationaryParent || axis == .horizontal ? 0 : -bounds.size.height * progress * direction)
                    .opacity(panel ? 1 - 0.78 * progress : open && !openingOrClosing ? 0 : 1)
                    .allowsHitTesting(!open && enabled)
                    // Disabling removes the native scroller gutter. Defer that
                    // input gate until the vertical parent is offscreen; restore
                    // its layout during return preparation, before either page moves.
                    // History replacement never involves this hidden parent and
                    // must keep its keyboard input gate closed throughout.
                    .disabled(open && (axis == .horizontal || progress == 1 && !openingOrClosing))
                    .accessibilityHidden(open)
                if panel && open {
                    NativeReadingPanelBackdrop(panel: panelBounds,
                        onDismiss: enabled && !motion.active ? onPanelOutsideClick : nil)
                        .accessibilityHidden(true)
                }
                if open && panel {
                    NativeReadingPanelViewport(target: panelBounds, source: panelSource,
                        open: panelContentReady || panelTransition != nil,
                        transition: panelTransition, contentReady: panelContentReady,
                        identity: reduceMotion ? nil : panelIdentity,
                        onCompletion: finishPanelTransition,
                        content: front.id(identity)
                            .environment(\.nativeThreadIdentityVisit, reduceMotion ? nil : panelIdentity)
                            .environment(\.nativeReadingPanelClosing, closing))
                } else if open {
                    ZStack {
                        front.id(identity)
                            .transition(axis == .vertical ? .asymmetric(
                                insertion: .modifier(
                                    active: ReadingPageReplacementOffset(travel: bounds.size.height, motion: motion),
                                    identity: ReadingPageReplacementOffset(travel: 0, motion: motion)),
                                removal: .modifier(
                                    active: ReadingPageReplacementOffset(travel: -bounds.size.height, motion: motion),
                                    identity: ReadingPageReplacementOffset(travel: 0, motion: motion))) : .identity)
                    }
                        // Limit replacement animation to the history identities;
                        // opening/return travel and timeline layout have their own owners.
                        .animation(axis == .vertical && direction != 0 && !reduceMotion ? curve : nil, value: identity)
                        .frame(width: panel ? panelBounds.width + 76 : bounds.size.width, height: panel ? panelBounds.height : bounds.size.height)
                        .background {
                            if axis == .horizontal {
                                NativeReadingPageAnchor(geometry: geometry, role: .front, geometryContext: geometryContext)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .modifier(ReadingPageSurface(progress: progress, active: !panel && motion.active && axis == .horizontal, axis: axis, clips: !panel))
                        .offset(x: !panel && axis == .horizontal ? bounds.size.width * (1 - progress) * direction : 0,
                                y: axis == .vertical ? bounds.size.height * (1 - progress) * direction : 0)
                }
            }
            .background {
                if axis == .horizontal {
                    NativeReadingPageAnchor(geometry: geometry, role: .root, geometryContext: geometryContext)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: bounds.size) { _, _ in settle(finishingClose: true) }
        }
        .clipped()
        .disabled(!enabled)
        .accessibilityElement(children: .contain)
        .onAppear {
            bindActions()
            mountedIdentity = identity
            settle()
        }
        .onChange(of: open) { _, value in
            bindActions()
            if value && enabled { mountedIdentity = identity; animate(closing: false) }
            else { settle() }
        }
        .onChange(of: identity) { _, _ in
            bindActions()
            if open && mountedIdentity != identity {
                settle()
                if axis == .vertical && direction != 0 && enabled && !reduceMotion { trackReplacement() }
            }
            mountedIdentity = identity
        }
        .onChange(of: scenePhase) { _, value in if value != .active { settle(finishingClose: true) } }
        .onChange(of: direction, initial: true) { _, value in
            motion.replacementDirection = value
            bindActions()
        }
        .onChange(of: reduceMotion) { _, value in
            bindActions()
            if value {
                settle(finishingClose: true)
            }
        }
        .onChange(of: enabled) { _, value in
            bindActions()
            if !value { settle() }
        }
        .onDisappear {
            settle()
            motion.closeAction = nil; motion.cancelAction = nil
        }
    }

    private func bindActions() {
        motion.closeAction = { requestClose() }
        motion.cancelAction = { settle(finishingClose: $0) }
    }

    private func requestClose() {
        guard open, !closing, !preparingClose else { return }
        // Reversing an opening uses the already participating parent immediately.
        // Only a settled detail needs to refresh its retained, paused backdrop.
        guard let prepareParent, !motion.active else {
            if enabled { animate(closing: true) }
            else { onClose() }
            return
        }
        generation += 1
        let token = generation
        preparingClose = true
        motion.active = true
        onParentPresentationChange?(true)
        animationTask = Task { @MainActor in
            guard !Task.isCancelled, generation == token else { return }
            await prepareParent()
            guard !Task.isCancelled, generation == token else { return }
            preparingClose = false
            motion.active = false
            if enabled { animate(closing: true) }
            else { onClose() }
        }
    }

    private func settle(finishingClose: Bool = false) {
        panelIdentity?.finish()
        // Layout/activation can interrupt the animation after Close was accepted.
        // Complete that visit's intent, but never close a replacement route or
        // turn an explicit cancellation into navigation.
        let finishClose = finishingClose && (closing || preparingClose) && open && mountedIdentity == identity
        animationTask?.cancel(); animationTask = nil
        generation += 1
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = open ? 1 : 0
            panelTransition = nil
            panelContentReady = open
            closing = false
            preparingClose = false
            replacing = false
            motion.active = false
        }
        onParentPresentationChange?(!open || finishClose)
        if finishClose { onClose() }
    }

    private var curve: Animation { .timingCurve(0.42, 0, 0.58, 1, duration: duration) }

    private func trackReplacement() {
        replacing = true
        motion.active = true
        let token = generation
        animationTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(duration + 2.0 / 60)) } catch { return }
            guard generation == token else { return }
            replacing = false
            motion.active = false
            animationTask = nil
        }
    }

    private func finishPanelTransition(_ token: Int, _ wasClosing: Bool) {
        guard generation == token, panelTransition?.generation == token else { return }
        panelTransition = nil
        motion.active = false
        closing = false
        if wasClosing { onClose() }
        else {
            panelContentReady = true
            onParentPresentationChange?(false)
        }
    }

    private func animate(closing: Bool) {
        // Freeze Overview's display projection before mounting a panel. Its
        // authoritative catalog still receives updates, and return preparation
        // refreshes the retained canvas before closing begins.
        onParentPresentationChange?(!panel || closing)
        guard !reduceMotion, closing || direction != 0 else {
            settle()
            if closing { onClose() }
            return
        }
        if panel {
            animationTask?.cancel(); animationTask = nil
            generation += 1
            replacing = false
            self.closing = closing
            motion.active = true
            if !closing { panelContentReady = false }
            panelTransition = NativeReadingPanelTransition(generation: generation, closing: closing,
                duration: duration, emphasized: !closing && emphasizedOpening, thread: threadPanelMotion)
            // Only the backdrop uses SwiftUI interpolation; panel geometry and
            // its completion belong to the native compositor, with no tick task.
            withAnimation(!closing && emphasizedOpening
                ? .timingCurve(0.76, 0, 0.24, 1, duration: duration) : curve) {
                progress = closing ? 0 : 1
            }
            return
        }
        let returningDuringOpening = closing && axis == .horizontal && motion.active && !self.closing && !replacing
        animationTask?.cancel()
        generation += 1
        let token = generation
        let initialProgress: Double
        if !panel, returningDuringOpening, let displayed = geometry.progress(identity: identity, direction: direction) {
            // A queued SwiftUI update can be ahead of the native geometry at
            // the click. Retarget from that committed pose, without flushing
            // pending layout or advancing the opening before reversing it.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { progress = displayed }
            initialProgress = displayed
        } else { initialProgress = progress }
        replacing = false
        self.closing = closing
        motion.active = true
        // Progress is stepped here rather than through `withAnimation`: an
        // implicit animation keeps its own additive presentation after a later
        // state change, so `settle()` could not stop a cancelled opening and a
        // history replacement begun during one would start from a page that is
        // not adjoined to its neighbour.
        let controlPoints: (x1: Double, x2: Double) = !closing && emphasizedOpening
            ? (0.76, 0.24) : (0.42, 0.58)
        let targetProgress = closing ? 0.0 : 1.0
        animationTask = Task { @MainActor in
            // Commit the offscreen front (or reveal the blurred retained
            // parent on return) before advancing the shared timeline. Without
            // preparation SwiftUI can coalesce insertion with its final pose.
            do { try await Task.sleep(for: .seconds(2.0 / 60)) } catch { return }
            guard generation == token else { return }
            let start = ContinuousClock.now
            while true {
                // Check before writing: a settle may have run between the
                // previous frame and this task resuming.
                guard generation == token else { return }
                let elapsed = start.duration(to: .now)
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                let time = min(1, seconds / duration)
                let eased = NativeReadingPageTiming.sample(x1: controlPoints.x1, x2: controlPoints.x2, at: time)
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { progress = initialProgress + (targetProgress - initialProgress) * eased }
                guard time < 1 else { break }
                do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
            }
            guard generation == token else { return }
            animationTask = nil
            motion.active = false
            self.closing = false
            if !closing { onParentPresentationChange?(false) }
            // Keep destination, navigation and selection until return ends.
            if closing { onClose() }
        }
    }
}

/// A departing view retains its insertion-time transition. Read the live
/// direction so reversing TOC order does not send both pages to the same edge.
private struct ReadingPageReplacementOffset: ViewModifier, @MainActor Animatable {
    var travel: CGFloat
    let motion: NativeReadingPageMotion
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }
    func body(content: Content) -> some View {
        content.offset(y: travel * motion.replacementDirection)
    }
}

/// The shadow travels with the opaque page and fades at both endpoints.
private struct ReadingPageSurface: ViewModifier, @MainActor Animatable {
    var progress: Double
    let active: Bool
    let axis: Axis
    let clips: Bool
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let envelope = max(0, min(1, min(progress, 1 - progress) / 0.15))
        if clips {
            content.clipShape(RoundedRectangle(cornerRadius: active ? 24 : 0))
                .shadow(color: .black.opacity(active ? 0.16 * envelope : 0), radius: 12,
                        x: axis == .horizontal ? -8 : 0, y: axis == .vertical ? -8 : 0)
        } else {
            // Panel shells clip themselves; their launchers deliberately live
            // outside the reader's frame, within the enclosing workspace.
            content
        }
    }
}

/// These anchors belong to the two viewport surfaces, not to a history identity's
/// transitioning content. Geometry is read only when reversing an opening.
@MainActor final class NativeReadingPageGeometry {
    enum Role { case root, front }
    struct Context: Equatable {
        let identity: JSONText
        let axis: Axis
        let direction: CGFloat
        let size: CGSize
    }
    private weak var root: NativeReadingPageAnchorView?
    private weak var front: NativeReadingPageAnchorView?

    func install(_ view: NativeReadingPageAnchorView, role: Role, context: Context) {
        if owns(view, role: role), view.geometryContext == context { return }
        if view.owner !== self { view.owner?.remove(view) }
        view.owner = self
        view.geometryContext = context
        switch role { case .root: root = view; case .front: front = view }
    }

    func remove(_ view: NativeReadingPageAnchorView) {
        if root === view { root = nil }
        if front === view { front = nil }
        if view.owner === self { view.owner = nil; view.geometryContext = nil }
    }

    func owns(_ view: NativeReadingPageAnchorView, role: Role) -> Bool {
        guard view.owner === self else { return false }
        switch role { case .root: return root === view; case .front: return front === view }
    }

    func progress(identity: JSONText, direction: CGFloat) -> Double? {
        guard let root, let front, root !== front, owns(root, role: .root), owns(front, role: .front),
              let rootContext = root.geometryContext, let frontContext = front.geometryContext else { return nil }
        let rootWindow = root.window
        let frontWindow = front.window
        guard let window = rootWindow, frontWindow === window,
              root.ancestorShared(with: front) != nil else { return nil }
        let rootBounds = root.bounds
        let frontFrame = front.convert(front.bounds, to: root)
        let tolerance = 1 / max(1, window.backingScaleFactor)
        return Self.progress(rootBounds: rootBounds, frontFrame: frontFrame,
            rootContext: rootContext, frontContext: frontContext,
            identity: identity, direction: direction, tolerance: tolerance)
    }

    static func progress(rootBounds: CGRect, frontFrame: CGRect, rootContext: Context, frontContext: Context,
                         identity: JSONText, direction: CGFloat, tolerance: CGFloat) -> Double? {
        guard rootContext == frontContext, rootContext.identity == identity,
              rootContext.axis == .horizontal, rootContext.direction == direction else { return nil }
        let size = rootContext.size
        let values = [rootBounds.origin.x, rootBounds.origin.y, rootBounds.width, rootBounds.height,
            frontFrame.origin.x, frontFrame.origin.y, frontFrame.width, frontFrame.height,
            size.width, size.height, direction, tolerance]
        guard values.allSatisfy({ $0.isFinite }), size.width > 0, size.height > 0,
              abs(direction) == 1, tolerance >= 0, rootBounds.width > 0, rootBounds.height > 0,
              abs(rootBounds.width - size.width) <= tolerance, abs(rootBounds.height - size.height) <= tolerance,
              abs(frontFrame.width - size.width) <= tolerance, abs(frontFrame.height - size.height) <= tolerance,
              abs(frontFrame.minY - rootBounds.minY) <= tolerance else { return nil }
        let travel = rootBounds.width * direction
        guard travel.isFinite, travel != 0 else { return nil }
        let progress = 1 - (frontFrame.minX - rootBounds.minX) / travel
        let rounding = tolerance / abs(travel)
        guard progress.isFinite, progress >= -rounding, progress <= 1 + rounding else { return nil }
        return Double(min(1, max(0, progress)))
    }
}

private struct NativeReadingPageAnchor: NSViewRepresentable {
    let geometry: NativeReadingPageGeometry
    let role: NativeReadingPageGeometry.Role
    let geometryContext: NativeReadingPageGeometry.Context
    func makeNSView(context: Context) -> NativeReadingPageAnchorView { NativeReadingPageAnchorView() }
    func updateNSView(_ view: NativeReadingPageAnchorView, context: Context) {
        geometry.install(view, role: role, context: geometryContext)
    }
    static func dismantleNSView(_ view: NativeReadingPageAnchorView, coordinator: ()) { view.owner?.remove(view) }
}

@MainActor final class NativeReadingPageAnchorView: NSView {
    fileprivate(set) weak var owner: NativeReadingPageGeometry?
    fileprivate var geometryContext: NativeReadingPageGeometry.Context?
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}

/// Shared by the production shell and native fixture. Margins yield only when
/// the viewport cannot support a readable compact surface.
public enum NativeReadingPanelGeometry {
    public static func frame(in size: CGSize) -> CGRect {
        let horizontal = min(76, max(12, (size.width - 320) / 2))
        let top = min(58, max(12, size.height * 0.1))
        let bottom = min(88, max(12, size.height * 0.15))
        return CGRect(x: horizontal, y: top, width: max(1, size.width - 2 * horizontal), height: max(1, size.height - top - bottom))
    }
}
