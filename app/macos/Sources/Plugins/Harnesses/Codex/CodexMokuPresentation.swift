import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Codex owns the answer target; the shell must carry it back unchanged.
public enum CodexMokuProjection {
    public static let maximumReplyExcerptPoints = 240

    public static func project(state: JSONValue) -> JSONValue {
        let turns = state["turns"]?.arrayValue ?? []
        var activity: JSONValue = .null
        if let turn = turns.last, turn["status"]?.stringValue == "running",
           var fields = turn["foreground"]?.objectValue {
            fields["executionId"] = turn["executionId"] ?? .null
            activity = .object(fields)
        }
        var reply: JSONValue = .null
        for turn in turns.reversed() where turn["status"]?.stringValue == "completed" {
            guard let message = (turn["timeline"]?.arrayValue ?? []).last(where: {
                $0["kind"]?.stringValue == "assistant" && !codexTrim($0["content"]).codeUnits.isEmpty
            }) else { continue }
            let excerpt = codexHeadPoints(codexTrim(message["content"]), limit: maximumReplyExcerptPoints)
            reply = .object([
                "id": .text(codexJSONString(.array([turn["executionId"] ?? .null, message["id"] ?? .null]))),
                "executionId": turn["executionId"] ?? .null,
                "excerpt": .string(excerpt),
                "target": .object([
                    "executionId": turn["executionId"] ?? .null,
                    "itemId": message["itemId"] ?? .null
                ])
            ])
            break
        }
        return .object(["activity": activity, "reply": reply])
    }

    public static func presentation(state: JSONValue) -> HarnessMokuPresentation {
        let raw = project(state: state)
        let activity: HarnessActivity?
        if let value = raw["activity"],
           case .string(let executionID) = value["executionId"],
           let sequence = value["sequence"]?.intValue {
            let body: HarnessActivityBody?
            switch value["kind"]?.stringValue {
            case "reasoning":
                if case .string(let text) = value["text"] {
                    body = .reasoning(text: text, textOffset: value["textOffset"]?.intValue)
                } else { body = nil }
            case "assistant-text": body = .assistantText
            case "tool-call":
                if case .string(let callID) = value["callId"],
                   case .string(let toolName) = value["toolName"] {
                    body = .toolCall(callID: callID, toolName: toolName)
                } else { body = nil }
            default: body = nil
            }
            activity = body.map { HarnessActivity(executionID: executionID, sequence: sequence, body: $0) }
        } else { activity = nil }
        let reply: HarnessMokuReply?
        if let value = raw["reply"], case .string(let id) = value["id"],
           case .string(let executionID) = value["executionId"],
           case .string(let excerpt) = value["excerpt"], let target = value["target"] {
            reply = HarnessMokuReply(id: id, executionID: executionID, excerpt: excerpt, target: target)
        } else { reply = nil }
        return HarnessMokuPresentation(activity: activity, reply: reply)
    }

    /// A stale or malformed target still permits navigation to the execution,
    /// but cannot select an unrelated timeline row.
    public static func replyAnchor(state: JSONValue, message: JSONValue?) -> JSONText? {
        guard case .string(let executionID) = message?["executionId"],
              case .string(let itemID) = message?["itemId"],
              let turn = (state["turns"]?.arrayValue ?? []).first(where: { $0["executionId"] == .string(executionID) }),
              let item = (turn["timeline"]?.arrayValue ?? []).first(where: {
                  $0["kind"]?.stringValue == "assistant" && $0["itemId"] == .string(itemID)
              }), case .string(let anchor) = item["id"] else { return nil }
        return anchor
    }
}

public func projectCodexMokuPresentation(state: JSONValue) -> HarnessMokuPresentation {
    CodexMokuProjection.presentation(state: state)
}

public func codexMokuReplyAnchor(state: JSONValue, message: JSONValue?) -> JSONText? {
    CodexMokuProjection.replyAnchor(state: state, message: message)
}

/// ECMAScript trim differs from Foundation's whitespace set (notably FEFF).
/// Work on UTF-16 to keep native identifiers and isolated surrogates lossless.
func codexTrim(_ value: JSONValue?) -> JSONText {
    guard case .string(let text) = value else { return JSONText("") }
    var start = 0
    var end = text.codeUnits.count
    while start < end && codexIsJSWhitespace(text.codeUnits[start]) { start += 1 }
    while end > start && codexIsJSWhitespace(text.codeUnits[end - 1]) { end -= 1 }
    return JSONText(codeUnits: Array(text.codeUnits[start..<end]))
}

private func codexIsJSWhitespace(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
         0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
    default: false
    }
}

func codexHeadPoints(_ text: JSONText, limit: Int) -> JSONText {
    var end = 0
    var points = 0
    while end < text.codeUnits.count && points < max(0, limit) {
        let unit = text.codeUnits[end]
        let pair = (0xD800...0xDBFF).contains(unit) && end + 1 < text.codeUnits.count &&
            (0xDC00...0xDFFF).contains(text.codeUnits[end + 1])
        end += pair ? 2 : 1
        points += 1
    }
    return JSONText(codeUnits: Array(text.codeUnits.prefix(end)))
}

func codexJSONString(_ value: JSONValue) -> String {
    // These IDs are JSON.stringify tuples. Keep JavaScript's short control
    // escapes as well as its lossless isolated-surrogate escaping.
    if case .array(let values) = value { return "[" + values.map(codexJSONString).joined(separator: ",") + "]" }
    if case .string(let text) = value {
        var result = "\""
        var index = 0
        while index < text.codeUnits.count {
            let unit = text.codeUnits[index]
            index += 1
            switch unit {
            case 0x0008: result += "\\b"
            case 0x0009: result += "\\t"
            case 0x000A: result += "\\n"
            case 0x000C: result += "\\f"
            case 0x000D: result += "\\r"
            case 0x0022: result += "\\\""
            case 0x005C: result += "\\\\"
            case 0x0000...0x001F: result += String(format: "\\u%04x", unit)
            case 0xD800...0xDBFF:
                if index < text.codeUnits.count && (0xDC00...0xDFFF).contains(text.codeUnits[index]) {
                    result += String(decoding: [unit, text.codeUnits[index]], as: UTF16.self)
                    index += 1
                } else { result += String(format: "\\u%04x", unit) }
            case 0xDC00...0xDFFF: result += String(format: "\\u%04x", unit)
            default: result += String(decoding: [unit], as: UTF16.self)
            }
        }
        return result + "\""
    }
    guard let bytes = try? value.encodedData() else { return "null" }
    return String(decoding: bytes, as: UTF8.self)
}
