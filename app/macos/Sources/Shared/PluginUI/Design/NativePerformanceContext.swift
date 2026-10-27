import MokuseiCore
import SwiftUI

private struct NativePerformanceOperationKey: EnvironmentKey {
    static let defaultValue: UInt64? = nil
}

public extension EnvironmentValues {
    /// Ephemeral operation IDs, never business identities or a global current thread.
    var nativePerformanceOperation: UInt64? {
        get { self[NativePerformanceOperationKey.self] }
        set { self[NativePerformanceOperationKey.self] = newValue }
    }
}
