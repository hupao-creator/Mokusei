import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Pi owns this durable boundary. Never repair a malformed private session into
/// an apparently empty conversation; identities remain JavaScript UTF-16 text.
struct PiState {
    let initialResponseScope: Bool
    let raw: JSONValue
    let messages: [PiMessage]
    let messagesByExecution: [JSONText: [PiMessage]]
    let executionUsage: [JSONText: PiUsage]
    let executions: [PublicExecution]
    let latestExecutionID: JSONText?
    let authors: [JSONText: JSONValue]
    let foregrounds: [JSONText: HarnessActivity]

    init(_ value: JSONValue) throws {
        if let flag = value["initialResponseScope"], flag.boolValue == nil { throw PiReader.failure }
        initialResponseScope = value == .null || value["initialResponseScope"] == .bool(true)
        raw = value == .null ? .object(["version": .number(1), "messages": .array([]), "executions": .array([]), "latestExecutionId": .null]) : value
        let r = try PiReader(raw)
        try r.only(["initialResponseScope", "version", "sessionFile", "nativeSessionJsonl", "forkSource", "messages", "executions", "executionAuthors", "latestExecutionId", "foregrounds", "executionUsage"])
        guard r.value["version"] == .number(1) else { throw PiReader.failure }
        if r.value["sessionFile"] != nil { _ = try r.text("sessionFile", maximum: 100_000, nonempty: true, noNUL: true) }
        _ = try r.optionalText("nativeSessionJsonl")
        if let fork = r.value["forkSource"] { let f = try PiReader(fork); try f.only(["jsonl"]); _ = try f.text("jsonl") }
        messages = try r.array("messages").map(PiMessage.init)
        messagesByExecution = Dictionary(grouping: messages, by: \.executionID)
        if let usage = r.value["executionUsage"] {
            executionUsage = try PiReader(usage).values.mapValues(PiUsage.init)
        } else {
            // Full durable states retain per-call usage. Compact Go projections
            // carry the same totals explicitly because they omit most messages.
            executionUsage = messagesByExecution.compactMapValues { rows in
                let usages = rows.filter { $0.role == "assistant" }.compactMap(\.usage)
                return usages.isEmpty ? nil : PiUsage(summing: usages)
            }
        }
        executions = try r.array("executions").map { try PublicExecution(json: $0) }
        guard Set(messages.map(\.id)).count == messages.count,
              Set(executions.map(\.executionID)).count == executions.count else { throw PiReader.failure }
        latestExecutionID = r.value["latestExecutionId"] == .null ? nil : try r.text("latestExecutionId", maximum: 1_024, nonempty: true, noNUL: true)
        if let value = r.value["executionAuthors"] {
            let values = try PiReader(value).values
            guard values.count <= 10_000 else { throw PiReader.failure }
            for (key, value) in values {
                try PiReader.validate(key, maximum: 1_024, nonempty: true, noNUL: true)
                let author = try PiReader(value); try author.only(["model", "effort"])
                for field in author.values.values {
                    guard case let .string(text) = field, !piTrim(text).codeUnits.isEmpty else { throw PiReader.failure }
                    try PiReader.validate(text, maximum: 4_096, noNUL: true)
                }
            }
            authors = values
        } else { authors = [:] }
        var activities: [JSONText: HarnessActivity] = [:]
        if r.value["foregrounds"] != nil {
            for value in try r.array("foregrounds") {
                let entry = try PiReader(value); try entry.only(["executionId", "foreground"])
                let id = try entry.text("executionId", maximum: 1_024, nonempty: true, noNUL: true)
                guard activities[id] == nil else { throw PiReader.failure }
                let foreground = try PiReader(entry.required("foreground"))
                let sequence = try foreground.integer("sequence", minimum: 1)
                let body: HarnessActivityBody
                switch try foreground.text("kind") {
                case "assistant-text":
                    try foreground.only(["sequence", "kind"]); body = .assistantText
                case "reasoning":
                    try foreground.only(["sequence", "kind", "text", "textOffset"])
                    let text = try foreground.text("text", maximum: 65_536, nonempty: true, noNUL: true)
                    guard piPointCount(text) <= 32_768 else { throw PiReader.failure }
                    let offset = foreground.value["textOffset"] == nil ? nil : try foreground.integer("textOffset")
                    body = .reasoning(text: text, textOffset: offset)
                case "tool-call":
                    try foreground.only(["sequence", "kind", "callId", "toolName"])
                    body = .toolCall(callID: try foreground.text("callId", maximum: 1_024, nonempty: true, noNUL: true),
                                     toolName: try foreground.text("toolName", maximum: 1_024, nonempty: true, noNUL: true))
                default: throw PiReader.failure
                }
                activities[id] = HarnessActivity(executionID: id, sequence: sequence, body: body)
            }
        }
        foregrounds = activities
    }
}

struct PiMessage: Identifiable {
    let raw: JSONValue
    let id: JSONText
    let executionID: JSONText
    let role: JSONText
    let text: JSONText
    let status: JSONText?
    let thinking: JSONText?
    let toolCallID: JSONText?
    let toolName: JSONText?
    let isError: Bool
    let todos: [PiTodo]?
    let model: JSONText?
    let provider: JSONText?
    let usage: PiUsage?
    let annotations: [JSONValue]
    init(_ raw: JSONValue) throws {
        self.raw = raw
        let r = try PiReader(raw)
        id = try r.text("id", maximum: 100_000, nonempty: true, noNUL: true)
        executionID = try r.text("executionId", maximum: 1_024, nonempty: true, noNUL: true)
        role = try r.text("role"); text = try r.text("text")
        let common: Set<JSONText> = ["id", "executionId", "role", "text"]
        switch role {
        case "user": try r.only(common.union(["annotations"]))
        case "assistant": try r.only(common.union(["status", "thinking", "model", "provider", "usage"]))
        case "tool": try r.only(common.union(["toolCallId", "toolName", "isError", "todos"]))
        default: throw PiReader.failure
        }
        status = try r.optionalText("status")
        if let status, ![JSONText("streaming"), "complete", "failed", "cancelled"].contains(status) { throw PiReader.failure }
        thinking = try r.optionalText("thinking"); model = try r.optionalText("model"); provider = try r.optionalText("provider")
        toolCallID = try r.optionalText("toolCallId", maximum: 1_024, nonempty: true, noNUL: true)
        toolName = try r.optionalText("toolName")
        isError = try r.optionalBool("isError") ?? false
        usage = try r.value["usage"].map(PiUsage.init)
        if r.value["todos"] != nil {
            guard toolName == "todo", !isError else { throw PiReader.failure }
            let values = try r.array("todos").map(PiTodo.init)
            guard Set(values.map(\.id)).count == values.count else { throw PiReader.failure }
            todos = values
        } else { todos = nil }
        annotations = r.value["annotations"] == nil ? [] : try r.array("annotations")
        guard annotations.count <= 20 else { throw PiReader.failure }
        for annotation in annotations { try piValidateAnnotation(annotation) }
    }
}

struct PiUsage {
    let input: Double; let output: Double; let cacheRead: Double; let cacheWrite: Double
    let reasoning: Double?; let cost: Double?
    var prompt: Double { input + cacheRead + cacheWrite }
    var total: Double { prompt + output }
    init(summing values: [PiUsage]) {
        input = values.reduce(0) { $0 + $1.input }; output = values.reduce(0) { $0 + $1.output }
        cacheRead = values.reduce(0) { $0 + $1.cacheRead }; cacheWrite = values.reduce(0) { $0 + $1.cacheWrite }
        reasoning = values.allSatisfy { $0.reasoning != nil } ? values.reduce(0) { $0 + ($1.reasoning ?? 0) } : nil
        cost = values.allSatisfy { $0.cost != nil } ? values.reduce(0) { $0 + ($1.cost ?? 0) } : nil
    }
    init(_ value: JSONValue) throws {
        let r = try PiReader(value); try r.only(["input", "output", "cacheRead", "cacheWrite", "reasoning", "cost"])
        input = Double(try r.integer("input")); output = Double(try r.integer("output"))
        cacheRead = Double(try r.integer("cacheRead")); cacheWrite = Double(try r.integer("cacheWrite"))
        reasoning = r.value["reasoning"] == nil ? nil : Double(try r.integer("reasoning"))
        cost = r.value["cost"] == nil ? nil : try r.number("cost", minimum: 0)
    }
}
struct PiTodo {
    let id: Int; let text: JSONText; let done: Bool
    init(_ value: JSONValue) throws {
        let r = try PiReader(value); try r.only(["id", "text", "done"])
        id = try r.integer("id", minimum: 1); text = try r.text("text", noNUL: true)
        guard !piTrim(text).codeUnits.isEmpty else { throw PiReader.failure }
        done = try r.bool("done")
    }
}

struct PiReader {
    let value: JSONValue
    let values: [JSONText: JSONValue]
    static var failure: PluginContractError { PluginContractError("Invalid Pi session state") }
    init(_ value: JSONValue) throws {
        guard case let .object(values) = value else { throw Self.failure }
        self.value = value; self.values = values
    }
    func only(_ allowed: Set<JSONText>) throws { guard values.keys.allSatisfy(allowed.contains) else { throw Self.failure } }
    func required(_ key: String) throws -> JSONValue { guard let result = value[key] else { throw Self.failure }; return result }
    static func validate(_ value: JSONText, maximum: Int = .max, nonempty: Bool = false, noNUL: Bool = false) throws {
        guard value.codeUnits.count <= maximum, !nonempty || !value.codeUnits.isEmpty,
              !noNUL || !value.codeUnits.contains(0) else { throw failure }
    }
    func text(_ key: String, maximum: Int = .max, nonempty: Bool = false, noNUL: Bool = false) throws -> JSONText {
        guard case let .string(text) = try required(key) else { throw Self.failure }
        try Self.validate(text, maximum: maximum, nonempty: nonempty, noNUL: noNUL); return text
    }
    func optionalText(_ key: String, maximum: Int = .max, nonempty: Bool = false, noNUL: Bool = false) throws -> JSONText? {
        value[key] == nil ? nil : try text(key, maximum: maximum, nonempty: nonempty, noNUL: noNUL)
    }
    func array(_ key: String) throws -> [JSONValue] { guard case let .array(v) = try required(key) else { throw Self.failure }; return v }
    func bool(_ key: String) throws -> Bool { guard case let .bool(v) = try required(key) else { throw Self.failure }; return v }
    func optionalBool(_ key: String) throws -> Bool? { value[key] == nil ? nil : try bool(key) }
    func number(_ key: String, minimum: Double = -.infinity, maximum: Double = .infinity) throws -> Double {
        guard let v = try required(key).numberValue, v.isFinite, v >= minimum, v <= maximum else { throw Self.failure }; return v
    }
    func integer(_ key: String, minimum: Int = 0) throws -> Int {
        let v = try number(key, minimum: Double(minimum), maximum: 9_007_199_254_740_991)
        guard let integer = Int(exactly: v) else { throw Self.failure }; return integer
    }
}

func piText(_ value: JSONValue?) -> JSONText? { if case let .string(text) = value { return text }; return nil }
func piTrim(_ value: JSONText) -> JSONText {
    func whitespace(_ unit: UInt16) -> Bool {
        switch unit { case 9...13, 32, 160, 5760, 8192...8202, 8232, 8233, 8239, 8287, 12288, 65279: true; default: false }
    }
    return JSONText(codeUnits: Array(value.codeUnits.drop(while: whitespace).reversed().drop(while: whitespace).reversed()))
}
func piPointCount(_ text: JSONText) -> Int {
    var count = 0; var index = 0
    while index < text.codeUnits.count {
        let unit = text.codeUnits[index]
        if (0xD800...0xDBFF).contains(unit), index + 1 < text.codeUnits.count, (0xDC00...0xDFFF).contains(text.codeUnits[index + 1]) {
            index += 2
        } else { index += 1 }
        count += 1
    }
    return count
}
func piHead(_ text: JSONText, _ points: Int) -> JSONText {
    var index = 0; var count = 0
    while index < text.codeUnits.count && count < points {
        let unit = text.codeUnits[index]
        index += (0xD800...0xDBFF).contains(unit) && index + 1 < text.codeUnits.count && (0xDC00...0xDFFF).contains(text.codeUnits[index + 1]) ? 2 : 1
        count += 1
    }
    return JSONText(codeUnits: Array(text.codeUnits.prefix(index)))
}
func piKey(_ parts: [JSONText]) -> JSONText {
    // JSON.stringify arrays are the shipped public identity convention.
    // Its short control escapes differ from the transport encoder's \u00xx.
    var units: [UInt16] = [91]
    let hex = Array("0123456789abcdef".utf16)
    for (position, part) in parts.enumerated() {
        if position > 0 { units.append(44) }; units.append(34)
        var index = 0
        while index < part.codeUnits.count {
            let unit = part.codeUnits[index]; index += 1
            switch unit {
            case 34, 92: units += [92, unit]
            case 8: units += [92, 98]
            case 9: units += [92, 116]
            case 10: units += [92, 110]
            case 12: units += [92, 102]
            case 13: units += [92, 114]
            case 0xD800...0xDBFF where index < part.codeUnits.count && (0xDC00...0xDFFF).contains(part.codeUnits[index]):
                units += [unit, part.codeUnits[index]]; index += 1
            case 0...31, 0xD800...0xDFFF:
                units += [92, 117, hex[Int(unit >> 12)], hex[Int((unit >> 8) & 15)], hex[Int((unit >> 4) & 15)], hex[Int(unit & 15)]]
            default: units.append(unit)
            }
        }
        units.append(34)
    }
    units.append(93)
    return JSONText(codeUnits: units)
}
private func piValidateAnnotation(_ value: JSONValue) throws {
    let r = try PiReader(value)
    try r.only(["id", "comment", "url", "title", "kind", "rect", "viewport", "selector", "text", "screenshotId"])
    func uuid(_ text: JSONText) -> Bool {
        text.string.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil || text == "00000000-0000-0000-0000-000000000000" || text == "ffffffff-ffff-ffff-ffff-ffffffffffff"
    }
    guard uuid(try r.text("id")), !(piTrim(try r.text("comment"))).codeUnits.isEmpty,
          piTrim(try r.text("comment")).codeUnits.count <= 10_000,
          [JSONText("element"), "region"].contains(try r.text("kind")),
          piValidAnnotationURL(try r.text("url")) else { throw PiReader.failure }
    _ = try r.text("title", maximum: 2_048)
    _ = try r.optionalText("selector", maximum: 4_096); _ = try r.optionalText("text", maximum: 4_000)
    if let screenshot = try r.optionalText("screenshotId"), !uuid(screenshot) { throw PiReader.failure }
    let rect = try PiReader(r.required("rect")); try rect.only(["x", "y", "width", "height"])
    for key in ["x", "y", "width", "height"] {
        let number = try rect.number(key, minimum: 0, maximum: 100_000)
        if ["width", "height"].contains(key), number == 0 { throw PiReader.failure }
    }
    let viewport = try PiReader(r.required("viewport")); try viewport.only(["width", "height", "scrollX", "scrollY"])
    for key in ["width", "height"] { guard try viewport.number(key, minimum: 0, maximum: 100_000) > 0 else { throw PiReader.failure } }
    _ = try viewport.number("scrollX"); _ = try viewport.number("scrollY")
}

private func piValidAnnotationURL(_ text: JSONText) -> Bool {
    // Match the HTTP(S) special-URL forms admitted by BrowserAnnotationSchema:
    // WHATWG URL also accepts http:host and a single slash, unlike Foundation.
    let value = text.string
    let prefix: String
    if value.hasPrefix("https:") { prefix = "https:" }
    else if value.hasPrefix("http:") { prefix = "http:" }
    else { return false }
    var rest = String(value.dropFirst(prefix.count)).replacingOccurrences(of: "\t", with: "")
        .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "\\", with: "/")
    rest = String(rest.drop(while: { $0 == "/" }))
    let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    let hostPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
    guard !hostPort.isEmpty, !hostPort.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
          let url = URL(string: prefix + "//" + rest), url.host?.isEmpty == false,
          url.port.map({ (0...65_535).contains($0) }) ?? true else { return false }
    return true
}
