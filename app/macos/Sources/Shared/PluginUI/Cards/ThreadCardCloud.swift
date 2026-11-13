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
private struct ThreadCardNativeDecorationsEnabledKey: EnvironmentKey {
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
    /// Overview opts into native drawing; shared card consumers keep their renderer.
    var threadCardNativeDecorationsEnabled: Bool {
        get { self[ThreadCardNativeDecorationsEnabledKey.self] }
        set { self[ThreadCardNativeDecorationsEnabledKey.self] = newValue }
    }
}

struct ThreadCardCloud: View {
    let running: Bool
    @Environment(\.threadCardCloudPalette) private var palette
    @Environment(\.threadCardCloudAnimationsEnabled) private var enabled
    @Environment(\.threadCardAnimationVisibility) private var visibility
    @Environment(\.threadCardNativeDecorationsEnabled) private var nativeDecorations

    var body: some View {
        if let palette {
            Group {
                if nativeDecorations && NativeOverviewCloudView.isAvailable {
                    NativeOverviewCloudView(palette: palette, running: running,
                        isAnimating: enabled && (visibility?.isVisible ?? true),
                        isVisible: visibility?.isVisible ?? true)
                } else {
                    NativeCloudLoading(palette: palette, intensity: running ? 1 : 0,
                                       isAnimating: enabled && (visibility?.isVisible ?? true), motionSpeed: 1.4)
                        .animation(.easeInOut(duration: 0.4), value: running)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: NativeGeometry.overviewCardRadius))
        }
    }
}
