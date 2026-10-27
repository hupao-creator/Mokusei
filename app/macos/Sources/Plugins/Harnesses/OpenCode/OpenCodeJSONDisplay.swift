import Foundation
import MokuseiCore

/// The owning TypeScript renderer adapter captures JSON.stringify while object
/// insertion order still exists. Swift validates these bytes against the value
/// without reconstructing or sorting the display.
func ocToolDisplayMatches(_ display: JSONText, source: JSONValue) -> Bool {
    if case .string(let text) = source { return display == text }
    var matcher = OpenCodeJSONDisplayMatcher(actual: display.codeUnits)
    do { try matcher.render(source, depth: 0); return matcher.offset == display.codeUnits.count }
    catch { return false }
}

extension OpenCodeMessage {
    func toolDisplay(_ field: String) throws -> JSONText? {
        guard let source = raw[field] else { return nil }
        if let display = raw.ocText(field + "Display") { return display }
        // Materialized scalar/array inputs have no missing ordering fact. Never
        // present sorted object reconstruction as the original native output.
        return try ocOrderIndependentDisplay(source, depth: 0, rawString: true)
    }
}

private func ocOrderIndependentDisplay(_ value: JSONValue, depth: Int, rawString: Bool = false) throws -> JSONText {
    if rawString, case .string(let text) = value { return text }
    switch value {
    case .object(let object):
        guard object.isEmpty else { throw OpenCodeToolDisplayError.missingProjection }
        return "{}"
    case .array(let array):
        if array.isEmpty { return "[]" }
        let indent = JSONText(String(repeating: "  ", count: depth + 1))
        var parts: [JSONText] = ["[\n"]
        for (index, child) in array.enumerated() {
            parts += [indent, try ocOrderIndependentDisplay(child, depth: depth + 1), index == array.count - 1 ? "\n" : ",\n"]
        }
        parts += [JSONText(String(repeating: "  ", count: depth)), "]"]
        return ocJoinedID(parts)
    default: return ocJSONString(value)
    }
}

enum OpenCodeToolDisplayError: Error, LocalizedError {
    case missingProjection
    var errorDescription: String? { "OpenCode tool display projection is unavailable. Reload this conversation." }
}

private struct OpenCodeJSONDisplayMatcher {
    enum Failure: Error { case mismatch }
    let actual: [UInt16]
    var offset = 0
    mutating func emit(_ expected: [UInt16]) throws {
        guard expected.count <= actual.count - offset,
              actual[offset..<(offset + expected.count)].elementsEqual(expected) else { throw Failure.mismatch }
        offset += expected.count
    }
    mutating func emit(_ expected: String) throws { try emit(Array(expected.utf16)) }
    mutating func render(_ value: JSONValue, depth: Int) throws {
        guard depth < JSONValue.maximumDepth else { throw Failure.mismatch }
        switch value {
        case .null: try emit("null")
        case .bool(let flag): try emit(flag ? "true" : "false")
        case .integer: try emit(ocNumberString(value.numberValue!))
        case .number(let number): try emit(ocNumberString(number))
        case .string: try emit(ocJSONString(value).codeUnits)
        case .array(let children):
            if children.isEmpty { try emit("[]"); return }
            try emit("[\n")
            for (index, child) in children.enumerated() {
                try emit(String(repeating: "  ", count: depth + 1)); try render(child, depth: depth + 1)
                try emit(index == children.count - 1 ? "\n" : ",\n")
            }
            try emit(String(repeating: "  ", count: depth) + "]")
        case .object(let children):
            if children.isEmpty { try emit("{}"); return }
            try emit("{\n")
            var remaining = children
            let numericKeys = children.keys.compactMap { key -> (UInt32, JSONText)? in
                guard !key.codeUnits.isEmpty, key.codeUnits.allSatisfy({ (48...57).contains($0) }),
                      let index = UInt32(key.string), index < UInt32.max, JSONText(String(index)) == key else { return nil }
                return (index, key)
            }.sorted { $0.0 < $1.0 }.map(\.1)
            for index in 0..<children.count {
                try emit(String(repeating: "  ", count: depth + 1))
                let key = index < numericKeys.count ? numericKeys[index] : try observedKey(in: remaining)
                guard let child = remaining.removeValue(forKey: key) else { throw Failure.mismatch }
                try emit(ocJSONString(.string(key)).codeUnits); try emit(": "); try render(child, depth: depth + 1)
                try emit(index == children.count - 1 ? "\n" : ",\n")
            }
            try emit(String(repeating: "  ", count: depth) + "}")
        }
    }
    private func observedKey(in remaining: [JSONText: JSONValue]) throws -> JSONText {
        guard offset < actual.count, actual[offset] == 34 else { throw Failure.mismatch }
        var end = offset + 1
        while end < actual.count {
            if actual[end] == 34 {
                let token = JSONText(codeUnits: Array(actual[offset...end]))
                guard let decoded = try? JSONValue(data: Data(token.string.utf8)),
                      case .string(let key) = decoded, remaining[key] != nil else { throw Failure.mismatch }
                return key
            }
            if actual[end] == 92 { end += 1 }
            end += 1
        }
        throw Failure.mismatch
    }
}
