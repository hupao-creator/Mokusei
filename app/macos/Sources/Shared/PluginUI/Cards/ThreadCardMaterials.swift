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
