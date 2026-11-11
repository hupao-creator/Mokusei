import SwiftUI

private struct ThreadCardFlatMaterialsKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Card renderers opt into static surfaces; shared controls elsewhere keep
    /// their own material composition. This is not a user preference.
    var threadCardUsesFlatMaterials: Bool {
        get { self[ThreadCardFlatMaterialsKey.self] }
        set { self[ThreadCardFlatMaterialsKey.self] = newValue }
    }
}

public extension View {
    /// A system glass surface with an opaque accessibility fallback. Apply to
    /// the backdrop alone when foreground ink has an independent reveal mask.
    func nativeRegularCardGlass<S: Shape>(in shape: S, opaque: Color,
                                         tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(NativeRegularCardGlass(shape: shape, opaque: opaque, tint: tint, interactive: interactive))
    }
}

private struct NativeRegularCardGlass<S: Shape>: ViewModifier {
    let shape: S
    let opaque: Color
    let tint: Color?
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(opaque, in: shape)
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
