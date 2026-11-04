import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Only the passive mark flips. The editor, its layout seat and native input
/// lifecycle are independent of Thread/Harness identity changes.
struct NativeMokuDockIdentity<Face: View>: View {
    let harness: AnyHarnessPlugin?
    let showsHarness: Bool
    @ViewBuilder var face: Face
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Identity: Hashable { case moku, harness(JSONText?) }
    private var identity: Identity { showsHarness ? .harness(harness?.descriptor.id) : .moku }
    private var transition: AnyTransition {
        reduceMotion ? .identity : .asymmetric(
            insertion: .modifier(active: NativeMokuIdentityFlip(progress: 0, incoming: true),
                identity: NativeMokuIdentityFlip(progress: 1, incoming: true)),
            removal: .modifier(active: NativeMokuIdentityFlip(progress: 0, incoming: false),
                identity: NativeMokuIdentityFlip(progress: 1, incoming: false)))
    }

    var body: some View {
        ZStack {
            if showsHarness {
                Group {
                    if let harness { harness.logo(size: 24) }
                    else { Image(systemName: "terminal").font(.system(size: 22)) }
                }
                .frame(width: NativeMokuFaceLayout.seat.width, height: NativeMokuFaceLayout.seat.height)
                .id(identity)
                .transition(transition)
            } else {
                face.transition(transition)
            }
        }
        .frame(width: NativeMokuFaceLayout.seat.width, height: NativeMokuFaceLayout.seat.height)
        .animation(reduceMotion ? nil : NativeReadingPageTiming.openingAnimation, value: identity)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct NativeMokuIdentityFlip: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat
    let incoming: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        // Retire the front in the first half, then reveal the back. Both rotate
        // downward about the same horizontal axis, with no mirrored back face.
        let visible = min(1, max(0, progress * 2 - 1))
        content
            .rotation3DEffect(.degrees(reduceMotion ? 0 : Double((incoming ? 90 : -90) * (1 - visible))),
                axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .opacity(visible > 0 ? 1 : 0)
    }
}
