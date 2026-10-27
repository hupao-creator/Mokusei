/// Marks the synchronous binding write performed by an explicit option or
/// switch choice. Hosts can persist these immediately while debouncing typing.
@MainActor
public enum NativeSettingsChangeContext {
    private static var discreteDepth = 0

    public static var isDiscreteChange: Bool { discreteDepth > 0 }

    public static func withDiscreteChange<Value>(_ change: () throws -> Value) rethrows -> Value {
        discreteDepth += 1
        defer { discreteDepth -= 1 }
        return try change()
    }
}
