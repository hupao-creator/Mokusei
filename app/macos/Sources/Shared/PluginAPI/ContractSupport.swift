import Foundation
import MokuseiCore

/// A malformed contract is surfaced to the owning surface, never replaced with empty content.
public struct PluginContractError: Error, Sendable, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// Each plugin owns decoding and encoding of its settings and application payloads.
/// Values remain lossless JSON until the owning plugin elects to interpret them.
@MainActor
public struct PluginValueCodec<Value> {
    public let decode: (JSONValue) throws -> Value
    public let encode: (Value) throws -> JSONValue
    public init(decode: @escaping (JSONValue) throws -> Value,
                encode: @escaping (Value) throws -> JSONValue) {
        self.decode = decode
        self.encode = encode
    }
}

extension PluginValueCodec where Value == JSONValue {
    public static var json: Self { Self(decode: { $0 }, encode: { $0 }) }
}

public enum PluginTheme: String, Sendable { case light, dark }
public typealias HarnessTranslationDictionary = [JSONText: JSONText]
public typealias HarnessTranslationCatalog = [JSONText: HarnessTranslationDictionary]

/// Single-owner cancellation for native view reads. Cancelling a view
/// does not stop a runtime participant or revoke an already accepted command.
@MainActor
public final class PluginLifetime {
    public private(set) var isCancelled = false
    private var handlers: [UUID: () -> Void] = [:]
    public init() {}
    @discardableResult
    public func onCancel(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        if isCancelled { handler() } else { handlers[id] = handler }
        return id
    }
    public func removeHandler(_ id: UUID) { handlers[id] = nil }
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let current = handlers.values
        handlers.removeAll()
        for handler in current { handler() }
    }
    public func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Check hand-constructed JSON values without serializing private histories into
/// another full byte buffer. Transport parsing has already validated wire bytes.
public enum PluginJSONValidation {
    public static func validate(_ value: JSONValue, maxDepth: Int = JSONValue.maximumDepth) throws {
        guard (1...JSONValue.maximumDepth).contains(maxDepth) else {
            throw PluginContractError("Invalid plugin JSON nesting limit")
        }
        try visit(value, depth: 0, maxDepth: maxDepth)
    }
    private static func visit(_ value: JSONValue, depth: Int, maxDepth: Int) throws {
        switch value {
        case .number(let number):
            guard number.isFinite else { throw PluginContractError("Plugin JSON contains a nonfinite number") }
        case .array(let values):
            guard depth < maxDepth else { throw PluginContractError("Plugin JSON exceeds maximum nesting depth") }
            for child in values { try visit(child, depth: depth + 1, maxDepth: maxDepth) }
        case .object(let values):
            guard depth < maxDepth else { throw PluginContractError("Plugin JSON exceeds maximum nesting depth") }
            for child in values.values { try visit(child, depth: depth + 1, maxDepth: maxDepth) }
        case .null, .bool, .string, .integer: break
        }
    }
}
