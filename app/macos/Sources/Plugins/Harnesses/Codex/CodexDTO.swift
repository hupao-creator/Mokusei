import Foundation
import MokuseiCore

/// Codex owns this occurrence model. The host sees opaque row keys, never a
/// second interpretation of Codex's native events. Raw values retain transport
/// identity and distinguish omitted fields from explicit nulls.
struct CodexState: Sendable, Hashable {
    let raw: JSONValue
    let turns: [CodexTurn]
    let forkHistory: [CodexTurn]
    let initialResponseScope: Bool

    init(_ value: JSONValue, createdAt: Double = 0) throws {
        if value == .null {
            raw = codexObject(["schema": .text("mokusei.harness.codex.thread.v1"),
                               "updatedAt": .number(createdAt), "turns": .array([]),
                               "backgroundTerminals": .array([])])
            turns = []; forkHistory = []; initialResponseScope = true; return
        }
        try codexValidateState(value)
        guard value["schema"]?.stringValue == "mokusei.harness.codex.thread.v1",
              value["updatedAt"]?.numberValue != nil,
              let turns = value["turns"]?.arrayValue, turns.count <= 200,
              let terminals = value["backgroundTerminals"]?.arrayValue, terminals.count <= 2_000,
              terminals.allSatisfy({ $0["id"]?.stringValue != nil && $0["command"]?.stringValue != nil && $0["cwd"]?.stringValue != nil })
        else { throw CodexPresentationError.invalidState }
        initialResponseScope = value["initialResponseScope"]?.boolValue ?? false
        raw = value
        self.turns = try turns.map(CodexTurn.init)
        forkHistory = try (value["forkHistory"]?.arrayValue ?? []).map(CodexTurn.init)
    }

    var updatedAt: Double { raw["updatedAt"]?.numberValue ?? 0 }
    var backgroundTerminals: [JSONValue] { raw["backgroundTerminals"]?.arrayValue ?? [] }
    var nativeActivity: JSONValue? { raw["nativeActivity"] }
}

struct CodexTurn: Sendable, Hashable, Identifiable {
    let raw: JSONValue
    let executionId: JSONText
    let messages: [CodexMessage]
    let timeline: [CodexTimelineItem]
    let activities: [CodexActivity]
    let interactions: [CodexInteraction]

    init(_ value: JSONValue) throws {
        guard case let .string(id)? = value["executionId"], !id.codeUnits.isEmpty,
              let status = value["status"]?.stringValue,
              ["running", "waiting-input", "completed", "failed", "interrupted"].contains(status),
              value["createdAt"]?.numberValue != nil, value["updatedAt"]?.numberValue != nil,
              value["answer"]?.stringValue != nil, value["reasoning"]?.stringValue != nil,
              value["plan"]?.arrayValue != nil, value["notices"]?.arrayValue != nil,
              let messages = value["messages"]?.arrayValue,
              let timeline = value["timeline"]?.arrayValue,
              let activities = value["activities"]?.arrayValue,
              let interactions = value["interactions"]?.arrayValue
        else { throw CodexPresentationError.invalidState }
        raw = value; executionId = id
        self.messages = try messages.map(CodexMessage.init)
        self.timeline = try timeline.map(CodexTimelineItem.init)
        self.activities = try activities.map(CodexActivity.init)
        self.interactions = try interactions.map(CodexInteraction.init)
    }
    var id: JSONText { executionId }
    var rowID: JSONText { JSONText(codeUnits: Array("turn:".utf16) + executionId.codeUnits) }
    var createdAt: Double { raw["createdAt"]!.numberValue! }
    var updatedAt: Double { raw["updatedAt"]!.numberValue! }
    var finishedAt: Double? { raw["finishedAt"]?.numberValue }
    var status: String { raw["status"]!.stringValue! }
    var statusLabel: String? { raw["statusLabel"]?.stringValue }
    var answer: String { raw["answer"]!.stringValue! }
    var reasoning: String { raw["reasoning"]!.stringValue! }
    var plan: [JSONValue] { raw["plan"]!.arrayValue! }
    var planExplanation: String? { raw["planExplanation"]?.stringValue }
    var notices: [JSONValue] { raw["notices"]!.arrayValue! }
    var usage: JSONValue? { raw["usage"] }
    var author: JSONValue? { raw["author"] }
    var runtimeModel: String? { raw["runtimeModel"]?.stringValue }
    var review: String? { raw["review"]?.stringValue }
    var error: String? { raw["error"]?.stringValue }
    var active: Bool { status == "running" || status == "waiting-input" }
}

struct CodexMessage: Sendable, Hashable, Identifiable {
    let raw: JSONValue
    init(_ value: JSONValue) throws {
        guard value["id"]?.stringValue != nil, value["content"]?.stringValue != nil,
              ["user", "assistant"].contains(value["role"]?.stringValue ?? ""),
              ["prompt", "follow-up", "answer"].contains(value["kind"]?.stringValue ?? ""),
              value["attachments"]?.arrayValue != nil else { throw CodexPresentationError.invalidState }
        raw = value
    }
    var id: JSONText { raw.codexIdentity("id") }
    var role: String { raw["role"]!.stringValue! }
    var kind: String { raw["kind"]!.stringValue! }
    var content: String { raw["content"]!.stringValue! }
    var isInternal: Bool { raw["internal"]?.boolValue == true }
    var annotations: [JSONValue] { raw["annotations"]?.arrayValue ?? [] }
    var attachments: [JSONValue] { raw["attachments"]!.arrayValue! }
}

struct CodexTimelineItem: Sendable, Hashable, Identifiable {
    let raw: JSONValue
    init(_ value: JSONValue) throws {
        guard value["id"]?.stringValue != nil,
              let kind = value["kind"]?.stringValue,
              ["user-message", "assistant", "reasoning", "activity", "interaction", "notice", "plan", "diff", "review", "context-compaction", "error"].contains(kind),
              value["createdAt"]?.numberValue != nil else { throw CodexPresentationError.invalidState }
        let reference = ["user-message": "messageId", "activity": "activityId", "interaction": "interactionId", "notice": "noticeId", "assistant": "itemId"]
        if let key = reference[kind], value[key]?.stringValue == nil { throw CodexPresentationError.invalidState }
        if ["assistant", "reasoning"].contains(kind), value["content"]?.stringValue == nil { throw CodexPresentationError.invalidState }
        raw = value
    }
    var id: JSONText { raw.codexIdentity("id") }
    var kind: String { raw["kind"]!.stringValue! }
    var content: String { raw["content"]?.stringValue ?? "" }
    var status: String? { raw["status"]?.stringValue }
    var createdAt: Double { raw["createdAt"]!.numberValue! }
}

struct CodexActivity: Sendable, Hashable, Identifiable {
    let raw: JSONValue
    init(_ value: JSONValue) throws {
        guard value["id"]?.stringValue != nil, value["label"]?.stringValue != nil,
              ["command", "file", "tool", "search", "agent", "subagent", "review", "hook"].contains(value["kind"]?.stringValue ?? ""),
              ["running", "completed", "failed", "cancelled"].contains(value["status"]?.stringValue ?? "") else { throw CodexPresentationError.invalidState }
        raw = value
    }
    var id: JSONText { raw.codexIdentity("id") }
    var kind: String { raw["kind"]!.stringValue! }
    var label: String { raw["label"]!.stringValue! }
    var status: String { raw["status"]!.stringValue! }
    var detail: String? { raw["detail"]?.stringValue }
    var toolCall: Bool { raw["toolCall"]?.boolValue == true }
}

struct CodexInteraction: Sendable, Hashable, Identifiable {
    let raw: JSONValue
    init(_ value: JSONValue) throws {
        guard value["id"]?.stringValue != nil, value["title"]?.stringValue != nil,
              value["blocksTurn"]?.boolValue != nil,
              ["pending", "allowed", "denied", "submitted", "cancelled", "resolved"].contains(value["status"]?.stringValue ?? ""),
              ["command-approval", "file-approval", "permissions", "user-input", "mcp-elicitation"].contains(value["kind"]?.stringValue ?? ""),
              value["actions"]?.arrayValue != nil, value["questions"]?.arrayValue != nil
        else { throw CodexPresentationError.invalidState }
        raw = value
    }
    var id: JSONText { raw.codexIdentity("id") }
    var title: String { raw["title"]!.stringValue! }
    var detail: String? { raw["detail"]?.stringValue }
    var kind: String { raw["kind"]!.stringValue! }
    var status: String { raw["status"]!.stringValue! }
    var blocksTurn: Bool { raw["blocksTurn"]!.boolValue! }
    var actions: [JSONValue] { raw["actions"]!.arrayValue! }
    var questions: [JSONValue] { raw["questions"]!.arrayValue! }
    var elicitation: JSONValue? { raw["elicitation"] }
}

enum CodexPresentationError: LocalizedError {
    case invalidState
    case expiredInteraction
    var errorDescription: String? {
        switch self {
        case .invalidState: "Codex sessionState 无效"
        case .expiredInteraction: "该 Codex 请求已失效。"
        }
    }
}

func codexObject(_ values: [String: JSONValue]) -> JSONValue {
    .object(Dictionary(uniqueKeysWithValues: values.map { (JSONText($0.key), $0.value) }))
}

extension JSONValue {
    func codexIdentity(_ key: String) -> JSONText {
        if case let .string(text)? = self[key] { return text }
        return JSONText("")
    }
}
