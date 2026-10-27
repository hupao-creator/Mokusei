import Foundation

public enum RuntimeProtocol {
    public static let version = 11
    public static let maxRequestBytes = 144 * 1024 * 1024
    public static let maxResponseBytes = 32 * 1024 * 1024
    public static let maxEventBytes = maxResponseBytes
    public static let maxOverviewBytes = 2 * 1024 * 1024
    public static let maximumSafeInteger = 9_007_199_254_740_991
}

public struct RuntimeError: Error, Sendable, LocalizedError, Equatable {
    public enum Kind: Sendable { case protocolFailure, requestRejected, commandRejected, uncertain }
    public let code: String
    public let message: String
    public let kind: Kind
    public let receiptID: String?
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String, kind: Kind = .protocolFailure, receiptID: String? = nil) {
        self.code = code; self.message = message; self.kind = kind; self.receiptID = receiptID
    }
    static func uncertain(_ id: String) -> RuntimeError {
        RuntimeError("COMMAND_OUTCOME_UNCERTAIN", "The command may already have been accepted. Inspect current state before sending new work; retry only with receipt \(id).", kind: .uncertain, receiptID: id)
    }
}

public enum RuntimeConnectionStatus: String, Sendable { case connecting, connected, disconnected, stopped }
public enum RuntimeContentScope: Sendable, Equatable {
    case thread
    case turn(key: JSONText)
    case execution(key: JSONText)
    var json: JSONValue {
        switch self {
        case .thread: return runtimeObject(["kind": .text("thread")])
        case .turn(let key): return runtimeObject(["kind": .text("turn"), "key": .string(key)])
        case .execution(let key): return runtimeObject(["kind": .text("execution"), "key": .string(key)])
        }
    }
}
public enum RuntimeContentState: Sendable, Equatable {
    case loading
    case ready(JSONValue)
    case error(String)
}
public enum RuntimeClientEvent: Sendable {
    case connection(RuntimeConnectionStatus)
    case synchronizing(Bool)
    /// Authority changes on a real hydration commit, not when a replacement
    /// observer catches up to the already-current state after queue overflow.
    case snapshot(JSONValue, authority: UUID)
    /// Exact post-apply state of this event, never a later actor snapshot.
    case mutation(JSONValue, state: JSONValue, authority: UUID)
    case threadContent(subscriptionId: String, state: RuntimeContentState)
    case overviewFilter(JSONValue)
    case failure(RuntimeError)
}

func runtimeObject(_ fields: [String: JSONValue]) -> JSONValue {
    .object(Dictionary(uniqueKeysWithValues: fields.map { (JSONText($0.key), $0.value) }))
}

func runtimeResult(_ result: JSONValue) throws -> JSONValue {
    guard let ok = result["ok"]?.boolValue else { throw RuntimeError("INVALID_RESPONSE", "Runtime returned an invalid command result") }
    if !ok {
        guard let code = result["error"]?["code"]?.stringValue,
              let message = result["error"]?["message"]?.stringValue else {
            throw RuntimeError("INVALID_RESPONSE", "Runtime returned an invalid command error")
        }
        throw RuntimeError(code, message, kind: .commandRejected)
    }
    // A successful void result deliberately omits value on the wire.
    return result["value"] ?? .null
}
