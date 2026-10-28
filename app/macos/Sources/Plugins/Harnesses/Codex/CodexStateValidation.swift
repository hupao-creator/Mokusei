import Foundation
import MokuseiCore

/// Mirrors the owning plugin's persisted-state admission. The renderer must
/// reject malformed private payloads before interpreting presentation authority.
func codexValidateState(_ value: JSONValue) throws {
    guard CodexStateAdmission.json(value), CodexStateAdmission.state(value) else {
        throw CodexPresentationError.invalidState
    }
}

private enum CodexStateAdmission {
    static let persistedText = 8 * 1024 * 1024
    static let answer = 256 * 1024
    static let reasoning = 64 * 1024
    static let detail = 32 * 1024
    static let notice = 16 * 1024
    static let maxSafeInteger = 9_007_199_254_740_991.0

    static func json(_ value: JSONValue, depth: Int = 0) -> Bool {
        switch value {
        case .null, .bool, .string, .integer: return true
        case .number(let number): return number.isFinite
        case .array(let values):
            return depth < JSONValue.maximumDepth && values.allSatisfy { json($0, depth: depth + 1) }
        case .object(let values):
            return depth < JSONValue.maximumDepth && values.values.allSatisfy { json($0, depth: depth + 1) }
        }
    }

    static func state(_ value: JSONValue) -> Bool {
        guard keys(value, ["initialResponseScope", "schema", "primarySessionId", "nativeToolConfiguration", "nativeToolMode", "nativeHistorySeed", "forkHistory", "updatedAt", "nativeActivity", "backgroundTerminals", "turns"]),
              optional(value, "initialResponseScope", { $0.boolValue != nil }),
              value["schema"] == .text("mokusei.harness.codex.thread.v1"),
              let updatedAt = timestamp(value["updatedAt"]),
              let turns = value["turns"]?.arrayValue, turns.count <= 200,
              let terminals = value["backgroundTerminals"]?.arrayValue, terminals.count <= 2_000,
              terminals.allSatisfy(backgroundTerminal),
              optional(value, "primarySessionId", { canonical($0, 1_024) }),
              optional(value, "nativeToolConfiguration", { matches($0, "^[a-f0-9]{64}$") }),
              optional(value, "nativeToolMode", { member($0, ["extend", "exclusive"]) }),
              optional(value, "nativeHistorySeed", { bounded($0, persistedText) }),
              optional(value, "nativeActivity", { nativeActivity($0, at: updatedAt) }) else { return false }
        if let history = value["forkHistory"] {
            guard let history = history.arrayValue, history.count <= 200,
                  history.allSatisfy({ turn($0, at: updatedAt) && !active($0) &&
                      !($0["activities"]?.arrayValue ?? []).contains(where: { $0["status"] == .text("running") }) &&
                      !($0["interactions"]?.arrayValue ?? []).contains(where: { $0["status"] == .text("pending") }) }) else { return false }
        }
        return turns.allSatisfy { turn($0, at: updatedAt) }
    }

    static func backgroundTerminal(_ value: JSONValue) -> Bool {
        keys(value, ["id", "command", "cwd"]) && canonical(value["id"], 1_024) &&
            bounded(value["command"], detail) && bounded(value["cwd"], detail)
    }

    static func nativeActivity(_ value: JSONValue, at maximum: Double) -> Bool {
        keys(value, ["status", "detail", "updatedAt"]) && bounded(value["status"], 256) &&
            optional(value, "detail", { bounded($0, detail) }) && within(value["updatedAt"], 0, maximum)
    }

    static func turn(_ value: JSONValue, at stateUpdatedAt: Double) -> Bool {
        guard keys(value, ["executionId", "createdAt", "updatedAt", "finishedAt", "status", "statusLabel", "foreground", "reasoningBreak", "author", "runtimeModel", "runtimeServiceTier", "messages", "timeline", "answer", "lastAssistantMessage", "reasoning", "plan", "planExplanation", "activities", "interactions", "notices", "usage", "diff", "review", "contextCompacted", "error"]),
              canonical(value["executionId"], 1_024),
              let createdAt = timestamp(value["createdAt"]), let updatedAt = timestamp(value["updatedAt"]),
              updatedAt >= createdAt, updatedAt <= stateUpdatedAt,
              member(value["status"], ["running", "waiting-input", "completed", "failed", "interrupted"]),
              active(value) ? value["finishedAt"] == nil : within(value["finishedAt"], createdAt, updatedAt),
              optional(value, "statusLabel", { bounded($0, persistedText) }),
              optional(value, "foreground", foreground),
              optional(value, "reasoningBreak", { $0.boolValue != nil }),
              optional(value, "author", author),
              optional(value, "runtimeModel", { bounded($0, persistedText) }),
              optional(value, "runtimeServiceTier", { $0 == .null || canonical($0, 128) }),
              let messages = value["messages"]?.arrayValue,
              let timeline = value["timeline"]?.arrayValue,
              bounded(value["answer"], answer),
              optional(value, "lastAssistantMessage", assistantSnapshot),
              bounded(value["reasoning"], reasoning),
              let plan = value["plan"]?.arrayValue, plan.count <= 200,
              let activities = value["activities"]?.arrayValue,
              let interactions = value["interactions"]?.arrayValue,
              let notices = value["notices"]?.arrayValue,
              optional(value, "planExplanation", { bounded($0, detail) }),
              optional(value, "usage", usage),
              optional(value, "diff", { bounded($0, answer) }),
              optional(value, "review", { bounded($0, answer) }),
              optional(value, "contextCompacted", { $0.boolValue != nil }),
              optional(value, "error", { bounded($0, notice) }) else { return false }
        return messages.allSatisfy { message($0, from: createdAt, to: updatedAt) } &&
            timeline.allSatisfy { timelineItem($0, from: createdAt, to: updatedAt) } &&
            plan.allSatisfy(planStep) && activities.allSatisfy(activity) &&
            interactions.allSatisfy(interaction) && notices.allSatisfy(noticeItem)
    }

    static func active(_ value: JSONValue) -> Bool { member(value["status"], ["running", "waiting-input"]) }
    static func assistantSnapshot(_ value: JSONValue) -> Bool {
        keys(value, ["itemId", "text"]) && canonical(value["itemId"], 1_024) && bounded(value["text"], 100_000)
    }
    static func author(_ value: JSONValue) -> Bool {
        guard keys(value, ["model", "effort"]), let values = value.objectValue else { return false }
        return values.values.allSatisfy { bounded($0, 4_096) && !codexTrim($0).codeUnits.isEmpty }
    }
    static func message(_ value: JSONValue, from minimum: Double, to maximum: Double) -> Bool {
        guard keys(value, ["id", "role", "kind", "content", "createdAt", "attachments", "annotations", "internal"]),
              canonical(value["id"], 1_024), member(value["role"], ["user", "assistant"]),
              member(value["kind"], ["prompt", "follow-up", "answer"]), bounded(value["content"], persistedText),
              within(value["createdAt"], minimum, maximum),
              let attachments = value["attachments"]?.arrayValue, attachments.count <= 128,
              attachments.allSatisfy(attachment),
              optional(value, "annotations", annotations),
              optional(value, "internal", { $0 == .bool(true) }) else { return false }
        return true
    }
    static func attachment(_ value: JSONValue) -> Bool {
        keys(value, ["id", "name", "mimeType", "size", "kind"]) &&
            nonEmpty(value["id"], 1_024) && bounded(value["name"], 4 * 1024 * 1024) && bounded(value["mimeType"], 256) &&
            integer(value["size"], minimum: 0) && member(value["kind"], ["image", "audio", "file"])
    }
    static func timelineItem(_ value: JSONValue, from minimum: Double, to maximum: Double) -> Bool {
        guard canonical(value["id"], 1_024), within(value["createdAt"], minimum, maximum) else { return false }
        switch value["kind"]?.stringValue {
        case "user-message": return keys(value, ["id", "kind", "createdAt", "messageId"]) && canonical(value["messageId"], 1_024)
        case "activity": return keys(value, ["id", "kind", "createdAt", "activityId"]) && canonical(value["activityId"], 1_024)
        case "interaction": return keys(value, ["id", "kind", "createdAt", "interactionId"]) && canonical(value["interactionId"], 1_024)
        case "notice": return keys(value, ["id", "kind", "createdAt", "noticeId"]) && canonical(value["noticeId"], 1_024)
        case "assistant":
            return keys(value, ["id", "kind", "createdAt", "itemId", "content", "status"]) && canonical(value["itemId"], 1_024) &&
                bounded(value["content"], answer) && member(value["status"], ["complete", "streaming", "failed", "cancelled"])
        case "reasoning": return keys(value, ["id", "kind", "createdAt", "content"]) && bounded(value["content"], reasoning)
        default: return keys(value, ["id", "kind", "createdAt"]) && member(value["kind"], ["plan", "diff", "review", "context-compaction", "error"])
        }
    }
    static func planStep(_ value: JSONValue) -> Bool {
        keys(value, ["step", "status"]) && bounded(value["step"], persistedText) && member(value["status"], ["pending", "inProgress", "completed"])
    }
    static func activity(_ value: JSONValue) -> Bool {
        keys(value, ["id", "kind", "label", "status", "detail", "toolName", "toolCall", "filePaths"]) && canonical(value["id"], 1_024) &&
            member(value["kind"], ["command", "file", "tool", "search", "agent", "subagent", "review", "hook"]) &&
            bounded(value["label"], detail) && member(value["status"], ["running", "completed", "failed", "cancelled"]) &&
            optional(value, "detail", { bounded($0, detail) }) && optional(value, "toolCall", { $0.boolValue != nil }) &&
            optional(value, "toolName", { nonEmpty($0, 1_024) }) &&
            optional(value, "filePaths", { $0.arrayValue?.allSatisfy { nonEmpty($0, persistedText) } == true })
    }
    static func foreground(_ value: JSONValue) -> Bool {
        guard integer(value["sequence"], minimum: 1) else { return false }
        switch value["kind"]?.stringValue {
        case "assistant-text": return keys(value, ["sequence", "kind"])
        case "reasoning":
            return keys(value, ["sequence", "kind", "text", "textOffset"]) && reasoningSource(value["text"]) &&
                optional(value, "textOffset", { integer($0, minimum: 0) })
        case "tool-call":
            return keys(value, ["sequence", "kind", "callId", "toolName"]) &&
                canonical(value["callId"], 1_024) && nonEmpty(value["toolName"], 1_024)
        default: return false
        }
    }
    static func reasoningSource(_ value: JSONValue?) -> Bool {
        guard bounded(value, 65_536), case .string(let text) = value else { return false }
        var index = 0
        var points = 0
        while index < text.codeUnits.count {
            let unit = text.codeUnits[index]
            index += (0xD800...0xDBFF).contains(unit) && index + 1 < text.codeUnits.count &&
                (0xDC00...0xDFFF).contains(text.codeUnits[index + 1]) ? 2 : 1
            points += 1
            if points > 32_768 { return false }
        }
        return true
    }
    static func interaction(_ value: JSONValue) -> Bool {
        let mcp = value["kind"] == .text("mcp-elicitation")
        guard keys(value, ["id", "kind", "title", "detail", "blocksTurn", "status", "resolution", "actions", "questions"] + (mcp ? ["elicitation", "mcpSchemaDisplay"] : [])),
              canonical(value["id"], 1_024),
              member(value["kind"], ["command-approval", "file-approval", "permissions", "user-input", "mcp-elicitation"]),
              bounded(value["title"], persistedText), optional(value, "detail", { bounded($0, persistedText) }),
              value["blocksTurn"]?.boolValue != nil,
              member(value["status"], ["pending", "allowed", "denied", "submitted", "cancelled", "resolved"]),
              optional(value, "resolution", { bounded($0, 1_000) }),
              let actions = value["actions"]?.arrayValue, actions.allSatisfy(interactionAction),
              let questions = value["questions"]?.arrayValue, questions.allSatisfy(question) else { return false }
        guard mcp else { return true }
        guard let elicitation = value["elicitation"], elicitation.objectValue != nil else { return false }
        if elicitation["mode"] == .text("url") {
            return value["mcpSchemaDisplay"] == nil && keys(elicitation, ["mode", "url"]) && nonEmpty(elicitation["url"], persistedText) && questions.isEmpty
        }
        return elicitation["mode"] == .text("form") && keys(elicitation, ["mode", "requestedSchema", "questionId"]) &&
            elicitation["requestedSchema"]?.objectValue != nil && nonEmpty(elicitation["questionId"], persistedText) &&
            questions.count == 1 && questions[0]["id"] == elicitation["questionId"] &&
            optional(value, "mcpSchemaDisplay", { codexJSONSchemaDisplayMatches($0, schema: elicitation["requestedSchema"]!, limit: Int.max) })
    }
    static func interactionAction(_ value: JSONValue) -> Bool {
        keys(value, ["id", "intent", "label"]) && member(value["id"], ["allow-once", "allow-session", "deny", "cancel", "submit"]) &&
            member(value["intent"], ["allow", "deny", "cancel", "submit"]) && bounded(value["label"], persistedText)
    }
    static func question(_ value: JSONValue) -> Bool {
        guard keys(value, ["id", "header", "prompt", "secret", "allowOther", "options"]),
              nonEmpty(value["id"], persistedText), optional(value, "header", { bounded($0, persistedText) }),
              bounded(value["prompt"], persistedText), value["secret"]?.boolValue != nil, value["allowOther"]?.boolValue != nil,
              let options = value["options"]?.arrayValue else { return false }
        return options.allSatisfy { keys($0, ["id", "label", "description"]) && nonEmpty($0["id"], persistedText) &&
            bounded($0["label"], persistedText) && optional($0, "description", { bounded($0, persistedText) }) }
    }
    static func noticeItem(_ value: JSONValue) -> Bool {
        keys(value, ["id", "level", "message"]) && canonical(value["id"], 1_024) &&
            member(value["level"], ["info", "warning", "error"]) && bounded(value["message"], notice)
    }
    static func usage(_ value: JSONValue) -> Bool {
        guard keys(value, ["inputTokens", "cachedInputTokens", "outputTokens", "reasoningTokens", "contextWindow"]),
              let values = value.objectValue else { return false }
        return values.values.allSatisfy { $0.numberValue?.isFinite == true }
    }

    static func annotations(_ value: JSONValue) -> Bool {
        guard let values = value.arrayValue, values.count <= 20 else { return false }
        return values.allSatisfy(annotation)
    }
    static func annotation(_ value: JSONValue) -> Bool {
        guard keys(value, ["id", "comment", "url", "title", "kind", "rect", "viewport", "selector", "text", "screenshotId"]),
              uuid(value["id"]), let comment = text(value["comment"]),
              !codexTrim(.string(comment)).codeUnits.isEmpty, codexTrim(.string(comment)).codeUnits.count <= 10_000,
              browserURL(value["url"]),
              stringLimit(value["title"], 2_048), member(value["kind"], ["element", "region"]),
              let rect = value["rect"], keys(rect, ["x", "y", "width", "height"]),
              coordinate(rect["x"]), coordinate(rect["y"]), coordinate(rect["width"], positive: true), coordinate(rect["height"], positive: true),
              let viewport = value["viewport"], keys(viewport, ["width", "height", "scrollX", "scrollY"]),
              coordinate(viewport["width"], positive: true), coordinate(viewport["height"], positive: true),
              viewport["scrollX"]?.numberValue?.isFinite == true, viewport["scrollY"]?.numberValue?.isFinite == true,
              optional(value, "selector", { stringLimit($0, 4_096) }), optional(value, "text", { stringLimit($0, 4_000) }),
              optional(value, "screenshotId", uuid) else { return false }
        return true
    }
    static func coordinate(_ value: JSONValue?, positive: Bool = false) -> Bool {
        guard let number = value?.numberValue, number.isFinite else { return false }
        return number <= 100_000 && (positive ? number > 0 : number >= 0)
    }
    static func uuid(_ value: JSONValue?) -> Bool {
        matches(value, "^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$")
    }
    /// Browser annotations use the web URL parser, whose HTTP syntax accepts
    /// omitted slashes and numeric IPv4 spellings but rejects oversized ports.
    /// Normalize that syntax before Foundation's URL/IDNA validation.
    static func browserURL(_ value: JSONValue?) -> Bool {
        guard let original = value?.stringValue,
              original.hasPrefix("http:") || original.hasPrefix("https:") else { return false }
        let scheme = original.hasPrefix("https:") ? "https:" : "http:"
        var suffix = String(original.dropFirst(scheme.count))
            .filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
            .replacingOccurrences(of: "\\", with: "/")
        while suffix.unicodeScalars.last.map({ $0.value <= 0x20 }) == true { suffix.removeLast() }
        while suffix.first == "/" { suffix.removeFirst() }
        let authority = String(suffix.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        let hostPort = String(authority.split(separator: "@", omittingEmptySubsequences: false).last ?? "")
        guard !hostPort.isEmpty else { return false }
        let host: String
        let port: String?
        if hostPort.first == "[" {
            guard let close = hostPort.firstIndex(of: "]") else { return false }
            host = String(hostPort[...close])
            let remainder = hostPort[hostPort.index(after: close)...]
            guard remainder.isEmpty || remainder.first == ":" else { return false }
            port = remainder.isEmpty ? nil : String(remainder.dropFirst())
        } else {
            let parts = hostPort.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return false }
            host = String(parts[0]); port = parts.count == 2 ? String(parts[1]) : nil
        }
        if let port, !port.isEmpty {
            guard port.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(port), number <= 65_535 else { return false }
        }
        guard let decodedHost = host.removingPercentEncoding, !decodedHost.isEmpty else { return false }
        if host.first != "[" {
            let forbidden = Set("#/:<>?@[\\]^|".unicodeScalars.map(\.value))
            guard !decodedHost.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F || forbidden.contains($0.value) }) else { return false }
            var parts = decodedHost.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if parts.last == "" { parts.removeLast() }
            if let last = parts.last, (!last.isEmpty && last.utf8.allSatisfy { (48...57).contains($0) } || ipv4Number(last) != nil) {
                guard !parts.isEmpty, parts.count <= 4 else { return false }
                let numbers = parts.compactMap(ipv4Number)
                guard numbers.count == parts.count, numbers.dropLast().allSatisfy({ $0 <= 255 }),
                      let final = numbers.last, final < UInt64(1) << (8 * (5 - numbers.count)) else { return false }
            }
        }
        guard let parsed = URL(string: scheme + "//" + suffix), let parsedHost = parsed.host, !parsedHost.isEmpty else { return false }
        return true
    }
    static func ipv4Number(_ value: String) -> UInt64? {
        var number = value
        var radix = 10
        if number.hasPrefix("0x") || number.hasPrefix("0X") { radix = 16; number = String(number.dropFirst(2)) }
        else if number.count >= 2 && number.first == "0" { radix = 8; number = String(number.dropFirst()) }
        if number.isEmpty { return 0 }
        guard number.utf8.allSatisfy({ (48...57).contains($0) || radix == 16 && ((65...70).contains($0) || (97...102).contains($0)) }) else { return nil }
        return UInt64(number, radix: radix)
    }
    static func keys(_ value: JSONValue, _ allowed: [String]) -> Bool {
        guard let object = value.objectValue else { return false }
        let allowed = Set(allowed.map { JSONText($0) })
        return object.keys.allSatisfy(allowed.contains)
    }
    static func optional(_ object: JSONValue, _ key: String, _ validate: (JSONValue) -> Bool) -> Bool {
        object[key].map(validate) ?? true
    }
    static func text(_ value: JSONValue?) -> JSONText? { if case .string(let text) = value { return text }; return nil }
    static func bounded(_ value: JSONValue?, _ maximum: Int) -> Bool {
        guard let value = text(value) else { return false }
        return value.codeUnits.count <= maximum && !value.codeUnits.contains(0)
    }
    static func stringLimit(_ value: JSONValue?, _ maximum: Int) -> Bool { text(value).map { $0.codeUnits.count <= maximum } ?? false }
    static func nonEmpty(_ value: JSONValue?, _ maximum: Int) -> Bool { bounded(value, maximum) && text(value)?.codeUnits.isEmpty == false }
    static func canonical(_ value: JSONValue?, _ maximum: Int) -> Bool { nonEmpty(value, maximum) && text(value) == codexTrim(value) }
    static func member(_ value: JSONValue?, _ values: [String]) -> Bool {
        guard let value = text(value) else { return false }
        return values.contains { JSONText($0) == value }
    }
    static func timestamp(_ value: JSONValue?) -> Double? {
        guard let number = value?.numberValue, number.isFinite, number >= 0 else { return nil }
        return number
    }
    static func within(_ value: JSONValue?, _ minimum: Double, _ maximum: Double) -> Bool {
        timestamp(value).map { $0 >= minimum && $0 <= maximum } ?? false
    }
    static func integer(_ value: JSONValue?, minimum: Double) -> Bool {
        guard let number = value?.numberValue, number.isFinite else { return false }
        return number.rounded(.towardZero) == number && number >= minimum && abs(number) <= maxSafeInteger
    }
    static func matches(_ value: JSONValue?, _ pattern: String) -> Bool {
        guard let text = value?.stringValue else { return false }
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
