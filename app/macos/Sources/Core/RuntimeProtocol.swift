import Foundation

public enum RuntimeProtocol {
    /// 13 adds bounded reader detail/body scopes on top of the coordinated
    /// #320 reader-adapter and #322 directory/preview contract.
    public static let version = 13
    public static let maxRequestBytes = 144 * 1024 * 1024
    public static let maxResponseBytes = 32 * 1024 * 1024
    public static let maxEventBytes = maxResponseBytes
    public static let maxOverviewBytes = 2 * 1024 * 1024
    public static let maximumSafeInteger = 9_007_199_254_740_991
    /// Shared bound for every content scope identity, measured in UTF-16 units.
    /// Harnesses derive a bounded row identity when a native id is longer.
    public static let maximumContentIdentityUnits = 256
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
    /// Agent reading keeps only content the count-only page can display.
    /// The opaque target is the Harness's explicitly requested native message.
    case reading(key: JSONText, target: JSONValue?)
    case execution(key: JSONText)
    /// Paged backend directory. The production Swift reader still consumes the
    /// full thread scope; later directory consumers must send a positive limit
    /// (1...200). The raw Go protocol also accepts zero as its default limit.
    case directory(offset: Int, limit: Int)
    case detail(execution: JSONText, items: [JSONText])
    case body(execution: JSONText, item: JSONText, slot: JSONText, cursor: String)
    /// Detail metadata and chunk pages are live derivatives, not offline
    /// reading content; retaining cursor pages would only serve stale bytes.
    var persistsOffline: Bool {
        switch self {
        case .detail, .body: return false
        default: return true
        }
    }
    var isReaderDetail: Bool {
        switch self {
        case .detail, .body: return true
        default: return false
        }
    }
    var json: JSONValue {
        switch self {
        case .thread: return runtimeObject(["kind": .text("thread")])
        case .turn(let key): return runtimeObject(["kind": .text("turn"), "key": .string(key)])
        case .reading(let key, let target):
            var value: [String: JSONValue] = ["kind": .text("turn"), "key": .string(key), "purpose": .text("agent-summary")]
            value["target"] = target
            return runtimeObject(value)
        case .execution(let key): return runtimeObject(["kind": .text("execution"), "key": .string(key)])
        case .directory(let offset, let limit):
            return runtimeObject(["kind": .text("directory"), "offset": .integer(offset), "limit": .integer(limit)])
        case .detail(let execution, let items):
            return runtimeObject(["kind": .text("detail"), "key": .string(execution), "items": .array(items.map(JSONValue.string))])
        case .body(let execution, let item, let slot, let cursor):
            return runtimeObject(["kind": .text("body"), "key": .string(execution), "items": .array([.string(item)]),
                                  "slot": .text(slot.string), "cursor": .text(cursor)])
        }
    }
}
public enum RuntimeContentState: Sendable, Equatable {
    case loading
    case ready(JSONValue)
    case error(String)
    /// Preserves the Runtime error identity for callers that must distinguish a
    /// stale detail cursor from a transport or projection failure.
    case failure(code: String, message: String)
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
