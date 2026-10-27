import SwiftUI

/// Keep the live page mounted and the underlying route inert until return ends.
struct NativeSettingsOverlay<Content: View>: View {
    let state: NativeMokuSceneState
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var progress = 0.0
    @State private var generation = 0
    @State private var preparation: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            if state.settingsOpen {
                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .modifier(SettingsReveal(progress: progress, origin: state.settingsOrigin,
                        size: geometry.size))
                    .disabled(state.settingsClosing)
                    .allowsHitTesting(!state.settingsClosing)
                    .accessibilityHidden(state.settingsClosing)
            }
            Color.clear.allowsHitTesting(false)
                .onChange(of: geometry.size) { _, _ in settle() }
        }
        .onAppear {
            state.settingsSettle = { settle() }
            settle()
        }
        .onChange(of: state.settingsTransitionRequest) { _, _ in
            // Observe intent, not just a Boolean target: multiple requests can
            // coalesce into the same route/closing flags before the next frame.
            if !state.settingsOpen || reduceMotion || scenePhase != .active { settle() }
            else { animate(opening: !state.settingsClosing) }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { settle() } }
        .onChange(of: reduceMotion) { _, value in if value { settle() } }
        .onDisappear {
            settle()
            state.settingsSettle = nil
        }
    }

    private func settle() {
        preparation?.cancel(); preparation = nil
        generation += 1
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = state.settingsOpen && !state.settingsClosing ? 1 : 0
            state.finishSettingsTransition()
        }
    }

    private func animate(opening: Bool) {
        preparation?.cancel()
        generation += 1
        let token = generation
        let anchored = !state.settingsOrigin.isEmpty
        let duration = anchored ? (opening ? 0.48 : 0.38) : 0.16
        let curve = opening
            ? Animation.timingCurve(0.76, 0, 0.24, 1, duration: duration)
            : Animation.timingCurve(0.55, 0, 0.25, 1, duration: duration)
        preparation = Task { @MainActor in
            // Mount at the collapsed pose before committing the destination;
            // otherwise insertion can coalesce with the fully revealed page.
            do { try await Task.sleep(for: .seconds(2.0 / 60)) } catch { return }
            guard generation == token else { return }
            preparation = nil
            withAnimation(curve, completionCriteria: .removed) {
                progress = opening ? 1 : 0
            } completion: {
                guard generation == token else { return }
                state.finishSettingsTransition()
            }
        }
    }
}

private struct SettingsReveal: ViewModifier, @MainActor Animatable {
    var progress: Double
    let origin: CGRect
    let size: CGSize
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let center = origin.isEmpty ? CGPoint(x: size.width / 2, y: size.height / 2)
            : CGPoint(x: origin.midX, y: origin.midY)
        let fullRadius = hypot(max(abs(center.x), abs(size.width - center.x)),
            max(abs(center.y), abs(size.height - center.y))) + 2
        let initialRadius = origin.isEmpty ? fullRadius : min(origin.width, origin.height) / 2
        let radius = initialRadius + (fullRadius - initialRadius) * progress
        content.mask {
            Circle().frame(width: radius * 2, height: radius * 2).position(center)
        }
        .opacity(origin.isEmpty ? progress : min(1, progress / 0.12))
    }
}
