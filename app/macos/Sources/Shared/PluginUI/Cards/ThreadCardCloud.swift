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
}

struct ThreadCardCloud: View {
    let running: Bool
    @Environment(\.threadCardCloudPalette) private var palette
    @Environment(\.threadCardCloudAnimationsEnabled) private var enabled
    @Environment(\.threadCardAnimationVisibility) private var visibility

    var body: some View {
        if let palette {
            NativeCloudLoading(palette: palette, intensity: running ? 1 : 0,
                               isAnimating: enabled && (visibility?.isVisible ?? true), motionSpeed: 1.4)
                .clipShape(RoundedRectangle(cornerRadius: NativeGeometry.overviewCardRadius))
                .animation(.easeInOut(duration: 0.4), value: running)
        }
    }
}
