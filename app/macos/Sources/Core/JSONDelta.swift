import Foundation

public struct JSONDeltaError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public let reason: String
    public let operationIndex: Int?

    public init(reason: String, operationIndex: Int? = nil) {
        self.reason = reason
        self.operationIndex = operationIndex
    }

    public var description: String {
        let location = operationIndex.map { " (operation \($0))" } ?? ""
        return "JSON delta requires a fresh snapshot\(location): \(reason)"
    }

    public var errorDescription: String? { description }
}

/// Applies the runtime's JSON delta protocol. Text offsets are UTF-16 code units,
/// not Swift grapheme, scalar, or UTF-8 offsets. A failure discards all operations;
/// callers must request a fresh snapshot instead of using a partial result.
public enum JSONDelta {
    public static func apply(_ operations: JSONValue, to previous: JSONValue) throws -> JSONValue {
        guard case let .array(operations) = operations else {
            throw JSONDeltaError(reason: "patch must be an array")
        }
        let result = WorkingNode(previous)
        for (operationIndex, operation) in operations.enumerated() {
            do {
                try applyOperation(operation, to: result)
            } catch let error as JSONDeltaError {
                throw JSONDeltaError(reason: error.reason, operationIndex: operationIndex)
            }
        }
        return result.materialized()
    }

    private enum PathComponent {
        case key(JSONText)
        case index(Int)
    }

    private static func applyOperation(_ operation: JSONValue, to result: WorkingNode) throws {
        guard case .object = operation,
              case let .array(pathValues)? = operation["path"],
              pathValues.count <= JSONValue.maximumDepth else {
            throw invalid("invalid path")
        }
        let path = try pathValues.map { value -> PathComponent in
            switch value {
            case let .string(key): return .key(key)
            case .number, .integer: return .index(try nonnegativeInteger(value, reason: "invalid array path"))
            default: throw invalid("invalid path component")
            }
        }
        switch operation["op"] {
        case .string("replace"):
            guard let replacement = operation["value"] else { throw invalid("replace requires a value") }
            try target(result, path: path[...]).storage = .frozen(replacement)
        case .string("add"), .string("remove"):
            guard case let .key(key)? = path.last else {
                throw invalid("add/remove requires an object key")
            }
            let isAdd = operation["op"] == .string("add")
            let replacement = operation["value"]
            if isAdd && replacement == nil { throw invalid("add requires a value") }
            let object = try target(result, path: path.dropLast()).object()
            let exists = object.contains(key)
            guard isAdd ? !exists : exists else { throw invalid("object key does not match base") }
            if isAdd, let replacement { object.changes[key] = .node(WorkingNode(replacement)) }
            else { object.changes[key] = .removed }
        case .string("splice"):
            guard case let .array(inserted)? = operation["values"] else {
                throw invalid("splice requires arrays")
            }
            let index = try nonnegativeInteger(operation["index"], reason: "invalid splice range")
            let deleteCount = try nonnegativeInteger(operation["deleteCount"], reason: "invalid splice range")
            let array = try target(result, path: path[...]).array()
            try checkRange(length: array.elements.count, index: index, deleteCount: deleteCount)
            let remaining = array.elements.count - deleteCount
            guard remaining <= Int(UInt32.max), inserted.count <= Int(UInt32.max) - remaining else {
                throw invalid("array is too long")
            }
            array.elements.replaceSubrange(index..<(index + deleteCount), with: inserted.lazy.map { .frozen($0) })
        case .string("text"):
            guard case let .string(inserted)? = operation["text"] else {
                throw invalid("text requires strings")
            }
            let index = try nonnegativeInteger(operation["index"], reason: "invalid splice range")
            let deleteCount = try nonnegativeInteger(operation["deleteCount"], reason: "invalid splice range")
            let text = try target(result, path: path[...]).text()
            try checkRange(length: text.units.count, index: index, deleteCount: deleteCount)
            text.units.replaceSubrange(index..<(index + deleteCount), with: inserted.codeUnits)
        default:
            throw invalid("unknown operation")
        }
    }

    private static func target(_ root: WorkingNode, path: ArraySlice<PathComponent>) throws -> WorkingNode {
        var node = root
        for component in path { node = try node.child(component) }
        return node
    }

    // These references belong exclusively to one apply call; they never escape
    // into JSONValue. A touched container is prepared once for the entire batch,
    // regardless of how many operations revisit it. Direct enum extraction and
    // reassignment would retain parent/child CoW buffers and clone on every op.
    private final class WorkingNode {
        enum Storage {
            case frozen(JSONValue)
            case object(WorkingObject)
            case array(WorkingArray)
            case text(WorkingText)
        }

        var storage: Storage

        init(_ value: JSONValue) { storage = .frozen(value) }

        func child(_ component: PathComponent) throws -> WorkingNode {
            switch storage {
            case .frozen(.object), .object:
                guard case let .key(key) = component else { throw invalid("invalid object path") }
                return try object().child(key)
            case .frozen(.array), .array:
                guard case let .index(index) = component else { throw invalid("invalid array path") }
                return try array().child(index)
            default:
                throw invalid("path traverses a primitive")
            }
        }

        func object() throws -> WorkingObject {
            switch storage {
            case let .object(object): return object
            case let .frozen(.object(values)):
                let object = WorkingObject(values)
                storage = .object(object)
                return object
            default: throw invalid("add/remove requires an object")
            }
        }

        func array() throws -> WorkingArray {
            switch storage {
            case let .array(array): return array
            case let .frozen(.array(values)):
                let array = WorkingArray(values)
                storage = .array(array)
                return array
            default: throw invalid("splice requires arrays")
            }
        }

        func text() throws -> WorkingText {
            switch storage {
            case let .text(text): return text
            case let .frozen(.string(value)):
                let text = WorkingText(value)
                storage = .text(text)
                return text
            default: throw invalid("text requires strings")
            }
        }

        func materialized() -> JSONValue {
            switch storage {
            case let .frozen(value): return value
            case let .object(object): return object.materialized()
            case let .array(array): return array.materialized()
            case let .text(text): return .string(JSONText(codeUnits: text.units))
            }
        }
    }

    private final class WorkingObject {
        enum Change {
            case node(WorkingNode)
            case removed
        }

        let base: [JSONText: JSONValue]
        var changes: [JSONText: Change] = [:]

        init(_ values: [JSONText: JSONValue]) { base = values }

        func contains(_ key: JSONText) -> Bool {
            switch changes[key] {
            case .node: return true
            case .removed: return false
            case nil: return base[key] != nil
            }
        }

        func child(_ key: JSONText) throws -> WorkingNode {
            switch changes[key] {
            case let .node(node): return node
            case .removed: throw invalid("missing path")
            case nil:
                guard let value = base[key] else { throw invalid("missing path") }
                let node = WorkingNode(value)
                changes[key] = .node(node)
                return node
            }
        }

        func materialized() -> JSONValue {
            // The first write clones the base dictionary; subsequent writes use
            // this one unique buffer. Untouched subtrees retain their storage.
            var values = base
            for (key, change) in changes {
                switch change {
                case let .node(node): values[key] = node.materialized()
                case .removed: values.removeValue(forKey: key)
                }
            }
            return .object(values)
        }
    }

    private final class WorkingArray {
        enum Element {
            case frozen(JSONValue)
            case node(WorkingNode)

            func materialized() -> JSONValue {
                switch self {
                case let .frozen(value): return value
                case let .node(node): return node.materialized()
                }
            }
        }

        // Slots preserve node identity as splices move elements. Wrapping the
        // original array occurs once, and only visited slots allocate nodes.
        var elements: [Element]

        init(_ values: [JSONValue]) { elements = values.map { .frozen($0) } }

        func child(_ index: Int) throws -> WorkingNode {
            guard index < elements.count else { throw invalid("invalid array path") }
            switch elements[index] {
            case let .node(node): return node
            case let .frozen(value):
                let node = WorkingNode(value)
                elements[index] = .node(node)
                return node
            }
        }

        func materialized() -> JSONValue { .array(elements.map { $0.materialized() }) }
    }

    private final class WorkingText {
        var units: [UInt16]

        init(_ text: JSONText) { units = text.codeUnits }
    }

    private static func nonnegativeInteger(_ value: JSONValue?, reason: String) throws -> Int {
        guard let integer = value?.intValue,
              integer >= 0, integer <= RuntimeProtocol.maximumSafeInteger else { throw invalid(reason) }
        return integer
    }

    private static func checkRange(length: Int, index: Int, deleteCount: Int) throws {
        guard index <= length, deleteCount <= length - index else { throw invalid("invalid splice range") }
    }

    private static func invalid(_ reason: String) -> JSONDeltaError { JSONDeltaError(reason: reason) }
}
