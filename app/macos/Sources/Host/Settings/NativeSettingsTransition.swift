import SwiftUI

// The scene supplies the page; the resident Dock owns its single glass surface.
// This slot keeps Settings independent of the composer's execution dependencies.
extension EnvironmentValues {
    @Entry var nativeMokuSettingsContent = AnyView(EmptyView())
}

/// Keep modal admission and the live page until the capsule finishes returning.
struct NativeSettingsTransition: ViewModifier {
    let state: NativeMokuSceneState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var generation = 0
    @State private var preparation: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in settle() }
            .onAppear {
                state.settingsSettle = { settle() }
                settle()
            }
            .onChange(of: state.settingsTransitionRequest) { _, _ in
                if !state.settingsOpen || reduceMotion || scenePhase != .active { settle() }
                else { animate() }
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
            state.settingsExpanded = state.settingsOpen && !state.settingsClosing
            state.finishSettingsTransition()
        }
    }

    private func animate() {
        preparation?.cancel()
        generation += 1
        let token = generation
        preparation = Task { @MainActor in
            // Mount the page at its final layout before expanding the resident
            // shell. Reversals redirect current geometry and fence old completions.
            do { try await Task.sleep(for: .seconds(2.0 / 60)) } catch { return }
            guard generation == token else { return }
            preparation = nil
            withAnimation(.smooth(duration: 0.42, extraBounce: 0), completionCriteria: .removed) {
                state.settingsExpanded = !state.settingsClosing
            } completion: {
                guard generation == token else { return }
                state.finishSettingsTransition()
            }
        }
    }
}
