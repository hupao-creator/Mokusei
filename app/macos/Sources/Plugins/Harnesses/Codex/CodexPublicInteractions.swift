import CryptoKit
import Foundation
import MokuseiCore

/// Match native requests to public response authority by domain-separated
/// identity and complete semantics. A partial match never enables a button.
func codexPublicInteractionsByNativeId(state: JSONValue, observation: JSONValue) -> [JSONText: JSONValue] {
    guard let execution = observation["latestExecution"], execution["status"]?.stringValue == "waiting-for-user",
          let turn = state["turns"]?.arrayValue?.last(where: { $0["executionId"] == execution["executionId"] }) else { return [:] }
    let native = (turn["interactions"]?.arrayValue ?? []).filter { $0["status"]?.stringValue == "pending" && $0["blocksTurn"]?.boolValue == true }
    let observed = execution["interactions"]?.arrayValue ?? []
    guard native.count == observed.count else { return [:] }
    var observedByID: [JSONText: JSONValue] = [:]
    for interaction in observed {
        let id = interaction.codexIdentity("id")
        guard observedByID[id] == nil else { return [:] }
        observedByID[id] = interaction
    }
    var result: [JSONText: JSONValue] = [:]
    var nativeIDs = Set<JSONText>()
    for interaction in native {
        let id = interaction.codexIdentity("id")
        guard nativeIDs.insert(id).inserted else { return [:] }
        let expected = codexToPublicInteraction(interaction)
        guard let actual = observedByID.removeValue(forKey: expected.codexIdentity("id")),
              codexSamePublicInteraction(expected, actual, native: interaction) else { return [:] }
        result[id] = actual
    }
    return observedByID.isEmpty ? result : [:]
}

func codexPublicInteractionID(_ native: JSONText) -> JSONText {
    codexOpaqueID("interaction", parts: [native])
}

private func codexOpaqueID(_ kind: String, parts: [JSONText]) -> JSONText {
    var digest = SHA256()
    digest.update(data: Data("mokusei.codex.public-interaction.v1".utf8))
    for part in [JSONText(kind)] + parts {
        // TextEncoder replaces an isolated UTF-16 surrogate with U+FFFD.
        let bytes = Data(part.string.utf8)
        digest.update(data: Data("\(bytes.count):".utf8)); digest.update(data: bytes)
    }
    let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
    return JSONText("codex-\(kind)-sha256-\(hex)")
}

func codexIsMCPConfirmationSchema(_ schema: JSONValue?) -> Bool {
    guard let schema, schema["type"]?.stringValue == "object",
          let properties = schema["properties"]?.objectValue, properties.isEmpty,
          let object = schema.objectValue else { return false }
    return object.allSatisfy { key, value in
        switch key.string {
        case "type", "properties": true
        case "required": value.arrayValue?.isEmpty == true
        case "additionalProperties": value == .bool(false)
        case "$schema", "$id", "$comment", "title", "description": value.stringValue != nil
        default: false
        }
    }
}

func codexToPublicInteraction(_ native: JSONValue) -> JSONValue {
    let id = native.codexIdentity("id")
    let elicitation = native["kind"]?.stringValue == "mcp-elicitation" ? native["elicitation"] : nil
    let form = elicitation?["mode"]?.stringValue == "form"
    let confirmation = form && codexIsMCPConfirmationSchema(elicitation?["requestedSchema"])
    let kind = native["kind"]?.stringValue == "user-input" || (form && !confirmation) ? "question" : "permission"
    let schema = form && !confirmation ? native["mcpSchemaDisplay"] ?? .text(codexPrettyJSON(elicitation?["requestedSchema"] ?? .null)) : nil
    var fields: [String: JSONValue] = [
        "id": .string(codexPublicInteractionID(id)), "kind": .text(kind),
        "title": codexDisplayText(native["title"], limit: 2_000, fallback: kind == "question" ? "Codex 需要补充信息" : "Codex 请求确认")
    ]
    let description = elicitation?["mode"]?.stringValue == "url" ? elicitation?["url"] : schema ?? native["detail"]
    if let description, !codexTrim(description).codeUnits.isEmpty { fields["description"] = codexDisplayText(description, limit: 20_000) }
    fields["actions"] = .array((native["actions"]?.arrayValue ?? []).map { action in
        let isConfirm = confirmation && action["id"]?.stringValue == "submit"
        let intent = isConfirm ? "allow" : action["intent"]?.stringValue ?? "cancel"
        return codexObject(["id": action["id"] ?? .null, "intent": .text(intent),
                            "label": isConfirm ? .text("允许") : codexDisplayText(action["label"], limit: 2_000, fallback: ["allow": "允许", "deny": "拒绝", "submit": "提交", "cancel": "取消"][intent] ?? "")])
    })
    fields["questions"] = .array(confirmation ? [] : (native["questions"]?.arrayValue ?? []).map { question in
        let questionID = question.codexIdentity("id")
        let isFormQuestion = form && question["id"] == elicitation?["questionId"]
        var value: [String: JSONValue] = [
            "id": .string(codexOpaqueID("question", parts: [id, questionID])),
            "prompt": codexDisplayText(isFormQuestion ? codexSchemaQuestionPrompt(schema) : question["prompt"], limit: 20_000, fallback: "Codex question"),
            "multiple": .bool(false), "allowOther": question["allowOther"] ?? .bool(false), "secret": question["secret"] ?? .bool(false)
        ]
        if let header = question["header"], !codexTrim(header).codeUnits.isEmpty { value["header"] = codexDisplayText(header, limit: 2_000) }
        if isFormQuestion { value["answerFormat"] = .text("json-object") }
        value["options"] = .array((question["options"]?.arrayValue ?? []).enumerated().map { index, option in
            var values: [String: JSONValue] = [
                "value": .string(codexOpaqueID("option", parts: [id, questionID, option.codexIdentity("id")])),
                "label": codexDisplayText(option["label"], limit: 2_000, fallback: "选项 \(index + 1)")
            ]
            if let description = option["description"], !codexTrim(description).codeUnits.isEmpty { values["description"] = codexDisplayText(description, limit: 10_000) }
            return codexObject(values)
        })
        return codexObject(value)
    })
    return codexObject(fields)
}

private func codexDisplayText(_ value: JSONValue?, limit: Int, fallback: String = "") -> JSONValue {
    guard case var .string(text) = value else { return .text(fallback) }
    text = JSONText(codeUnits: text.codeUnits.map { $0 == 0 ? 0xFFFD : $0 })
    let clipped = JSONText(codeUnits: Array(codexTrim(.string(text)).codeUnits.prefix(limit)))
    return clipped.codeUnits.isEmpty ? .text(fallback) : .string(clipped)
}

/// JSONValue intentionally discards object insertion order. Pretty display is
/// deterministic; the binding comparator independently verifies the runtime's
/// JavaScript pretty formatting against the native schema and its UTF-16 limit.
func codexPrettyJSON(_ value: JSONValue) -> String {
    codexPrettyJSONString(value)
}

private func codexSamePublicInteraction(_ expected: JSONValue, _ actual: JSONValue, native: JSONValue) -> Bool {
    for field in ["id", "kind", "title"] where expected[field] != actual[field] { return false }
    let nativeSchema = native["elicitation"]?["requestedSchema"]
    let schema = native["elicitation"]?["mode"]?.stringValue == "form" && !codexIsMCPConfirmationSchema(nativeSchema) ? nativeSchema : nil
    let projectedDisplay = native["mcpSchemaDisplay"]
    if let projectedDisplay {
        guard native["kind"]?.stringValue == "mcp-elicitation", native["elicitation"]?["mode"]?.stringValue == "form",
              let nativeSchema, codexJSONSchemaDisplayMatches(projectedDisplay, schema: nativeSchema, limit: Int.max) else { return false }
    }
    if schema != nil, let projectedDisplay {
        guard actual["description"] == codexDisplayText(projectedDisplay, limit: 20_000) else { return false }
    } else if let schema {
        guard codexJSONSchemaDisplayMatches(actual["description"], schema: schema) else { return false }
    } else if expected["description"] != actual["description"] { return false }
    guard let actions = expected["actions"]?.arrayValue, let otherActions = actual["actions"]?.arrayValue,
          actions.count == otherActions.count else { return false }
    for (lhs, rhs) in zip(actions, otherActions) {
        for field in ["id", "intent", "label"] where lhs[field] != rhs[field] { return false }
    }
    guard let questions = expected["questions"]?.arrayValue, let otherQuestions = actual["questions"]?.arrayValue,
          questions.count == otherQuestions.count else { return false }
    for (lhs, rhs) in zip(questions, otherQuestions) {
        for field in ["id", "header", "multiple", "allowOther", "secret", "answerFormat", "form"] where lhs[field] != rhs[field] { return false }
        if lhs["answerFormat"]?.stringValue == "json-object", let schema {
            let prefix = "JSON form values matching this schema:\n"
            if let projectedDisplay {
                guard rhs["prompt"] == codexDisplayText(codexSchemaQuestionPrompt(projectedDisplay), limit: 20_000, fallback: "Codex question") else { return false }
            } else if !codexJSONSchemaDisplayMatches(rhs["prompt"], schema: schema, prefix: prefix) { return false }
        } else if lhs["prompt"] != rhs["prompt"] { return false }
        guard let options = lhs["options"]?.arrayValue, let otherOptions = rhs["options"]?.arrayValue,
              options.count == otherOptions.count else { return false }
        for (option, other) in zip(options, otherOptions) {
            for field in ["value", "label", "description"] where option[field] != other[field] { return false }
        }
    }
    return true
}

private func codexSchemaQuestionPrompt(_ schema: JSONValue?) -> JSONValue {
    let prefix = Array("JSON form values matching this schema:\n".utf16)
    if case let .string(text) = schema { return .string(JSONText(codeUnits: prefix + text.codeUnits)) }
    return .string(JSONText(codeUnits: prefix))
}
