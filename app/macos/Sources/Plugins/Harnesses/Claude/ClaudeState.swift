import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Private wire values retain exact UTF-16 identities and absence versus null.
struct ClaudeState: Hashable, Sendable {
    let initialResponseScope: Bool
    let raw: JSONValue
    let turns: [ClaudeTurn]
    init(_ value: JSONValue) throws {
        if let flag = value["initialResponseScope"], flag.boolValue == nil { throw claudeInvalid() }
        initialResponseScope = value == .null || value["initialResponseScope"] == .bool(true)
        let value = value == .null ? claudeObject(["version": .number(1), "turns": .array([]), "nativeNotifications": .array([])]) : value
        try claudeKeys(value, ["initialResponseScope", "version", "primarySessionId", "pendingFork", "forkHistory", "goalPromptPending", "runtime", "turns", "nativeNotifications"])
        guard value["version"] == .number(1), let entries = value["turns"]?.arrayValue, entries.count <= 2_000,
              let notices = value["nativeNotifications"]?.arrayValue, notices.count <= 200 else { throw claudeInvalid() }
        if let id = value["primarySessionId"] { try claudeText(id, max: 512, nonempty: true) }
        if let pending = value["pendingFork"] {
            try claudeKeys(pending, ["sourceSessionId", "checkpointId"])
            try claudeText(pending["sourceSessionId"], max: 512, nonempty: true)
            if let checkpoint = pending["checkpointId"] { try claudeText(checkpoint, max: 512, nonempty: true) }
            guard value["primarySessionId"] == nil else { throw claudeInvalid() }
        }
        if let goal = value["goalPromptPending"], goal != .bool(true) { throw claudeInvalid() }
        for notice in notices {
            try claudeKeys(notice, ["summary", "status"]); try claudeText(notice["summary"], max: 20_000)
            if let status = notice["status"] { try claudeText(status, max: 256) }
        }
        if let history = value["forkHistory"] {
            try claudeKeys(history, ["sourceSessionId", "checkpointId", "items"])
            try claudeText(history["sourceSessionId"], max: 512, nonempty: true)
            let items = try claudeArray(history["items"], max: 4_000)
            try claudeUnique(items, key: "id")
            for item in items { try claudeValidateTimeline(item, history: true) }
            let units = items.reduce(0) { sum, item in
                sum + ((item["content"] ?? item["message"]).map { if case .string(let text) = $0 { text.codeUnits.count } else { 0 } } ?? claudeJSONString(item).utf16.count)
            }
            guard units <= 4_000_000 else { throw claudeInvalid("fork history content") }
            if let checkpoint = history["checkpointId"] {
                try claudeText(checkpoint,max:512,nonempty:true)
                guard items.filter({ $0.claudeKind == "user-message" && $0["checkpointId"] == checkpoint }).count == 1 else { throw claudeInvalid("fork checkpoint") }
            }
            guard zip(items, items.dropFirst()).allSatisfy({ ($0["createdAt"]?.numberValue ?? 0) <= ($1["createdAt"]?.numberValue ?? 0) }) else { throw claudeInvalid() }
        }
        if let runtime = value["runtime"] { try claudeValidateRuntime(runtime) }
        raw = value; turns = try entries.map(ClaudeTurn.init)
    }
    var history: [JSONValue] { raw["forkHistory"]?["items"]?.arrayValue ?? [] }
    var tasks: [JSONValue] { raw["runtime"]?["backgroundTasks"]?.arrayValue ?? [] }
}
struct ClaudeTurn: Hashable, Sendable, Identifiable {
    let raw: JSONValue
    var id: JSONText { raw.claudeID("executionId") }
    var status: String { raw["status"]!.stringValue! }
    var createdAt: Double { raw["createdAt"]!.numberValue! }
    var updatedAt: Double { raw["updatedAt"]!.numberValue! }
    var finishedAt: Double? { raw["finishedAt"]?.numberValue }
    var prompts: [JSONValue] { raw["prompts"]!.arrayValue! }
    var timeline: [JSONValue] { raw["timeline"]!.arrayValue! }
    var activities: [JSONValue] { raw["activities"]!.arrayValue! }
    var interactions: [JSONValue] { raw["interactions"]!.arrayValue! }
    var notices: [JSONValue] { raw["notices"]!.arrayValue! }
    var plan: [JSONValue] { raw["plan"]!.arrayValue! }
    var internalIndexes: Set<Int> { Set((raw["internalPromptIndexes"]?.arrayValue ?? []).compactMap { $0.numberValue.map(Int.init) }) }
    var visiblePrompts: [JSONValue] { prompts.enumerated().filter { !internalIndexes.contains($0.offset) }.map(\.element) }
    init(_ value: JSONValue) throws {
        try claudeKeys(value, ["author", "executionId", "createdAt", "updatedAt", "finishedAt", "prompts", "promptAttachments", "internalPromptIndexes", "text", "lastAssistantMessage", "reasoning", "status", "statusLabel", "foreground", "error", "plan", "planExplanation", "activities", "interactions", "notices", "timeline", "usage", "diff", "review", "compacted"])
        try claudeText(value["executionId"], max: 512, nonempty: true)
        let created = try claudeNumber(value["createdAt"]), updated = try claudeNumber(value["updatedAt"])
        guard updated >= created, let status = value["status"]?.stringValue, ["running", "completed", "failed", "interrupted"].contains(status) else { throw claudeInvalid() }
        if status == "running" { guard value["finishedAt"] == nil else { throw claudeInvalid() } }
        else { let finished = try claudeNumber(value["finishedAt"]); guard finished >= created, finished <= updated else { throw claudeInvalid() } }
        let prompts = try claudeArray(value["prompts"], max: 200)
        for prompt in prompts { try claudeText(prompt, max: 2_000_000) }
        let attachments = try claudeArray(value["promptAttachments"], max: 200)
        guard attachments.count == prompts.count else { throw claudeInvalid() }
        for list in attachments { try claudeValidateAttachments(claudeArray(list, max: 128)) }
        if let indexes = value["internalPromptIndexes"] {
            let indexes = try claudeArray(indexes, max: prompts.count)
            guard Set(indexes).count == indexes.count else { throw claudeInvalid() }
            for index in indexes { let number = try claudeNumber(index); guard number.rounded() == number, number < Double(prompts.count) else { throw claudeInvalid() } }
        }
        for key in ["text", "reasoning"] { try claudeText(value[key], max: 4_000_000) }
        for (key, limit) in [("statusLabel",512), ("error",100_000), ("planExplanation",32_000), ("diff",500_000), ("review",500_000)] { if let text = value[key] { try claudeText(text, max: limit) } }
        try claudeValidatePlan(value["plan"])
        for (key, limit) in [("activities",2_000), ("interactions",500), ("notices",500), ("timeline",50_000)] {
            let items = try claudeArray(value[key], max: limit); try claudeUnique(items, key: "id")
            for item in items {
                switch key { case "activities": try claudeValidateActivity(item)
                case "interactions": try claudeValidateInteraction(item)
                case "notices": try claudeValidateNotice(item)
                default: try claudeValidateTimeline(item)
                    guard (item["createdAt"]?.numberValue ?? 0) <= updated else { throw claudeInvalid() }
                    if item["kind"]?.stringValue == "user-message" { guard let index = item["promptIndex"]?.numberValue, index < Double(prompts.count) else { throw claudeInvalid() } }
                }
            }
        }
        let timeline = value["timeline"]!.arrayValue!
        var previous = created, contentUnits = 0
        for item in timeline {
            let timestamp = item["createdAt"]!.numberValue!
            guard timestamp >= previous else { throw claudeInvalid("timeline order") }; previous = timestamp
            if ["assistant","reasoning","diff","review"].contains(item.claudeKind) { contentUnits += item.claudeID("content").codeUnits.count }
            if item.claudeKind == "error" { contentUnits += item.claudeID("message").codeUnits.count }
        }
        guard contentUnits <= 4_000_000 else { throw claudeInvalid("timeline content") }
        if let author = value["author"] {
            // Accept both persisted shapes: legacy {model, effort} with string
            // fields and the Go encoder's {model, thinking: {mode, effort}}.
            try claudeKeys(author, ["model", "effort", "thinking"], "author")
            for key in ["model", "effort"] {
                if let field = author[key] { try claudeText(field, max: 4_096, nonempty: true, path: "author.\(key)") }
            }
            if let thinking = author["thinking"] {
                try claudeKeys(thinking, ["mode", "effort"], "author.thinking")
                for key in ["mode", "effort"] {
                    if let field = thinking[key] { try claudeText(field, max: 4_096, nonempty: true, path: "author.thinking.\(key)") }
                }
            }
        }
        if let message = value["lastAssistantMessage"] {
            try claudeKeys(message,["id","text"]); try claudeText(message["text"],max:100_000)
            if let id = message["id"] { try claudeText(id,max:512,nonempty:true) }
        }
        if let usage = value["usage"] { try claudeValidateUsage(usage) }
        if let compacted = value["compacted"], compacted != .bool(true) { throw claudeInvalid() }
        if let foreground = value["foreground"] {
            let kind = foreground["kind"]?.stringValue
            let seq = try claudeNumber(foreground["sequence"]); guard seq.rounded() == seq, seq >= 1, seq <= 9_007_199_254_740_991 else { throw claudeInvalid() }
            switch kind {
            case "assistant-text": try claudeKeys(foreground, ["sequence", "kind"])
            case "reasoning": try claudeKeys(foreground, ["sequence", "kind", "text", "textOffset"]); try claudeText(foreground["text"], max: 65_536, nonempty: true)
                let reasoning = foreground.claudeID("text"); guard claudeHeadPoints(reasoning,limit:32_768) == reasoning else { throw claudeInvalid("foreground reasoning") }
                if let offset = foreground["textOffset"] { let n = try claudeNumber(offset); guard n.rounded() == n, n <= 9_007_199_254_740_991 else { throw claudeInvalid() } }
            case "tool-call": try claudeKeys(foreground, ["sequence", "kind", "callId", "toolName"]); try claudeText(foreground["callId"], max: 1_024, nonempty: true); try claudeText(foreground["toolName"], max: 1_024, nonempty: true)
            default: throw claudeInvalid()
            }
        }
        raw = claudeNormalizedAuthor(value)
    }
}
func claudeProjectTimeline(_ turn: ClaudeTurn) -> [JSONValue] {
    let activities = Dictionary(uniqueKeysWithValues: turn.activities.map { ($0.claudeID("id"), $0) })
    let interactions = Dictionary(uniqueKeysWithValues: turn.interactions.map { ($0.claudeID("id"), $0) })
    let replace: Set<String> = ["plan", "usage", "review"]
    var last: [String: Int] = [:], seenActivities = Set<JSONText>(), seenInteractions = Set<JSONText>()
    for (index, item) in turn.timeline.enumerated() where replace.contains(item.claudeKind) { last[item.claudeKind] = index }
    return turn.timeline.enumerated().compactMap { index, item in
        if item.claudeKind == "diff" { return nil }
        if item.claudeKind == "activity" {
            let id = item["activity"]?.claudeID("id") ?? ""
            guard let current = activities[id], seenActivities.insert(id).inserted else { return nil }
            return item.claudeReplacing("activity", current)
        }
        if item.claudeKind == "interaction" {
            let id = item["interaction"]?.claudeID("id") ?? ""
            guard let current = interactions[id], seenInteractions.insert(id).inserted else { return nil }
            return item.claudeReplacing("interaction", current)
        }
        return replace.contains(item.claudeKind) && last[item.claudeKind] != index ? nil : item
    }
}
func claudeActivityRunStarts(_ turn: ClaudeTurn) -> Set<JSONText> {
    let current = Set(turn.activities.map { $0.claudeID("id") }); var seen = Set<JSONText>(), result = Set<JSONText>(), boundary = true
    for item in turn.timeline {
        guard item.claudeKind == "activity" else { boundary = true; continue }
        let id = item["activity"]!.claudeID("id")
        guard current.contains(id), seen.insert(id).inserted else { continue }
        if boundary { result.insert(item.claudeID("id")) }; boundary = false
    }
    return result
}
func claudeInvalid(_ detail: String = "sessionState") -> PluginContractError { PluginContractError("Claude \(detail) 无效") }
func claudeInvalidObject(_ path: String) -> PluginContractError { PluginContractError("Claude \(path) 必须是对象") }
func claudeKeys(_ value: JSONValue, _ allowed: Set<String>, _ path: String = "sessionState") throws {
    guard let object = value.objectValue else { throw claudeInvalidObject(path) }
    if let unknown = object.keys.map(\.string).sorted().first(where: { !allowed.contains($0) }) {
        throw PluginContractError("Claude \(path).\(unknown) 字段无效")
    }
}
func claudeText(_ value: JSONValue?, max: Int, nonempty: Bool = false, path: String? = nil) throws {
    guard case let .string(text)? = value, text.codeUnits.count <= max, !text.codeUnits.contains(0), !nonempty || !text.codeUnits.isEmpty else { throw claudeInvalid(path ?? "sessionState") }
}
/// Persisted Go states record effort inside `thinking`; the turn header reads
/// the legacy top-level `effort` field, so project it without dropping the
/// native shape.
func claudeNormalizedAuthor(_ value: JSONValue) -> JSONValue {
    guard let thinking = value["author"]?["thinking"], let effort = thinking["effort"]?.stringValue,
          value["author"]?["effort"] == nil else { return value }
    return value.claudeReplacing("author", value["author"]?.claudeReplacing("effort", .text(effort)))
}
@discardableResult func claudeNumber(_ value: JSONValue?) throws -> Double {
    guard let n = value?.numberValue, n.isFinite, n >= 0 else { throw claudeInvalid() }; return n
}
func claudeArray(_ value: JSONValue?, max: Int) throws -> [JSONValue] {
    guard let array = value?.arrayValue, array.count <= max else { throw claudeInvalid() }; return array
}
func claudeUnique(_ values: [JSONValue], key: String) throws { guard Set(values.map { $0[key] }).count == values.count else { throw claudeInvalid() } }
func claudeObject(_ values: [String: JSONValue]) -> JSONValue { .object(Dictionary(uniqueKeysWithValues: values.map { (JSONText($0.key), $0.value) })) }
func claudeJSONString(_ value: JSONValue) -> String {
    // These IDs are JSON.stringify tuples. Keep JavaScript's short control
    // escapes as well as its lossless isolated-surrogate escaping.
    if case .object(let values) = value { return "{" + values.map { claudeJSONString(.string($0.key)) + ":" + claudeJSONString($0.value) }.joined(separator:",") + "}" }
    if let number = value.numberValue { return claudeJSNumber(number) }
    if case .array(let values) = value { return "[" + values.map(claudeJSONString).joined(separator: ",") + "]" }
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
func claudeTrim(_ value: JSONValue?) -> String { value.map { if case .string(let text) = $0 { claudeTrimText(text).string } else { "" } } ?? "" }
func claudeBoundedText(_ value: JSONText, _ max: Int) -> JSONText {
    value.codeUnits.count <= max ? value : JSONText(codeUnits: Array(value.codeUnits.prefix(max-1)) + [0x2026])
}
func claudeBounded(_ value: String, _ max: Int) -> String { claudeBoundedText(JSONText(value),max).string }

extension JSONValue {
    var claudeKind: String { self["kind"]?.stringValue ?? "" }
    func claudeID(_ key: String) -> JSONText { if case .string(let id)? = self[key] { id } else { "" } }
    func claudeReplacing(_ key: String, _ value: JSONValue?) -> JSONValue {
        guard case var .object(object) = self else { return self }; object[JSONText(key)] = value; return .object(object)
    }
}
