import Foundation
import MokuseiCore

/// The wire preserves exact keys but JSON object insertion order is not semantic.
/// A long public form prompt contains only a prefix of JSON.stringify(schema, null, 2).
/// Walk that prefix against the schema, taking object order from the public prompt.
/// This checks all represented fields without inventing authority for omitted text.
func claudeSchemaPrefixMatches(_ schema: JSONValue, prefix: JSONText) -> Bool {
    var reader = ClaudeSchemaPrefix(units:prefix.codeUnits,allowTruncation:true)
    return reader.match(schema,depth:0) && reader.offset == reader.units.count
}
private struct ClaudeSchemaPrefix {
    let units:[UInt16]
    let allowTruncation:Bool
    var offset = 0
    var done:Bool { offset == units.count }
    mutating func emit(_ text:String) -> Bool { emit(Array(text.utf16)) }
    mutating func emit(_ expected:[UInt16]) -> Bool {
        let count = min(expected.count,units.count-offset)
        guard allowTruncation || count == expected.count else { return false }
        guard units[offset..<(offset+count)].elementsEqual(expected.prefix(count)) else { return false }
        offset += count; return true
    }
    mutating func match(_ value:JSONValue,depth:Int) -> Bool {
        if done { return allowTruncation }
        guard depth <= 32 else { return false }
        switch value {
        case .array(let values):
            guard emit("[") else { return false }; if done { return allowTruncation }
            if values.isEmpty { return emit("]") }
            guard emit("\n") else { return false }
            for (index,value) in values.enumerated() {
                if done { return allowTruncation }
                if index > 0 { guard emit(",\n") else { return false } }
                guard emit(String(repeating:"  ",count:depth+1)), match(value,depth:depth+1) else { return false }
            }
            return emit("\n" + String(repeating:"  ",count:depth) + "]")
        case .object(let values):
            guard emit("{") else { return false }; if done { return allowTruncation }
            if values.isEmpty { return emit("}") }
            guard emit("\n") else { return false }
            var remaining=Set(values.keys), index=0
            while !remaining.isEmpty {
                if done { return allowTruncation }
                if index > 0 { guard emit(",\n") else { return false } }
                guard emit(String(repeating:"  ",count:depth+1)) else { return false }; if done { return allowTruncation }
                let key = remaining.first { key in
                    let encoded=Array(claudeJSONString(.string(key)).utf16), count=min(encoded.count,units.count-offset)
                    return units[offset..<(offset+count)].elementsEqual(encoded.prefix(count))
                }
                guard let key,emit(claudeJSONString(.string(key))),emit(": "),match(values[key]!,depth:depth+1) else { return false }
                remaining.remove(key); index += 1
            }
            return emit("\n" + String(repeating:"  ",count:depth) + "}")
        case .integer: return emit(claudeJSNumber(value.numberValue!))
        case .number(let number): return emit(claudeJSNumber(number))
        default: return emit(claudeJSONString(value))
        }
    }
}

/// Only projection-owned JSON.stringify bytes may feed visible JSON details.
/// Raw objects are compared semantically; the original display order comes from
/// the display string, and the native renderer never reconstructs that order.
func claudeJSONDisplayMatches(_ display:JSONValue, value:JSONValue) -> Bool {
    guard case .string(let text) = display,
          let parsed = try? JSONValue(data:Data(text.string.utf8)), parsed == value else { return false }
    var reader = ClaudeSchemaPrefix(units:text.codeUnits,allowTruncation:false)
    return reader.match(value,depth:0) && reader.offset == text.codeUnits.count
}
func claudeInteractionDisplay(_ interaction:JSONValue,field:String,limit:Int=20_000) -> JSONText? {
    guard case .string(let text)? = interaction[field + "Display"] else { return nil }
    return claudeBoundedText(text,limit)
}
