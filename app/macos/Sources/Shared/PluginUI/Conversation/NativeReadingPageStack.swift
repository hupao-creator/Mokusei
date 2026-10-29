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
    @ObservationIgnored fileprivate var cancelAction: (() -> Void)?
    public init() { Self.registry.removeAll { $0.value == nil }; Self.registry.append(WeakMotion(self)) }
    public func close() { closeAction?() }
    public func cancel() { cancelAction?() }
    public static func cancelAll() { registry.forEach { $0.value?.cancel() } }
}

public struct NativeReadingPageStack<Parent: View, Front: View>: View {
    public let open: Bool
    public let identity: JSONText
    public let motion: NativeReadingPageMotion
    public var enabled: Bool
    public var focusBlur: Bool
    public var stationaryParent: Bool
    public var emphasizedOpening: Bool
    public var duration: TimeInterval
    public var axis: Axis
    public var direction: CGFloat
    public var onClose: () -> Void
    private let parent: Parent
    private let front: Front

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0
    @State private var closing = false
    @State private var replacing = false
    @State private var generation = 0
    @State private var mountedIdentity: JSONText?
    @State private var animationTask: Task<Void, Never>?

    public init(open: Bool, identity: JSONText, motion: NativeReadingPageMotion,
                enabled: Bool = true, focusBlur: Bool = false, stationaryParent: Bool = false,
                emphasizedOpening: Bool = false, duration: TimeInterval = NativeReadingPageTiming.duration,
                axis: Axis = .horizontal,
                direction: CGFloat = 1,
                onClose: @escaping () -> Void,
                @ViewBuilder parent: () -> Parent, @ViewBuilder front: () -> Front) {
        self.open = open; self.identity = identity; self.motion = motion; self.enabled = enabled
        self.focusBlur = focusBlur; self.stationaryParent = stationaryParent
        self.emphasizedOpening = emphasizedOpening; self.duration = duration
        self.axis = axis
        self.direction = direction
        self.onClose = onClose; self.parent = parent(); self.front = front()
    }
    public var body: some View {
        GeometryReader { bounds in
            ZStack {
                parent
                    .overlay { Color.black.opacity(axis == .horizontal ? 0.14 * progress : 0).allowsHitTesting(false) }
                    .blur(radius: axis == .horizontal && focusBlur && motion.active ? 16 * progress : 0)
                    .offset(x: stationaryParent || axis == .vertical ? 0 : -0.25 * bounds.size.width * progress * direction,
                            y: stationaryParent || axis == .horizontal ? 0 : -bounds.size.height * progress * direction)
                    .opacity(replacing || open && !motion.active ? 0 : 1)
                    .allowsHitTesting(!open && enabled)
                    // Disabling removes the native scroller gutter. Defer that
                    // input gate until the vertical parent is offscreen; restore
                    // its layout during return preparation, before either page moves.
                    .disabled(open && (axis == .horizontal || progress == 1 && !motion.active))
                    .accessibilityHidden(open)
                if open {
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
                        .frame(width: bounds.size.width, height: bounds.size.height)
                        .modifier(ReadingPageSurface(progress: progress, active: motion.active && axis == .horizontal, axis: axis))
                        .offset(x: axis == .horizontal ? bounds.size.width * (1 - progress) * direction : 0,
                                y: axis == .vertical ? bounds.size.height * (1 - progress) * direction : 0)
                }
            }
            .onChange(of: bounds.size) { _, _ in settle() }
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
        .onChange(of: scenePhase) { _, value in if value != .active { settle() } }
        .onChange(of: direction, initial: true) { _, value in
            motion.replacementDirection = value
            bindActions()
        }
        .onChange(of: reduceMotion) { _, value in
            bindActions()
            if value {
                let finishClose = closing
                settle()
                if finishClose { onClose() }
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
        motion.closeAction = {
            guard open, !closing else { return }
            if enabled { animate(closing: true) }
            else { onClose() }
        }
        motion.cancelAction = { settle() }
    }

    private func settle() {
        animationTask?.cancel(); animationTask = nil
        generation += 1
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = open ? 1 : 0
            closing = false
            replacing = false
            motion.active = false
        }
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

    private func animate(closing: Bool) {
        guard !reduceMotion, closing || direction != 0 else {
            settle()
            if closing { onClose() }
            return
        }
        generation += 1
        let token = generation
        replacing = false
        self.closing = closing
        motion.active = true
        let curve = !closing && emphasizedOpening
            ? Animation.timingCurve(0.76, 0, 0.24, 1, duration: duration)
            : Animation.timingCurve(0.42, 0, 0.58, 1, duration: duration)
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            // Commit the offscreen front (or reveal the blurred retained
            // parent on return) before advancing the shared timeline. Without
            // preparation SwiftUI can coalesce insertion with its final pose.
            do { try await Task.sleep(for: .seconds(2.0 / 60)) } catch { return }
            guard generation == token else { return }
            animationTask = nil
            withAnimation(curve, completionCriteria: .removed) {
                progress = closing ? 0 : 1
            } completion: {
                guard generation == token else { return }
                motion.active = false
                self.closing = false
                // Keep destination, navigation and selection until return ends.
                if closing { onClose() }
            }
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
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let envelope = max(0, min(1, min(progress, 1 - progress) / 0.15))
        content
            .clipShape(RoundedRectangle(cornerRadius: active ? 24 : 0))
            .shadow(color: .black.opacity(active ? 0.16 * envelope : 0), radius: 12,
                    x: axis == .horizontal ? -8 : 0, y: axis == .vertical ? -8 : 0)
    }
}
