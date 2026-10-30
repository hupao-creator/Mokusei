import Observation
import SwiftUI

/// A native canvas updates this value without replacing the card's SwiftUI root.
@MainActor @Observable
public final class ThreadCardAnimationVisibility {
    public var isVisible: Bool
    public init(isVisible: Bool = true) { self.isVisible = isVisible }
}

private struct ThreadCardCloudPaletteKey: EnvironmentKey {
    static let defaultValue: NativeCloudPalette? = nil
}
private struct ThreadCardCloudAnimationsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}
private struct ThreadCardAnimationVisibilityKey: EnvironmentKey {
    static let defaultValue: ThreadCardAnimationVisibility? = nil
}
private struct ThreadCardDecorationsIsolatedKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Harness-owned colors; a shared card never looks up a harness by ID.
    var threadCardCloudPalette: NativeCloudPalette? {
        get { self[ThreadCardCloudPaletteKey.self] }
        set { self[ThreadCardCloudPaletteKey.self] = newValue }
    }
    /// The workspace pauses drawing while the overview or document is hidden.
    var threadCardCloudAnimationsEnabled: Bool {
        get { self[ThreadCardCloudAnimationsEnabledKey.self] }
        set { self[ThreadCardCloudAnimationsEnabledKey.self] = newValue }
    }
    /// Per-card viewport and window visibility, supplied by the native canvas.
    var threadCardAnimationVisibility: ThreadCardAnimationVisibility? {
        get { self[ThreadCardAnimationVisibilityKey.self] }
        set { self[ThreadCardAnimationVisibilityKey.self] = newValue }
    }
    /// Overview opts its continuous decorations into separate drawing graphs.
    var threadCardDecorationsIsolated: Bool {
        get { self[ThreadCardDecorationsIsolatedKey.self] }
        set { self[ThreadCardDecorationsIsolatedKey.self] = newValue }
    }
}

struct ThreadCardCloud: View {
    let running: Bool
    @Environment(\.threadCardCloudPalette) private var palette
    @Environment(\.threadCardCloudAnimationsEnabled) private var enabled
    @Environment(\.threadCardAnimationVisibility) private var visibility
    @Environment(\.threadCardDecorationsIsolated) private var isolated

    var body: some View {
        if let palette {
            let cloud = ThreadCardCloudDrawing(palette: palette, running: running,
                animates: enabled && (visibility?.isVisible ?? true))
            if isolated {
                NativeCardDecorationHost(content: cloud)
            } else {
                cloud
            }
        }
    }
}

private struct ThreadCardCloudDrawing: View {
    let palette: NativeCloudPalette
    let running: Bool
    let animates: Bool

    var body: some View {
        NativeCloudLoading(palette: palette, intensity: running ? 1 : 0,
                           isAnimating: animates, motionSpeed: 1.4)
            .clipShape(RoundedRectangle(cornerRadius: NativeGeometry.overviewCardRadius))
            // The fade belongs to the drawing graph, including after a native
            // host receives a new root value. Keep its seed and clock mounted.
            .animation(.easeInOut(duration: 0.4), value: running)
    }
}
