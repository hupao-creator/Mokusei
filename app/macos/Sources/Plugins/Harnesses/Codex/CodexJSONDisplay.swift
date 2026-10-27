import Foundation
import MokuseiCore

/// JavaScript's pretty JSON is part of Codex's public MCP display contract.
/// JSONValue retains exact keys and values but intentionally not object insertion
/// order. Read the observed key order while checking every emitted character
/// against the native schema, including a prefix clipped at the UTF-16 limit.
/// This accepts no changed whitespace, values, escaping, or schema properties.
func codexJSONSchemaDisplayMatches(_ value: JSONValue?, schema: JSONValue, limit: Int = 20_000,
                                  prefix: String = "") -> Bool {
    guard case let .string(text) = value, text.codeUnits.count <= limit else { return false }
    var matcher = CodexPrettyJSONMatcher(actual: text.codeUnits, permitsPrefix: text.codeUnits.count == limit)
    do {
        try matcher.emit(Array(prefix.utf16))
        try matcher.render(schema, depth: 0)
        return matcher.offset == text.codeUnits.count
    } catch CodexPrettyJSONMatcher.Failure.prefix { return true }
    catch { return false }
}

func codexPrettyJSONString(_ value: JSONValue) -> String {
    func render(_ value: JSONValue, depth: Int) -> [UInt16] {
        let indent = Array(String(repeating: "  ", count: depth).utf16)
        let childIndent = indent + [32, 32]
        switch value {
        case .null: return Array("null".utf16)
        case .bool(let flag): return Array((flag ? "true" : "false").utf16)
        case .integer: return Array(codexJavaScriptNumber(value.numberValue!).utf16)
        case .number(let number): return Array(codexJavaScriptNumber(number).utf16)
        case .string(let text): return codexJSONStringUnits(text)
        case .array(let values):
            if values.isEmpty { return [91, 93] }
            var result: [UInt16] = [91, 10]
            for (index, value) in values.enumerated() {
                result += childIndent + render(value, depth: depth + 1)
                result += index == values.count - 1 ? [10] : [44, 10]
            }
            return result + indent + [93]
        case .object(let fields):
            if fields.isEmpty { return [123, 125] }
            let keys = fields.keys.sorted { $0.codeUnits.lexicographicallyPrecedes($1.codeUnits) }
            var result: [UInt16] = [123, 10]
            for (index, key) in keys.enumerated() {
                result += childIndent + codexJSONStringUnits(key) + [58, 32] + render(fields[key]!, depth: depth + 1)
                result += index == keys.count - 1 ? [10] : [44, 10]
            }
            return result + indent + [125]
        }
    }
    return JSONText(codeUnits: render(value, depth: 0)).string
}

private struct CodexPrettyJSONMatcher {
    enum Failure: Error { case mismatch, prefix }
    let actual: [UInt16]
    let permitsPrefix: Bool
    var offset = 0

    mutating func emit(_ expected: [UInt16]) throws {
        let count = min(expected.count, actual.count - offset)
        guard actual[offset..<(offset + count)].elementsEqual(expected.prefix(count)) else { throw Failure.mismatch }
        offset += count
        if count < expected.count { throw permitsPrefix ? Failure.prefix : Failure.mismatch }
    }
    mutating func emit(_ expected: String) throws { try emit(Array(expected.utf16)) }

    mutating func render(_ value: JSONValue, depth: Int) throws {
        guard depth < JSONValue.maximumDepth else { throw Failure.mismatch }
        switch value {
        case .null: try emit("null")
        case .bool(let flag): try emit(flag ? "true" : "false")
        case .integer: try emit(codexJavaScriptNumber(value.numberValue!))
        case .number(let number): try emit(codexJavaScriptNumber(number))
        case .string(let text): try emit(codexJSONStringUnits(text))
        case .array(let values):
            if values.isEmpty { try emit("[]"); return }
            try emit("[\n")
            for (index, value) in values.enumerated() {
                try emit(String(repeating: "  ", count: depth + 1))
                try render(value, depth: depth + 1)
                try emit(index == values.count - 1 ? "\n" : ",\n")
            }
            try emit(String(repeating: "  ", count: depth) + "]")
        case .object(let values):
            if values.isEmpty { try emit("{}"); return }
            try emit("{\n")
            var remaining = values
            let integerKeys = values.keys.compactMap { key -> (UInt32, JSONText)? in
                guard !key.codeUnits.isEmpty, key.codeUnits.allSatisfy({ (48...57).contains($0) }),
                      let integer = UInt32(key.string), integer < UInt32.max,
                      JSONText(String(integer)) == key else { return nil }
                return (integer, key)
            }.sorted { $0.0 < $1.0 }.map(\.1)
            for index in 0..<values.count {
                try emit(String(repeating: "  ", count: depth + 1))
                let key: JSONText
                if index < integerKeys.count { key = integerKeys[index] }
                else { key = try observedKey(in: remaining) }
                guard let child = remaining.removeValue(forKey: key) else { throw Failure.mismatch }
                try emit(codexJSONStringUnits(key)); try emit(": ")
                try render(child, depth: depth + 1)
                try emit(index == values.count - 1 ? "\n" : ",\n")
            }
            try emit(String(repeating: "  ", count: depth) + "}")
        }
    }

    /// The only unknown is native insertion order. Complete key tokens resolve
    /// by exact UTF-16 identity. A clipped token must prefix an unvisited key.
    private func observedKey(in values: [JSONText: JSONValue]) throws -> JSONText {
        guard offset < actual.count else { throw permitsPrefix ? Failure.prefix : Failure.mismatch }
        guard actual[offset] == 34 else { throw Failure.mismatch }
        var end = offset + 1
        while end < actual.count {
            if actual[end] == 34 {
                let token = JSONText(codeUnits: Array(actual[offset...end]))
                guard let value = try? JSONValue(data: Data(token.string.utf8)),
                      case let .string(key) = value, values[key] != nil else { throw Failure.mismatch }
                return key
            }
            if actual[end] == 92 { end += 1 }
            end += 1
        }
        guard permitsPrefix else { throw Failure.mismatch }
        let suffix = actual[offset...]
        guard values.keys.contains(where: { codexJSONStringUnits($0).starts(with: suffix) }) else { throw Failure.mismatch }
        throw Failure.prefix
    }
}

private func codexJSONStringUnits(_ text: JSONText) -> [UInt16] {
    var result: [UInt16] = [34]
    let hex = Array("0123456789abcdef".utf16)
    var index = 0
    while index < text.codeUnits.count {
        let unit = text.codeUnits[index]; index += 1
        switch unit {
        case 34, 92: result += [92, unit]
        case 8: result += [92, 98]
        case 9: result += [92, 116]
        case 10: result += [92, 110]
        case 12: result += [92, 102]
        case 13: result += [92, 114]
        case 0...31: result += [92, 117, 48, 48, hex[Int(unit >> 4)], hex[Int(unit & 15)]]
        case 0xD800...0xDBFF:
            if index < text.codeUnits.count && (0xDC00...0xDFFF).contains(text.codeUnits[index]) {
                result += [unit, text.codeUnits[index]]; index += 1
            } else { result += [92, 117, hex[Int(unit >> 12)], hex[Int((unit >> 8) & 15)], hex[Int((unit >> 4) & 15)], hex[Int(unit & 15)]] }
        case 0xDC00...0xDFFF: result += [92, 117, hex[Int(unit >> 12)], hex[Int((unit >> 8) & 15)], hex[Int((unit >> 4) & 15)], hex[Int(unit & 15)]]
        default: result.append(unit)
        }
    }
    result.append(34)
    return result
}

/// Number.toString's decimal/scientific thresholds differ from Swift's. Both
/// start with the shortest round-tripping binary64 significand; normalize its
/// notation before matching the public JSON text.
private func codexJavaScriptNumber(_ value: Double) -> String {
    if value == 0 { return "0" }
    guard value.isFinite else { return "null" }
    let negative = value < 0
    let source = String(abs(value)).lowercased().split(separator: "e", omittingEmptySubsequences: false)
    let mantissa = String(source[0])
    let exponent = source.count > 1 ? Int(source[1]) ?? 0 : 0
    let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    var digits = String(parts[0]) + (parts.count > 1 ? String(parts[1]) : "")
    var point = parts[0].count + exponent
    while digits.first == "0" { digits.removeFirst(); point -= 1 }
    while digits.last == "0" { digits.removeLast() }
    let sign = negative ? "-" : ""
    if point > 0 && point <= 21 {
        if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) }
        let split = digits.index(digits.startIndex, offsetBy: point)
        return sign + digits[..<split] + "." + digits[split...]
    }
    if point <= 0 && point > -6 { return sign + "0." + String(repeating: "0", count: -point) + digits }
    let power = point - 1
    let significand = digits.count == 1 ? digits : String(digits.prefix(1)) + "." + digits.dropFirst()
    return sign + significand + "e" + (power >= 0 ? "+" : "") + String(power)
}
