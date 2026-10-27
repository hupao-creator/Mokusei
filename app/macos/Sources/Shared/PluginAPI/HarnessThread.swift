import MokuseiCore

/// The public thread envelope. Private payloads are carried without interpretation.
public struct HarnessThread: Hashable, Sendable {
    public let json: JSONValue
    public let id: JSONText
    public let harnessID: JSONText
    public let revision: Int
    public let sessionState: JSONValue
    public let observation: ThreadPublicObservation
    public let cwd: JSONText
    /// Resolved by the runtime so every native view uses the same directory scope.
    public let directoryTag: JSONText
    public let directoryScope: JSONText
    public let worktree: JSONValue?
    public let settings: JSONValue
    public let settingsRevision: Int
    public let cancellationID: JSONText?
    public let pendingInput: Bool
    public let createdAt: Double
    public let updatedAt: Double
    public let title: JSONText
    public let metadataState: JSONValue?
    public let metadataRevision: Int?
    public let tags: [JSONText]
    public let tagEmojis: [JSONText: JSONText]
    public let archived: Bool?
    public let moku: Bool?
    public let note: ThreadNote?
    public let transcript: JSONValue?

    public init(json: JSONValue) throws {
        // Also rejects non-finite numbers or excessive depth in opaque payloads.
        try PluginJSONValidation.validate(json)
        let r = try ThreadContractReader(json, path: "thread")
        id = try r.text("id")
        harnessID = try r.text("harnessId")
        revision = try r.integer("revision")
        sessionState = try r.required("sessionState")
        observation = try ThreadPublicObservation(json: r.required("observation"))
        cwd = try r.text("cwd")
        directoryTag = try r.optionalText("directoryTag") ?? ""
        directoryScope = try r.optionalText("directoryScope") ?? ""
        worktree = r.values["worktree"]
        settings = try r.required("settings")
        settingsRevision = try r.optionalInteger("settingsRevision") ?? 0
        cancellationID = try r.optionalText("cancellationId")
        pendingInput = try r.optionalBool("pendingInput") ?? false
        createdAt = try r.number("createdAt", minimum: 0)
        updatedAt = try r.number("updatedAt", minimum: createdAt)
        title = try r.text("title")
        metadataState = r.values["metadataState"]
        metadataRevision = try r.optionalInteger("metadataRevision")
        tags = try r.texts("tags")
        tagEmojis = try SemanticTagLabel.decodeEmojis(r.required("tagEmojis"), names: tags)
        archived = try r.optionalBool("archived")
        moku = try r.optionalBool("moku")
        note = try r.values["note"].map { try ThreadNote(json: $0) }
        transcript = r.values["transcript"]
        // The note is Moku's own milestone recap; an ordinary thread must never
        // publish one, because only Moku may author it.
        if note != nil, moku != true {
            throw PluginContractError("thread.note requires a Moku thread")
        }
        if let moku {
            guard moku, archived == nil else {
                throw PluginContractError("thread.moku must be true and cannot carry archived")
            }
            guard case .array = transcript else {
                throw PluginContractError("thread.transcript must be an array for Moku")
            }
        }
        self.json = json
    }

    public init(id: JSONText, harnessID: JSONText, revision: Int, sessionState: JSONValue,
                observation: ThreadPublicObservation, cwd: JSONText, settings: JSONValue,
                createdAt: Double, updatedAt: Double, title: JSONText, tags: [JSONText],
                worktree: JSONValue? = nil, metadataState: JSONValue? = nil,
                metadataRevision: Int? = nil, archived: Bool? = nil,
                moku: Bool? = nil, note: ThreadNote? = nil,
                transcript: JSONValue? = nil, tagEmojis: [JSONText: JSONText] = [:],
                directoryTag: JSONText = "", directoryScope: JSONText = "") throws {
        var object: [JSONText: JSONValue] = [
            "id": .string(id), "harnessId": .string(harnessID), "revision": .integer(revision),
            "sessionState": sessionState, "observation": observation.json, "cwd": .string(cwd),
            "directoryTag": .string(directoryTag), "directoryScope": .string(directoryScope),
            "settings": settings, "createdAt": .number(createdAt), "updatedAt": .number(updatedAt),
            "title": .string(title), "tags": .array(tags.map(JSONValue.string))
        ]
        object["tagEmojis"] = .object(tagEmojis.mapValues(JSONValue.string))
        object["worktree"] = worktree
        object["metadataState"] = metadataState
        object["metadataRevision"] = metadataRevision.map { .integer($0) }
        object["archived"] = archived.map(JSONValue.bool)
        object["moku"] = moku.map(JSONValue.bool)
        object["note"] = note?.json
        object["transcript"] = transcript
        try self.init(json: .object(object))
    }

    // Every public field is derived from this immutable value. Avoid comparing
    // or hashing the private session twice through both json and sessionState.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }
    public func hash(into hasher: inout Hasher) { hasher.combine(json) }

    public func replacingSessionState(_ state: JSONValue) throws -> Self {
        guard case var .object(object) = json else {
            throw PluginContractError("thread must be an object")
        }
        object["sessionState"] = state
        return try Self(json: .object(object))
    }
}

/// Moku's single persistent milestone note. Revision is monotonic across clears
/// within one incarnation, and an empty text is the explicit "no note" value the
/// UI shows as empty.
public struct ThreadNote: Hashable, Sendable {
    public static let maximumCodePoints = 1200
    /// Names this note incarnation. It is stable across updates and host
    /// replacement; a history reset starts a new identity even though note
    /// revisions restart at 1, so read state cannot suppress a new note.
    public let id: JSONText
    public let text: JSONText
    public let revision: Int
    public let updatedAt: Double
    /// A CAS counter for evidence changes, independent of the text revision.
    public let readingRevision: Int
    public let lastExposure: ThreadNoteExposure?

    public init(id: JSONText, text: JSONText, revision: Int, updatedAt: Double,
                readingRevision: Int = 0, lastExposure: ThreadNoteExposure? = nil) throws {
        try self.init(json: .object(["id": .string(id), "text": .string(text), "revision": .integer(revision),
            "updatedAt": .number(updatedAt), "readingRevision": .integer(readingRevision),
            "lastExposure": lastExposure?.json ?? .null]))
    }

    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "note", keys: ["id", "text", "revision", "updatedAt", "readingRevision", "lastExposure"])
        id = try r.identifier("id")
        text = try r.rawText("text")
        guard text.string.unicodeScalars.count <= Self.maximumCodePoints, !text.codeUnits.contains(0) else {
            throw PluginContractError("note.text exceeds its code point limit or contains NUL")
        }
        if !text.codeUnits.isEmpty {
            try ThreadContractReader.nonblank(text, path: "note.text")
        }
        revision = try r.integer("revision")
        guard revision >= 1, revision <= 9_007_199_254_740_991 else { throw PluginContractError("note.revision is out of range") }
        updatedAt = try r.number("updatedAt", minimum: 0)
        readingRevision = try r.integer("readingRevision")
        guard readingRevision >= 0, readingRevision <= 9_007_199_254_740_991 else {
            throw PluginContractError("note.readingRevision is out of range")
        }
        if let value = json["lastExposure"], value != .null {
            let exposure = try ThreadNoteExposure(json: value)
            guard !text.codeUnits.isEmpty, exposure.revision <= revision, readingRevision > 0 else {
                throw PluginContractError("note.lastExposure is inconsistent")
            }
            lastExposure = exposure
        } else { lastExposure = nil }
        self.json = json
    }

    /// The empty text is a clear, not a note the UI should show.
    public var isEmpty: Bool { text.codeUnits.isEmpty }
    public let json: JSONValue
}

public struct ThreadNoteExposure: Hashable, Sendable {
    public let revision: Int
    public let text: JSONText
    public let recordedAt: Double
    public let signal: JSONText
    public let json: JSONValue

    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "note.lastExposure", keys: ["revision", "text", "recordedAt", "signal"])
        revision = try r.integer("revision")
        guard revision >= 1, revision <= 9_007_199_254_740_991 else { throw PluginContractError("note.lastExposure.revision is out of range") }
        text = try r.rawText("text")
        guard !text.codeUnits.isEmpty, text.string.unicodeScalars.count <= ThreadNote.maximumCodePoints,
              !text.codeUnits.contains(0) else { throw PluginContractError("note.lastExposure.text is invalid") }
        try ThreadContractReader.nonblank(text, path: "note.lastExposure.text")
        recordedAt = try r.number("recordedAt", minimum: 0)
        signal = try r.rawText("signal")
        guard signal == "complete-viewport-coverage-v1" else { throw PluginContractError("note.lastExposure.signal is invalid") }
        self.json = json
    }
}

public struct ThreadPublicObservation: Hashable, Sendable {
    public let latestExecution: PublicExecution?
    public let backgroundWork: PublicBackgroundWork?

    public init(latestExecution: PublicExecution? = nil, backgroundWork: PublicBackgroundWork? = nil) {
        self.latestExecution = latestExecution
        self.backgroundWork = backgroundWork
    }

    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "observation", keys: ["latestExecution", "backgroundWork"])
        let latest = try r.required("latestExecution")
        latestExecution = latest == .null ? nil : try PublicExecution(json: latest)
        let background = try r.required("backgroundWork")
        backgroundWork = background == .null ? nil : try PublicBackgroundWork(json: background)
    }

    public var isExecutionActive: Bool {
        latestExecution?.status == .running || latestExecution?.status == .waitingForUser
    }

    public var json: JSONValue {
        .object(["latestExecution": latestExecution?.json ?? .null, "backgroundWork": backgroundWork?.json ?? .null])
    }
}

public struct PublicBackgroundWork: Hashable, Sendable {
    public enum Status: String, CaseIterable, Hashable, Sendable { case running }
    public let status: Status
    public init(status: Status = .running) { self.status = status }
    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "backgroundWork", keys: ["status"])
        status = try r.enumeration("status", as: Status.self)
    }
    public var json: JSONValue { .object(["status": .text(status.rawValue)]) }
}

public struct PublicExecution: Hashable, Sendable {
    public enum Status: String, CaseIterable, Hashable, Sendable {
        case running, waitingForUser = "waiting-for-user", completed, interrupted, failed
    }
    public let executionID: JSONText
    public var id: JSONText { executionID }
    public let status: Status
    public let startedAt: Double
    public let finishedAt: Double?
    public let summary: JSONText?
    public let error: JSONText?
    public let interactions: [PublicInteraction]

    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "execution")
        executionID = try r.identifier("executionId")
        status = try r.enumeration("status", as: Status.self)
        startedAt = try r.number("startedAt", minimum: 0)
        summary = try r.optionalText("summary", maximum: 100_000)
        var keys: Set<JSONText> = ["executionId", "status", "startedAt", "summary"]
        switch status {
        case .running:
            finishedAt = nil; error = nil; interactions = []
        case .waitingForUser:
            keys.insert("interactions")
            interactions = try r.array("interactions").map { try PublicInteraction(json: $0) }
            guard !interactions.isEmpty else { throw PluginContractError("waiting-for-user interactions must not be empty") }
            try ThreadContractReader.unique(interactions.map(\.id), path: "execution.interactions")
            finishedAt = nil; error = nil
        case .completed, .interrupted, .failed:
            keys.insert("finishedAt")
            finishedAt = try r.number("finishedAt", minimum: startedAt)
            if status == .failed {
                keys.insert("error")
                error = try r.optionalText("error", maximum: 100_000)
            } else { error = nil }
            interactions = []
        }
        try r.only(keys)
    }

    public init(executionID: JSONText, status: Status, startedAt: Double,
                finishedAt: Double? = nil, summary: JSONText? = nil,
                error: JSONText? = nil, interactions: [PublicInteraction] = []) throws {
        var object: [JSONText: JSONValue] = ["executionId": .string(executionID),
            "status": .text(status.rawValue), "startedAt": .number(startedAt)]
        object["finishedAt"] = finishedAt.map(JSONValue.number)
        object["summary"] = summary.map(JSONValue.string)
        object["error"] = error.map(JSONValue.string)
        if status == .waitingForUser || !interactions.isEmpty {
            object["interactions"] = .array(interactions.map(\.json))
        }
        try self.init(json: .object(object))
    }

    public var json: JSONValue {
        var object: [JSONText: JSONValue] = ["executionId": .string(executionID),
            "status": .text(status.rawValue), "startedAt": .number(startedAt)]
        object["summary"] = summary.map(JSONValue.string)
        object["finishedAt"] = finishedAt.map(JSONValue.number)
        object["error"] = error.map(JSONValue.string)
        if status == .waitingForUser { object["interactions"] = .array(interactions.map(\.json)) }
        return .object(object)
    }
}

public struct PublicInteractionAction: Hashable, Sendable {
    public enum Intent: String, CaseIterable, Hashable, Sendable { case allow, deny, submit, cancel }
    public let id: JSONText
    public let intent: Intent
    public let label: JSONText
    public init(id: JSONText, intent: Intent, label: JSONText) {
        self.id = id; self.intent = intent; self.label = label
    }
    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "action", keys: ["id", "intent", "label"])
        id = try r.identifier("id")
        intent = try r.enumeration("intent", as: Intent.self)
        label = try r.text("label", maximum: 2_000, nonblank: true)
    }
    public var json: JSONValue { .object(["id": .string(id), "intent": .text(intent.rawValue), "label": .string(label)]) }
}

public struct PublicInteractionOption: Hashable, Sendable {
    public let value: JSONText
    public let label: JSONText
    public let description: JSONText?
    public init(value: JSONText, label: JSONText, description: JSONText? = nil) {
        self.value = value; self.label = label; self.description = description
    }
    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "option", keys: ["value", "label", "description"])
        value = try r.text("value", maximum: 2_000, nonblank: true)
        label = try r.text("label", maximum: 2_000, nonblank: true)
        description = try r.optionalText("description", maximum: 10_000)
    }
    public var json: JSONValue {
        var object: [JSONText: JSONValue] = ["value": .string(value), "label": .string(label)]
        object["description"] = description.map(JSONValue.string)
        return .object(object)
    }
}

public struct PublicQuestionForm: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case string, number, integer, boolean, multiselect, external
    }
    public enum Format: String, CaseIterable, Hashable, Sendable {
        case email, uri, date, dateTime = "date-time"
    }
    public struct Condition: Hashable, Sendable {
        public enum Operation: String, CaseIterable, Hashable, Sendable { case eq, neq }
        public let questionID: JSONText
        public let op: Operation
        public let value: JSONValue
        public init(questionID: JSONText, op: Operation, value: JSONValue) throws {
            try self.init(json: .object(["questionId": .string(questionID), "op": .text(op.rawValue), "value": value]))
        }
        public init(json: JSONValue) throws {
            let r = try ThreadContractReader(json, path: "condition", keys: ["questionId", "op", "value"])
            questionID = try r.identifier("questionId")
            op = try r.enumeration("op", as: Operation.self)
            value = try r.required("value")
            try ThreadContractReader.formValue(value, array: false, path: "condition.value")
        }
        public var json: JSONValue { .object(["questionId": .string(questionID), "op": .text(op.rawValue), "value": value]) }
    }

    public let json: JSONValue
    public let type: Kind
    public let required: Bool
    public let hidden: Bool?
    public let defaultValue: JSONValue?
    public let when: [Condition]?
    public let optionValues: [JSONText: JSONText]?
    public let optionIDPrefix: JSONText?
    public let minimum: Double?
    public let maximum: Double?
    public let minLength: Int?
    public let maxLength: Int?
    public let pattern: JSONText?
    public let format: Format?
    public let minItems: Int?
    public let maxItems: Int?

    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "form", keys: ["type", "required", "hidden", "default", "when",
            "optionValues", "optionIdPrefix", "minimum", "maximum", "minLength", "maxLength", "pattern", "format", "minItems", "maxItems"])
        type = try r.enumeration("type", as: Kind.self)
        required = try r.bool("required")
        hidden = try r.optionalBool("hidden")
        defaultValue = r.values["default"]
        if let defaultValue { try ThreadContractReader.formValue(defaultValue, array: true, path: "form.default") }
        when = try r.optionalArray("when")?.map { try Condition(json: $0) }
        if let value = r.values["optionValues"] {
            let options = try ThreadContractReader(value, path: "form.optionValues")
            optionValues = try options.values.mapValues { try ThreadContractReader.rawText($0, path: "form.optionValues") }
        } else { optionValues = nil }
        optionIDPrefix = try r.optionalText("optionIdPrefix", maximum: 128, nonblank: true)
        minimum = try r.optionalNumber("minimum")
        maximum = try r.optionalNumber("maximum")
        minLength = try r.optionalInteger("minLength")
        maxLength = try r.optionalInteger("maxLength")
        pattern = try r.optionalRawText("pattern")
        format = try r.optionalEnumeration("format", as: Format.self)
        minItems = try r.optionalInteger("minItems")
        maxItems = try r.optionalInteger("maxItems")
        self.json = json
    }

    public init(type: Kind, required: Bool, hidden: Bool? = nil, defaultValue: JSONValue? = nil,
                when: [Condition]? = nil, optionValues: [JSONText: JSONText]? = nil,
                optionIDPrefix: JSONText? = nil, minimum: Double? = nil, maximum: Double? = nil,
                minLength: Int? = nil, maxLength: Int? = nil, pattern: JSONText? = nil,
                format: Format? = nil, minItems: Int? = nil, maxItems: Int? = nil) throws {
        var object: [JSONText: JSONValue] = ["type": .text(type.rawValue), "required": .bool(required)]
        object["hidden"] = hidden.map(JSONValue.bool)
        object["default"] = defaultValue
        object["when"] = when.map { .array($0.map(\.json)) }
        object["optionValues"] = optionValues.map { .object($0.mapValues(JSONValue.string)) }
        object["optionIdPrefix"] = optionIDPrefix.map(JSONValue.string)
        object["minimum"] = minimum.map(JSONValue.number)
        object["maximum"] = maximum.map(JSONValue.number)
        object["minLength"] = minLength.map { .integer($0) }
        object["maxLength"] = maxLength.map { .integer($0) }
        object["pattern"] = pattern.map(JSONValue.string)
        object["format"] = format.map { .text($0.rawValue) }
        object["minItems"] = minItems.map { .integer($0) }
        object["maxItems"] = maxItems.map { .integer($0) }
        try self.init(json: .object(object))
    }
}

public struct PublicInteractionQuestion: Hashable, Sendable {
    public enum AnswerFormat: String, CaseIterable, Hashable, Sendable { case jsonObject = "json-object" }
    public let id: JSONText
    public let prompt: JSONText
    public let header: JSONText?
    public let multiple: Bool
    public let allowOther: Bool
    public let secret: Bool
    public let answerFormat: AnswerFormat?
    public let form: PublicQuestionForm?
    public let options: [PublicInteractionOption]

    public init(id: JSONText, prompt: JSONText, header: JSONText? = nil,
                multiple: Bool, allowOther: Bool, secret: Bool,
                answerFormat: AnswerFormat? = nil, form: PublicQuestionForm? = nil,
                options: [PublicInteractionOption]) {
        self.id = id; self.prompt = prompt; self.header = header
        self.multiple = multiple; self.allowOther = allowOther; self.secret = secret
        self.answerFormat = answerFormat; self.form = form; self.options = options
    }

    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "question", keys: ["id", "prompt", "header", "multiple", "allowOther", "secret", "answerFormat", "form", "options"])
        id = try r.identifier("id")
        prompt = try r.text("prompt", maximum: 20_000, nonblank: true)
        header = try r.optionalText("header", maximum: 2_000)
        multiple = try r.bool("multiple")
        allowOther = try r.bool("allowOther")
        secret = try r.bool("secret")
        answerFormat = try r.optionalEnumeration("answerFormat", as: AnswerFormat.self)
        form = try r.values["form"].map { try PublicQuestionForm(json: $0) }
        options = try r.array("options").map { try PublicInteractionOption(json: $0) }
        try ThreadContractReader.unique(options.map(\.value), path: "question.options")
    }

    public var json: JSONValue {
        var object: [JSONText: JSONValue] = ["id": .string(id), "prompt": .string(prompt),
            "multiple": .bool(multiple), "allowOther": .bool(allowOther), "secret": .bool(secret),
            "options": .array(options.map(\.json))]
        object["header"] = header.map(JSONValue.string)
        object["answerFormat"] = answerFormat.map { .text($0.rawValue) }
        object["form"] = form?.json
        return .object(object)
    }
}

public struct PublicInteraction: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable { case permission, question }
    public let id: JSONText
    public let kind: Kind
    public let title: JSONText
    public let description: JSONText?
    public let actions: [PublicInteractionAction]
    public let questions: [PublicInteractionQuestion]

    public init(id: JSONText, kind: Kind, title: JSONText, description: JSONText? = nil,
                actions: [PublicInteractionAction], questions: [PublicInteractionQuestion]) {
        self.id = id; self.kind = kind; self.title = title; self.description = description
        self.actions = actions; self.questions = questions
    }

    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "interaction", keys: ["id", "kind", "title", "description", "actions", "questions"])
        id = try r.identifier("id")
        kind = try r.enumeration("kind", as: Kind.self)
        title = try r.text("title", maximum: 2_000, nonblank: true)
        description = try r.optionalText("description", maximum: 20_000)
        actions = try r.array("actions").map { try PublicInteractionAction(json: $0) }
        guard !actions.isEmpty else { throw PluginContractError("interaction.actions must not be empty") }
        try ThreadContractReader.unique(actions.map(\.id), path: "interaction.actions")
        questions = try r.array("questions").map { try PublicInteractionQuestion(json: $0) }
        try ThreadContractReader.unique(questions.map(\.id), path: "interaction.questions")
    }

    public var json: JSONValue {
        var object: [JSONText: JSONValue] = ["id": .string(id), "kind": .text(kind.rawValue),
            "title": .string(title), "actions": .array(actions.map(\.json)), "questions": .array(questions.map(\.json))]
        object["description"] = description.map(JSONValue.string)
        return .object(object)
    }
}

public enum HarnessResponseAnswer: Hashable, Sendable {
    case text(JSONText)
    case multiple([JSONText])
    public init(json: JSONValue) throws {
        switch json {
        case let .string(text): self = .text(text)
        case let .array(values): self = .multiple(try values.map { try ThreadContractReader.rawText($0, path: "answer") })
        default: throw PluginContractError("answer must be a string or array of strings")
        }
    }
    public var json: JSONValue {
        switch self {
        case let .text(text): .string(text)
        case let .multiple(values): .array(values.map(JSONValue.string))
        }
    }
}

public struct HarnessRespondRequest: Hashable, Sendable {
    public typealias Answer = HarnessResponseAnswer
    public let interactionID: JSONText
    public let actionID: JSONText
    public let answers: [JSONText: HarnessResponseAnswer]?
    public let message: JSONText?
    public init(interactionID: JSONText, actionID: JSONText,
                answers: [JSONText: HarnessResponseAnswer]? = nil, message: JSONText? = nil) {
        self.interactionID = interactionID; self.actionID = actionID
        self.answers = answers; self.message = message
    }
    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "response", keys: ["interactionId", "actionId", "answers", "message"])
        interactionID = try r.rawText("interactionId")
        actionID = try r.rawText("actionId")
        try ThreadContractReader.nonblank(interactionID, path: "response.interactionId")
        try ThreadContractReader.nonblank(actionID, path: "response.actionId")
        if let value = r.values["answers"] {
            let a = try ThreadContractReader(value, path: "response.answers")
            for key in a.values.keys { try ThreadContractReader.nonblank(key, path: "response.answers key") }
            answers = try a.values.mapValues { try HarnessResponseAnswer(json: $0) }
        } else { answers = nil }
        let text = try r.optionalText("message", maximum: 10_000)
        message = text?.codeUnits.isEmpty == true ? nil : text
    }
    public var json: JSONValue {
        var object: [JSONText: JSONValue] = ["interactionId": .string(interactionID), "actionId": .string(actionID)]
        object["answers"] = answers.map { .object($0.mapValues(\.json)) }
        object["message"] = message.map(JSONValue.string)
        return .object(object)
    }
}

public struct HarnessReadingTarget: Hashable, Sendable {
    public enum Mode: String, CaseIterable, Hashable, Sendable { case current, history }
    public let executionID: JSONText
    public let requestID: JSONText
    public let mode: Mode
    public let message: JSONValue?
    public init(executionID: JSONText, requestID: JSONText, mode: Mode, message: JSONValue? = nil) {
        self.executionID = executionID; self.requestID = requestID; self.mode = mode; self.message = message
    }
    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "readingTarget", keys: ["executionId", "requestId", "mode", "message"])
        executionID = try r.rawText("executionId")
        requestID = try r.rawText("requestId")
        mode = try r.enumeration("mode", as: Mode.self)
        message = r.values["message"]
        if let message { try PluginJSONValidation.validate(message) }
    }
    public var json: JSONValue {
        var object: [JSONText: JSONValue] = ["executionId": .string(executionID), "requestId": .string(requestID), "mode": .text(mode.rawValue)]
        object["message"] = message
        return .object(object)
    }
}

public struct ThreadConversationIndex: Hashable, Sendable {
    public let executionIDs: [JSONText]
    public let hasInheritedHistory: Bool
    public init(executionIDs: [JSONText], hasInheritedHistory: Bool) {
        self.executionIDs = executionIDs; self.hasInheritedHistory = hasInheritedHistory
    }
    public init(json: JSONValue) throws {
        let r = try ThreadContractReader(json, path: "conversationIndex", keys: ["executionIds", "hasInheritedHistory"])
        executionIDs = try r.texts("executionIds")
        hasInheritedHistory = try r.bool("hasInheritedHistory")
    }
    public var json: JSONValue {
        .object(["executionIds": .array(executionIDs.map(JSONValue.string)), "hasInheritedHistory": .bool(hasInheritedHistory)])
    }
}

private struct ThreadContractReader {
    let values: [JSONText: JSONValue]
    let path: String
    init(_ json: JSONValue, path: String, keys: Set<JSONText>? = nil) throws {
        guard case let .object(values) = json else { throw PluginContractError("\(path) must be an object") }
        self.values = values; self.path = path
        if let keys { try only(keys) }
    }
    func only(_ keys: Set<JSONText>) throws {
        guard values.keys.allSatisfy(keys.contains) else { throw PluginContractError("\(path) contains unknown fields") }
    }
    func required(_ key: JSONText) throws -> JSONValue {
        guard let value = values[key] else { throw PluginContractError("\(path).\(key.string) is required") }
        return value
    }
    static func rawText(_ json: JSONValue, path: String) throws -> JSONText {
        guard case let .string(value) = json else { throw PluginContractError("\(path) must be a string") }
        return value
    }
    func rawText(_ key: JSONText) throws -> JSONText { try Self.rawText(required(key), path: "\(path).\(key.string)") }
    func optionalRawText(_ key: JSONText) throws -> JSONText? { try values[key].map { try Self.rawText($0, path: "\(path).\(key.string)") } }
    func text(_ key: JSONText, maximum: Int = Int.max, nonblank: Bool = false) throws -> JSONText {
        let value = try rawText(key)
        guard value.codeUnits.count <= maximum, !value.codeUnits.contains(0) else {
            throw PluginContractError("\(path).\(key.string) exceeds its text limit or contains NUL")
        }
        if nonblank { try Self.nonblank(value, path: "\(path).\(key.string)") }
        return value
    }
    func optionalText(_ key: JSONText, maximum: Int = Int.max, nonblank: Bool = false) throws -> JSONText? {
        guard values[key] != nil else { return nil }
        return try text(key, maximum: maximum, nonblank: nonblank)
    }
    static func nonblank(_ value: JSONText, path: String) throws {
        guard value.codeUnits.contains(where: { !isWhitespace($0) }) else { throw PluginContractError("\(path) must not be blank") }
    }
    // ECMAScript WhiteSpace and LineTerminator code units, matching String.trim().
    static func isWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }
    func identifier(_ key: JSONText) throws -> JSONText {
        let value = try rawText(key)
        func alphanumeric(_ unit: UInt16) -> Bool { (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) }
        guard let first = value.codeUnits.first, alphanumeric(first), value.codeUnits.count <= 128,
              value.codeUnits.allSatisfy({ alphanumeric($0) || [46, 95, 58, 45].contains($0) }) else {
            throw PluginContractError("\(path).\(key.string) is not a public identifier")
        }
        return value
    }
    func bool(_ key: JSONText) throws -> Bool {
        guard case let .bool(value) = try required(key) else { throw PluginContractError("\(path).\(key.string) must be a boolean") }
        return value
    }
    func optionalBool(_ key: JSONText) throws -> Bool? { values[key] == nil ? nil : try bool(key) }
    func number(_ key: JSONText, minimum: Double? = nil) throws -> Double {
        guard let value = try required(key).numberValue, value.isFinite,
              minimum.map({ value >= $0 }) ?? true else { throw PluginContractError("\(path).\(key.string) must be a finite number in range") }
        return value
    }
    func optionalNumber(_ key: JSONText) throws -> Double? { values[key] == nil ? nil : try number(key) }
    func integer(_ key: JSONText) throws -> Int {
        let value = try number(key, minimum: 0)
        guard value <= 9_007_199_254_740_991, let integer = Int(exactly: value) else {
            throw PluginContractError("\(path).\(key.string) must be a nonnegative safe integer")
        }
        return integer
    }
    func optionalInteger(_ key: JSONText) throws -> Int? { values[key] == nil ? nil : try integer(key) }
    func array(_ key: JSONText) throws -> [JSONValue] {
        guard case let .array(value) = try required(key) else { throw PluginContractError("\(path).\(key.string) must be an array") }
        return value
    }
    func optionalArray(_ key: JSONText) throws -> [JSONValue]? { values[key] == nil ? nil : try array(key) }
    func texts(_ key: JSONText) throws -> [JSONText] {
        try array(key).map { try Self.rawText($0, path: "\(path).\(key.string)") }
    }
    func enumeration<T: RawRepresentable & CaseIterable>(_ key: JSONText, as: T.Type) throws -> T where T.RawValue == String {
        let value = try rawText(key)
        guard let result = T.allCases.first(where: { JSONText($0.rawValue) == value }) else {
            throw PluginContractError("\(path).\(key.string) has an unknown value")
        }
        return result
    }
    func optionalEnumeration<T: RawRepresentable & CaseIterable>(_ key: JSONText, as: T.Type) throws -> T? where T.RawValue == String {
        values[key] == nil ? nil : try enumeration(key, as: T.self)
    }
    static func unique<T: Hashable>(_ values: [T], path: String) throws {
        guard Set(values).count == values.count else { throw PluginContractError("\(path) contains duplicate identities") }
    }
    static func formValue(_ value: JSONValue, array: Bool, path: String) throws {
        switch value {
        case .string, .bool, .integer: return
        case let .number(number) where number.isFinite: return
        case let .array(values) where array:
            for value in values { _ = try rawText(value, path: path) }
        default: throw PluginContractError("\(path) must be a string, finite number, boolean\(array ? " or string array" : "")")
        }
    }
}
