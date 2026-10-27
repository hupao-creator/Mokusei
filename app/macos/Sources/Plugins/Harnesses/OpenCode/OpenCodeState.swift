import CryptoKit
import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// OpenCode's private state stays inside its native plugin. IDs retain raw UTF-16.
struct OpenCodeState: Hashable, Sendable {
    let initialResponseScope: Bool
    let raw: JSONValue
    let messages: [OpenCodeMessage]
    let executions: [PublicExecution]
    let interactions: [JSONValue]
    init(_ value: JSONValue) throws {
        if let flag = value["initialResponseScope"], flag.boolValue == nil { throw OpenCodeError.invalidState }
        initialResponseScope = value == .null || value["initialResponseScope"] == .bool(true)
        let value = value == .null ? JSONValue.object(["version": .number(1), "messages": .array([]), "executions": .array([]), "latestExecutionId": .null, "interactions": .array([])]) : value
        try ocOnly(value, ["initialResponseScope", "version", "nativeSessionId", "nativeSessionCreated", "nativeTranscript", "nativeReadPrefix", "nativeContextEntries", "forkSource", "messages", "executions", "executionAuthors", "latestExecutionId", "interactions", "foregrounds", "backgroundSessions", "backgroundShells", "cursors", "nativeExecutions", "automaticExecutions", "auxiliaryUsage", "usageRecorded"])
        guard value["version"]?.intValue == 1, let messages = value["messages"]?.arrayValue,
              let executions = value["executions"]?.arrayValue, let interactions = value["interactions"]?.arrayValue,
              value["latestExecutionId"] != nil else { throw OpenCodeError.invalidState }
        try ocValidateRemainingState(value)
        self.raw = value; self.messages = try messages.map(OpenCodeMessage.init)
        self.executions = try executions.map(PublicExecution.init(json:)); self.interactions = interactions
        try ocUnique(self.messages.map(\.id)); try ocUnique(self.executions.map(\.executionID))
        if value["latestExecutionId"] != .null {
            let latest = try ocRequiredText(value, "latestExecutionId", nonempty: true)
            guard self.executions.contains(where: { $0.executionID == latest }) else { throw OpenCodeError.invalidState }
        }
        try ocOptionalText(value, ["nativeSessionId"])
        if let created = value["nativeSessionCreated"] { guard created == .bool(true), let id = value.ocText("nativeSessionId"), !id.codeUnits.isEmpty else { throw OpenCodeError.invalidState } }
        for key in ["nativeTranscript", "nativeReadPrefix", "executionAuthors", "cursors", "nativeExecutions", "automaticExecutions"] {
            if let field = value[key], field.objectValue == nil { throw OpenCodeError.invalidState }
        }
        if let fork = value["forkSource"] {
            try ocOnly(fork, ["sessionId", "messageId", "transcript"])
            _ = try ocRequiredText(fork, "sessionId", nonempty: true); try ocOptionalText(fork, ["messageId"])
            guard fork["transcript"]?.objectValue != nil else { throw OpenCodeError.invalidState }
        }
        for item in interactions {
            for key in ["id", "executionId", "sessionId", "title"] { _ = try ocRequiredText(item, key, nonempty: true) }
            guard ["pending", "answered", "cancelled"].contains(item["status"]?.stringValue ?? "") else { throw OpenCodeError.invalidState }
            switch item["kind"]?.stringValue {
            case "permission":
                try ocOnly(item, ["id", "executionId", "sessionId", "title", "status", "kind", "action", "resources", "save", "description", "metadata"])
                _ = try ocRequiredText(item, "action", nonempty: true)
                guard let resources = item["resources"]?.arrayValue, resources.allSatisfy({ $0.ocString != nil }) else { throw OpenCodeError.invalidState }
                try ocOptionalText(item, ["description"])
                if let save = item["save"], save.arrayValue?.allSatisfy({ $0.ocString != nil }) != true { throw OpenCodeError.invalidState }
            case "form":
                try ocOnly(item, ["id", "executionId", "sessionId", "title", "status", "kind", "fields", "metadata"])
                guard let fields = item["fields"]?.arrayValue, !fields.isEmpty else { throw OpenCodeError.invalidState }
                try ocUnique(try fields.map { field in
                    guard ["string", "number", "integer", "boolean", "multiselect", "external"].contains(field["type"]?.stringValue ?? "") else { throw OpenCodeError.invalidState }
                    return try ocRequiredText(field, "key", nonempty: true)
                })
            default: throw OpenCodeError.invalidState
            }
        }
        try ocUnique(interactions.map { ocJoinedID([$0.ocID("executionId"), ":", $0.ocID("id")]) })
        if let foregrounds = value["foregrounds"] {
            guard let array = foregrounds.arrayValue else { throw OpenCodeError.invalidState }
            try ocUnique(try array.map { item in
                try ocOnly(item, ["executionId", "foreground", "segmentId"])
                let id = try ocRequiredText(item, "executionId", nonempty: true)
                guard let foreground = item["foreground"], ["reasoning", "assistant-text", "tool-call"].contains(foreground["kind"]?.stringValue ?? ""),
                      let sequence = foreground["sequence"]?.intValue, sequence >= 1, sequence <= 9_007_199_254_740_991 else { throw OpenCodeError.invalidState }
                return id
            })
        }
        for key in ["backgroundSessions", "backgroundShells"] {
            if let raw = value[key] {
                guard let array = raw.arrayValue else { throw OpenCodeError.invalidState }
                try ocUnique(try array.map { item in
                    try ocOnly(item, key == "backgroundSessions" ? ["sessionId", "status"] : ["shellId", "sessionId", "status"])
                    _ = try ocRequiredText(item, "sessionId", nonempty: true)
                    guard ["running", "idle"].contains(item["status"]?.stringValue ?? "") else { throw OpenCodeError.invalidState }
                    return try ocRequiredText(item, key == "backgroundSessions" ? "sessionId" : "shellId", nonempty: true)
                })
            }
        }
        if let auxiliary = value["auxiliaryUsage"] {
            guard let samples = auxiliary.arrayValue else { throw OpenCodeError.invalidState }
            try ocUnique(try samples.map { sample in
                try ocOnly(sample, ["id", "nativeSessionId", "createdAt", "executionId", "kind", "usage", "provider", "model"])
                for key in ["nativeSessionId", "executionId"] { _ = try ocRequiredText(sample, key, nonempty: true) }
                guard sample["kind"]?.stringValue == "compaction", ocNonnegative(sample["createdAt"]) else { throw OpenCodeError.invalidState }
                _ = try OpenCodeUsage(sample["usage"] ?? .null)
                return try ocRequiredText(sample, "id", nonempty: true)
            })
        }
    }
    var nativeSessionID: JSONText? { raw.ocText("nativeSessionId") }
    var latestExecutionID: JSONText? { raw.ocText("latestExecutionId") }
    var auxiliary: [JSONValue] { raw["auxiliaryUsage"]?.arrayValue ?? [] }
    func nativeInteraction(_ publicID: JSONText) -> JSONValue? {
        interactions.first { ocPublicID("interaction", [$0.ocID("executionId"), $0.ocID("id")]) == publicID }
    }
}
struct OpenCodeMessage: Hashable, Sendable, Identifiable {
    let raw: JSONValue
    init(_ value: JSONValue) throws {
        try ocOnly(value, ["id", "executionId", "role", "text", "nativeSessionId", "nativeMessageId", "createdAt", "status", "thinking", "parts", "toolCallId", "toolName", "arguments", "result", "argumentsDisplay", "resultDisplay", "metadata", "isError", "model", "provider", "variant", "usage", "attachments", "todos", "inherited", "annotations"])
        _ = try ocRequiredText(value, "id", nonempty: true); _ = try ocRequiredText(value, "executionId", nonempty: true)
        _ = try ocRequiredText(value, "text")
        guard ["user", "assistant", "tool"].contains(value["role"]?.stringValue ?? "") else { throw OpenCodeError.invalidState }
        try ocOptionalText(value, ["nativeSessionId", "nativeMessageId", "thinking", "toolCallId", "toolName", "model", "provider", "variant"])
        for field in ["arguments", "result"] {
            if let display = value[field + "Display"] {
                guard value["role"] == .text("tool"), let source = value[field], let text = display.ocString,
                      ocToolDisplayMatches(text, source: source) else { throw OpenCodeError.invalidState }
            }
        }
        if let status = value["status"], !["streaming", "complete", "failed", "cancelled"].contains(status.stringValue ?? "") { throw OpenCodeError.invalidState }
        if let createdAt = value["createdAt"], !ocNonnegative(createdAt) { throw OpenCodeError.invalidState }
        if let inherited = value["inherited"], inherited != .bool(true) { throw OpenCodeError.invalidState }
        if let error = value["isError"], error.boolValue == nil { throw OpenCodeError.invalidState }
        if let usage = value["usage"] { _ = try OpenCodeUsage(usage) }
        if let metadata = value["metadata"], metadata.objectValue == nil { throw OpenCodeError.invalidState }
        for key in ["parts", "attachments", "todos", "annotations"] { if let item = value[key], item.arrayValue == nil { throw OpenCodeError.invalidState } }
        for part in value["parts"]?.arrayValue ?? [] {
            if part["type"]?.stringValue == "tool" {
                try ocOnly(part, ["type", "toolCallId"]); _ = try ocRequiredText(part, "toolCallId", nonempty: true)
            } else {
                try ocOnly(part, ["type", "ordinal", "text"])
                guard ["text", "reasoning"].contains(part["type"]?.stringValue ?? ""), let ordinal = part["ordinal"]?.intValue, ordinal >= 0 else { throw OpenCodeError.invalidState }
                _ = try ocRequiredText(part, "text")
            }
        }
        if let annotations = value["annotations"]?.arrayValue {
            guard annotations.count <= 20 else { throw OpenCodeError.invalidState }
            for annotation in annotations { try ocValidateAnnotation(annotation) }
        }
        for attachment in value["attachments"]?.arrayValue ?? [] {
            try ocOnly(attachment, ["name", "mimeType", "path"]); _ = try ocRequiredText(attachment, "name"); try ocOptionalText(attachment, ["mimeType", "path"])
        }
        for todo in value["todos"]?.arrayValue ?? [] {
            try ocOnly(todo, ["id", "text", "done"]); _ = try ocRequiredText(todo, "id"); _ = try ocRequiredText(todo, "text")
            guard todo["done"]?.boolValue != nil else { throw OpenCodeError.invalidState }
        }
        raw = value
    }
    var id: JSONText { raw.ocID("id") }
    var executionID: JSONText { raw.ocID("executionId") }
    var nativeSessionID: JSONText? { raw.ocText("nativeSessionId") }
    var role: String { raw["role"]!.stringValue! }
    var text: String { raw["text"]!.stringValue! }
    var status: String? { raw["status"]?.stringValue }
    var inherited: Bool { raw["inherited"] == .bool(true) }
    var parts: [JSONValue] { raw["parts"]?.arrayValue ?? [] }
}
struct OpenCodeUsage: Hashable, Sendable {
    var input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, reasoning: Double = 0, cost: Double = 0
    init() {}
    init(_ value: JSONValue) throws {
        try ocOnly(value, ["input", "output", "cacheRead", "cacheWrite", "reasoning", "cost"])
        guard ["input", "output", "cacheRead", "cacheWrite"].allSatisfy({ ocNonnegative(value[$0]) }),
              ["reasoning", "cost"].allSatisfy({ value[$0] == nil || ocNonnegative(value[$0]) }) else { throw OpenCodeError.invalidState }
        input = value["input"]!.numberValue!; output = value["output"]!.numberValue!; cacheRead = value["cacheRead"]!.numberValue!; cacheWrite = value["cacheWrite"]!.numberValue!
        reasoning = value["reasoning"]?.numberValue ?? 0; cost = value["cost"]?.numberValue ?? 0
    }
    var total: Double { input + output + cacheRead + cacheWrite + reasoning }
    mutating func add(_ other: Self) { input += other.input; output += other.output; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite; reasoning += other.reasoning; cost += other.cost }
}
func ocExecutionUsage(_ messages: [OpenCodeMessage], auxiliary: [JSONValue] = []) -> OpenCodeUsage? {
    let samples = messages.filter { $0.role == "assistant" && !$0.inherited }.compactMap { $0.raw["usage"] } + auxiliary.compactMap { $0["usage"] }
    guard !samples.isEmpty else { return nil }
    var result = OpenCodeUsage(); for sample in samples { if let usage = try? OpenCodeUsage(sample) { result.add(usage) } }; return result
}
func ocCompactTokens(_ value: Double) -> String {
    guard value >= 1_000 else { return ocNumberString(value) }
    let scale: Double = value >= 1_000_000_000 ? 1_000_000_000 : value >= 1_000_000 ? 1_000_000 : 1_000
    return ocFixedOne(value / scale) + (scale == 1_000_000_000 ? "B" : scale == 1_000_000 ? "M" : "K")
}
/// Number.toFixed(1) rounds the exact binary value, with ties toward positive
/// infinity. printf uses ties-to-even and cannot preserve the renderer's cells.
func ocFixedOne(_ value: Double) -> String {
    guard value.isFinite, value < 1e21 else { return ocNumberString(value) }
    let bits = value.bitPattern
    let significand = (bits & 0x000f_ffff_ffff_ffff) | (1 << 52)
    let exponent = Int((bits >> 52) & 0x7ff) - 1023 - 52
    let numerator = significand * 10
    if exponent < 0 {
        let denominator: UInt64 = 1 << (-exponent)
        let rounded = numerator / denominator + ((numerator % denominator) * 2 >= denominator ? 1 : 0)
        return "\(rounded / 10).\(rounded % 10)"
    }
    // OpenCode reports finite numbers without Pi's safe-integer bound. Decimal
    // digits retain very large exact integer numerators without UInt64 overflow.
    var digits = Array(String(numerator).utf8.reversed()).map { Int($0 - 48) }
    for _ in 0..<exponent {
        var carry = 0
        for index in digits.indices { let next = digits[index] * 2 + carry; digits[index] = next % 10; carry = next / 10 }
        if carry > 0 { digits.append(carry) }
    }
    let result = digits.reversed().map(String.init).joined()
    return String(result.dropLast()) + "." + result.suffix(1)
}
func ocNumberString(_ value: Double) -> String {
    if value.isNaN { return "NaN" }; if value == .infinity { return "Infinity" }; if value == -.infinity { return "-Infinity" }
    if value == 0 { return "0" }
    let source = String(value)
    let components = source.lowercased().split(separator: "e", omittingEmptySubsequences: false)
    if components.count == 1 { return source.hasSuffix(".0") ? String(source.dropLast(2)) : source }
    let exponent = Int(components[1]) ?? 0
    var mantissa = String(components[0]); if mantissa.hasSuffix(".0") { mantissa.removeLast(2) }
    if abs(value) >= 1e21 || abs(value) < 1e-6 { return mantissa + "e" + (exponent >= 0 ? "+" : "") + String(exponent) }
    let negative = mantissa.hasPrefix("-"); if negative { mantissa.removeFirst() }
    let before = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
    let digits = mantissa.replacingOccurrences(of: ".", with: "")
    let position = before + exponent
    let expanded: String
    if position <= 0 { expanded = "0." + String(repeating: "0", count: -position) + digits }
    else if position >= digits.count { expanded = digits + String(repeating: "0", count: position - digits.count) }
    else { let index = digits.index(digits.startIndex, offsetBy: position); expanded = String(digits[..<index]) + "." + digits[index...] }
    return (negative ? "-" : "") + expanded
}

enum OpenCodeError: Error, LocalizedError { case invalidState, invalidSettings, expiredInteraction
    var errorDescription: String? { switch self { case .invalidState: "Invalid OpenCode session state"; case .invalidSettings: "Invalid OpenCode settings"; case .expiredInteraction: "OpenCode 请求已失效" } }
}
extension JSONValue {
    var ocString: JSONText? { if case .string(let value) = self { value } else { nil } }
    func ocText(_ key: String) -> JSONText? { self[key]?.ocString }
    func ocID(_ key: String) -> JSONText { ocText(key) ?? "" }
}
func ocRequiredText(_ value: JSONValue, _ key: String, nonempty: Bool = false) throws -> JSONText {
    guard let text = value.ocText(key), !nonempty || (!text.codeUnits.isEmpty && !text.codeUnits.contains(0)) else { throw OpenCodeError.invalidState }; return text
}
func ocOptionalText(_ value: JSONValue, _ keys: [String]) throws {
    guard keys.allSatisfy({ value[$0] == nil || value.ocText($0) != nil }) else { throw OpenCodeError.invalidState }
}
func ocOnly(_ value: JSONValue, _ keys: Set<String>) throws {
    let allowed = Set(keys.map { JSONText($0) })
    guard let object = value.objectValue, Set(object.keys).isSubset(of: allowed) else { throw OpenCodeError.invalidState }
}
func ocUnique(_ ids: [JSONText]) throws { guard Set(ids).count == ids.count else { throw OpenCodeError.invalidState } }
func ocNonnegative(_ value: JSONValue?) -> Bool { value?.numberValue.map { $0.isFinite && $0 >= 0 } == true }
func ocJoinedID(_ parts: [JSONText]) -> JSONText { JSONText(codeUnits: parts.flatMap(\.codeUnits)) }
func ocJSONStringID(_ values: [JSONValue]) -> JSONText {
    // JSON.stringify's short control escapes are part of the source identity.
    JSONText(codeUnits: [91] + values.enumerated().flatMap { index, value in
        (index > 0 ? [UInt16(44)] : []) + ocJSONString(value).codeUnits
    } + [93])
}
func ocJSONString(_ value: JSONValue) -> JSONText {
    if let number = value.numberValue { return JSONText(number.isFinite ? ocNumberString(number) : "null") }
    if case .string(let text) = value {
        let hex = Array("0123456789abcdef".utf16)
        var result: [UInt16] = [34]; var index = 0
        while index < text.codeUnits.count {
            let unit = text.codeUnits[index]; index += 1
            switch unit {
            case 34, 92: result += [92, unit]
            case 8: result += [92, 98]
            case 9: result += [92, 116]
            case 10: result += [92, 110]
            case 12: result += [92, 102]
            case 13: result += [92, 114]
            case 0xD800...0xDBFF where index < text.codeUnits.count && (0xDC00...0xDFFF).contains(text.codeUnits[index]):
                result += [unit, text.codeUnits[index]]; index += 1
            case 0...31, 0xD800...0xDFFF:
                result += [92, 117, hex[Int(unit >> 12)], hex[Int((unit >> 8) & 15)], hex[Int((unit >> 4) & 15)], hex[Int(unit & 15)]]
            default: result.append(unit)
            }
        }
        return JSONText(codeUnits: result + [34])
    }
    if case .array(let entries) = value { return ocJSONStringID(entries) }
    if case .object(let object) = value {
        let keys = object.keys.sorted { $0.codeUnits.lexicographicallyPrecedes($1.codeUnits) }
        var units: [UInt16] = [123]
        for (index, key) in keys.enumerated() {
            if index > 0 { units.append(44) }; units += ocJSONString(.string(key)).codeUnits + [58] + ocJSONString(object[key]!).codeUnits
        }
        return JSONText(codeUnits: units + [125])
    }
    return JSONText(String(decoding: (try? value.encodedData()) ?? Data(), as: UTF8.self))
}
func ocTrimText(_ value: JSONText) -> JSONText {
    func whitespace(_ unit: UInt16) -> Bool {
        switch unit { case 9...13, 32, 160, 5760, 8192...8202, 8232, 8233, 8239, 8287, 12288, 65279: true; default: false }
    }
    return JSONText(codeUnits: Array(value.codeUnits.drop(while: whitespace).reversed().drop(while: whitespace).reversed()))
}
func ocHeadText(_ value: JSONText, points: Int) -> JSONText {
    var index = 0, count = 0
    while index < value.codeUnits.count && count < points {
        let unit = value.codeUnits[index]
        index += (0xD800...0xDBFF).contains(unit) && index + 1 < value.codeUnits.count && (0xDC00...0xDFFF).contains(value.codeUnits[index + 1]) ? 2 : 1
        count += 1
    }
    return JSONText(codeUnits: Array(value.codeUnits.prefix(index)))
}
func ocPublicID(_ kind: String, _ parts: [JSONText]) -> JSONText {
    var digest = SHA256(); digest.update(data: Data("mokusei.opencode.public-interaction.v1".utf8))
    for part in parts { let data = Data(part.string.utf8); digest.update(data: Data("\(data.count):".utf8)); digest.update(data: data) }
    return JSONText("opencode-\(kind)-" + digest.finalize().map { String(format: "%02x", $0) }.joined())
}

func ocTrim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))) }

private func ocValidateRemainingState(_ state: JSONValue) throws {
    if let authors = state["executionAuthors"]?.objectValue {
        guard authors.count <= 10_000 else { throw OpenCodeError.invalidState }
        for (id, author) in authors {
            guard !id.codeUnits.isEmpty, id.codeUnits.count <= 1_024, !id.codeUnits.contains(0) else { throw OpenCodeError.invalidState }
            try ocOnly(author, ["model", "effort"])
            for field in author.objectValue?.values ?? Dictionary<JSONText, JSONValue>().values {
                guard let text = field.ocString, !ocTrim(text.string).isEmpty, text.codeUnits.count <= 4_096, !text.codeUnits.contains(0) else { throw OpenCodeError.invalidState }
            }
        }
    }
    if let entries = state["nativeContextEntries"] {
        guard let entries = entries.arrayValue else { throw OpenCodeError.invalidState }
        for entry in entries { try ocOnly(entry, ["id", "content"]); _ = try ocRequiredText(entry, "id"); _ = try ocRequiredText(entry, "content") }
    }
    for value in state["cursors"]?.objectValue?.values ?? Dictionary<JSONText, JSONValue>().values {
        guard let integer = value.intValue, integer >= 0, integer <= 9_007_199_254_740_991 else { throw OpenCodeError.invalidState }
    }
    for value in state["nativeExecutions"]?.objectValue?.values ?? Dictionary<JSONText, JSONValue>().values {
        guard let text = value.ocString, !text.codeUnits.isEmpty, !text.codeUnits.contains(0) else { throw OpenCodeError.invalidState }
    }
    for value in state["automaticExecutions"]?.objectValue?.values ?? Dictionary<JSONText, JSONValue>().values {
        guard let array = value.arrayValue, !array.isEmpty else { throw OpenCodeError.invalidState }
        let ids = try array.map { item -> JSONText in guard let text = item.ocString, !text.codeUnits.isEmpty, !text.codeUnits.contains(0) else { throw OpenCodeError.invalidState }; return text }
        try ocUnique(ids)
    }
    if let recorded = state["usageRecorded"] {
        guard let array = recorded.arrayValue else { throw OpenCodeError.invalidState }
        try ocUnique(try array.map { value in guard let text = value.ocString, !text.codeUnits.isEmpty, !text.codeUnits.contains(0) else { throw OpenCodeError.invalidState }; return text })
    }
    for entry in state["foregrounds"]?.arrayValue ?? [] {
        guard let foreground = entry["foreground"] else { throw OpenCodeError.invalidState }
        try ocOptionalText(entry, ["segmentId"])
        switch foreground["kind"]?.stringValue {
        case "reasoning":
            try ocOnly(foreground, ["kind", "sequence", "text", "textOffset"])
            let text = try ocRequiredText(foreground, "text")
            guard text.codeUnits.count <= 65_536, !text.codeUnits.contains(0), ocHeadText(text, points: 32_768) == text else { throw OpenCodeError.invalidState }
            if let offset = foreground["textOffset"] { guard let integer = offset.intValue, integer >= 0 else { throw OpenCodeError.invalidState } }
        case "assistant-text": try ocOnly(foreground, ["kind", "sequence"])
        case "tool-call":
            try ocOnly(foreground, ["kind", "sequence", "callId", "toolName"])
            _ = try ocRequiredText(foreground, "callId", nonempty: true)
            let toolName = try ocRequiredText(foreground, "toolName", nonempty: true)
            guard !ocTrimText(toolName).codeUnits.isEmpty, ocHeadText(toolName, points: 64) == toolName else { throw OpenCodeError.invalidState }
        default: throw OpenCodeError.invalidState
        }
    }
    for interaction in state["interactions"]?.arrayValue ?? [] {
        if let metadata = interaction["metadata"], metadata.objectValue == nil { throw OpenCodeError.invalidState }
        for field in interaction["fields"]?.arrayValue ?? [] {
            try ocValidateFormField(field)
        }
    }
}
private func ocValidateFormField(_ field: JSONValue) throws {
    let type = field["type"]?.stringValue ?? ""
    try ocOptionalText(field, ["title", "description"])
    if type == "external" { _ = try ocRequiredText(field, "url", nonempty: true); return }
    var form: [JSONText: JSONValue] = ["type": .text(type), "required": field["required"] ?? .bool(false)]
    for key in ["minimum", "maximum", "minLength", "maxLength", "pattern", "format", "minItems", "maxItems", "hidden", "default"] { form[JSONText(key)] = field[key] }
    if let when = field["when"] {
        guard let conditions = when.arrayValue else { throw OpenCodeError.invalidState }
        form["when"] = .array(try conditions.map { condition in
            let key = try ocRequiredText(condition, "key", nonempty: true)
            return .object(["questionId": .string(key), "op": condition["op"] ?? .null, "value": condition["value"] ?? .null])
        })
    }
    _ = try PublicQuestionForm(json: .object(form))
    if let options = field["options"] {
        guard let options = options.arrayValue else { throw OpenCodeError.invalidState }
        for option in options { _ = try ocRequiredText(option, "value"); _ = try ocRequiredText(option, "label"); try ocOptionalText(option, ["description"]) }
    }
    if type == "multiselect", field["options"]?.arrayValue == nil { throw OpenCodeError.invalidState }
    if let custom = field["custom"], custom.boolValue == nil { throw OpenCodeError.invalidState }
}

private func ocValidateAnnotation(_ value: JSONValue) throws {
    try ocOnly(value, ["id", "comment", "url", "title", "kind", "rect", "viewport", "selector", "text", "screenshotId"])
    func uuid(_ text: JSONText) -> Bool {
        text.string.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil || text == "00000000-0000-0000-0000-000000000000" || text == "ffffffff-ffff-ffff-ffff-ffffffffffff"
    }
    let comment = ocTrimText(try ocRequiredText(value, "comment"))
    guard uuid(try ocRequiredText(value, "id")), !comment.codeUnits.isEmpty, comment.codeUnits.count <= 10_000,
          ["element", "region"].contains(value["kind"]?.stringValue ?? ""),
          let url = URL(string: try ocRequiredText(value, "url").string), ["http", "https"].contains(url.scheme), url.host != nil,
          try ocRequiredText(value, "title").codeUnits.count <= 2_048 else { throw OpenCodeError.invalidState }
    try ocOptionalText(value, ["selector", "text", "screenshotId"])
    if let selector = value.ocText("selector"), selector.codeUnits.count > 4_096 { throw OpenCodeError.invalidState }
    if let text = value.ocText("text"), text.codeUnits.count > 4_000 { throw OpenCodeError.invalidState }
    if let screenshot = value.ocText("screenshotId"), !uuid(screenshot) { throw OpenCodeError.invalidState }
    guard let rect = value["rect"], let viewport = value["viewport"] else { throw OpenCodeError.invalidState }
    try ocOnly(rect, ["x", "y", "width", "height"]); try ocOnly(viewport, ["width", "height", "scrollX", "scrollY"])
    for key in ["x", "y", "width", "height"] {
        guard let number = rect[key]?.numberValue, number.isFinite, number >= 0, number <= 100_000,
              !["width", "height"].contains(key) || number > 0 else { throw OpenCodeError.invalidState }
    }
    for key in ["width", "height"] { guard let number = viewport[key]?.numberValue, number.isFinite, number > 0, number <= 100_000 else { throw OpenCodeError.invalidState } }
    for key in ["scrollX", "scrollY"] { guard viewport[key]?.numberValue?.isFinite == true else { throw OpenCodeError.invalidState } }
}
