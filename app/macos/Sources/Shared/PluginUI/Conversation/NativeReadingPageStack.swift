import Observation
import MokuseiCore
import SwiftUI

@MainActor @Observable
public final class NativeReadingPageMotion {
    private final class WeakMotion { weak var value: NativeReadingPageMotion?; init(_ value: NativeReadingPageMotion) { self.value = value } }
    private static var registry: [WeakMotion] = []
    public fileprivate(set) var active = false
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
    public var onClose: () -> Void
    private let parent: Parent
    private let front: Front

    @Environment(\.scenePhase) private var scenePhase
    @State private var progress = 0.0
    @State private var closing = false
    @State private var generation = 0
    @State private var mountedIdentity: JSONText?
    @State private var animationTask: Task<Void, Never>?

    public init(open: Bool, identity: JSONText, motion: NativeReadingPageMotion,
                enabled: Bool = true, focusBlur: Bool = false, stationaryParent: Bool = false,
                emphasizedOpening: Bool = false, duration: TimeInterval = NativeReadingPageTiming.duration,
                onClose: @escaping () -> Void,
                @ViewBuilder parent: () -> Parent, @ViewBuilder front: () -> Front) {
        self.open = open; self.identity = identity; self.motion = motion; self.enabled = enabled
        self.focusBlur = focusBlur; self.stationaryParent = stationaryParent
        self.emphasizedOpening = emphasizedOpening; self.duration = duration
        self.onClose = onClose; self.parent = parent(); self.front = front()
    }
    public var body: some View {
        GeometryReader { bounds in
            ZStack {
                parent
                    .overlay { Color.black.opacity(0.14 * progress).allowsHitTesting(false) }
                    .blur(radius: focusBlur && motion.active ? 16 * progress : 0)
                    .offset(x: stationaryParent ? 0 : -0.25 * bounds.size.width * progress)
                    .opacity(open && !motion.active ? 0 : 1)
                    .allowsHitTesting(!open && enabled)
                    .disabled(open)
                    .accessibilityHidden(open)
                if open {
                    front.id(identity)
                        .frame(width: bounds.size.width, height: bounds.size.height)
                        .modifier(ReadingPageSurface(progress: progress, active: motion.active))
                        .offset(x: bounds.size.width * (1 - progress))
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
            // Replacing an already open route does not replay its entrance.
            if open && mountedIdentity != identity { settle() }
            mountedIdentity = identity
        }
        .onChange(of: scenePhase) { _, value in if value != .active { settle() } }
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
            motion.active = false
        }
    }

    private func animate(closing: Bool) {
        generation += 1
        let token = generation
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

/// The shadow travels with the opaque page and fades at both endpoints.
private struct ReadingPageSurface: ViewModifier, @MainActor Animatable {
    var progress: Double
    let active: Bool
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let envelope = max(0, min(1, min(progress, 1 - progress) / 0.15))
        content
            .clipShape(RoundedRectangle(cornerRadius: active ? 24 : 0))
            .shadow(color: .black.opacity(active ? 0.16 * envelope : 0), radius: 12, x: -8)
    }
}
