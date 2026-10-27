import Foundation
import MokuseiCore

/// A plugin-projected field, not a transport schema. The owning plugin decides
/// which questions are active, their semantic constraints, and their wire values.
///
/// Harness cards use the single-line editor and trim ordinary custom answers.
/// Typed forms can project `.multiline`/`.jsonObject`/`.number`/`.integer`, set
/// `trimsCustomAnswer: false`, and export with `includingEmpty: true` to preserve
/// explicit clearing of source-owned defaults. Pass translated help and default
/// descriptions through `hints`, redacting secret default values in the plugin.
/// Conditional visibility, validation, and source-specific submission stay with
/// that owner. Numeric bounds affect keyboard stepping only, not validation.
public struct InteractionQuestionSpec: Identifiable, Hashable, Sendable {
    public let id: JSONText
    public var prompt: String
    public var header: String?
    public var multiple: Bool
    public var allowOther: Bool
    public var secret: Bool
    public var options: [InteractionQuestionOption]
    public var required: Bool
    public var hasDefault: Bool
    public var editor: InteractionQuestionEditor
    public var hints: [String]
    public var trimsCustomAnswer: Bool
    public var minimum: Double?
    public var maximum: Double?

    public init(id: JSONText, prompt: String, header: String? = nil,
                multiple: Bool = false, allowOther: Bool = false, secret: Bool = false,
                options: [InteractionQuestionOption] = [], required: Bool = true,
                hasDefault: Bool = false, editor: InteractionQuestionEditor = .singleLine,
                hints: [String] = [], trimsCustomAnswer: Bool = true,
                minimum: Double? = nil, maximum: Double? = nil) {
        self.id = id; self.prompt = prompt; self.header = header
        self.multiple = multiple; self.allowOther = allowOther; self.secret = secret
        self.options = options; self.required = required; self.hasDefault = hasDefault
        self.editor = editor; self.hints = hints; self.trimsCustomAnswer = trimsCustomAnswer
        self.minimum = minimum; self.maximum = maximum
    }

    public var isTextOnly: Bool { options.isEmpty }
}

public struct InteractionQuestionOption: Identifiable, Hashable, Sendable {
    public let id: JSONText
    public let value: JSONText
    public var label: String
    public var description: String?

    public init(id: JSONText? = nil, value: JSONText, label: String, description: String? = nil) {
        self.id = id ?? value; self.value = value; self.label = label; self.description = description
    }
}

public enum InteractionQuestionEditor: Hashable, Sendable {
    case singleLine, multiline, number, integer, jsonObject
}

public enum InteractionAnswer: Hashable, Sendable {
    case single(JSONText)
    case multiple([JSONText])

    public var values: [JSONText] {
        switch self { case .single(let value): [value]; case .multiple(let values): values }
    }

    public var json: JSONValue {
        switch self {
        case .single(let value): .string(value)
        case .multiple(let values): .array(values.map(JSONValue.string))
        }
    }
}

/// UI-owned value state. Keep this in the interaction's owner with `@State`, then
/// pass a binding to fields. Custom text remains separate from option selection,
/// even when the text happens to equal an option value during editing.
///
/// IDs and wire values use JSONText; only labels and editor display use String.
/// Use `clear` to restore absence and let source defaults apply again. Restore
/// from authoritative reloads, not each keystroke: the wire representation cannot
/// distinguish custom text from an identically valued option.
public struct InteractionAnswers: Hashable, Sendable {
    private struct Draft: Hashable, Sendable {
        var picked: [JSONText] = []
        // nil means closed; an empty value means open but not answered.
        var custom: JSONText?
        // A restored multi-answer may contain several custom values. Display
        // them together, but preserve each wire value until the user edits text.
        var restoredCustom: [JSONText]?
        var restoredAnswer: InteractionAnswer?
    }
    private var drafts: [JSONText: Draft] = [:]

    public init() {}

    public init(questions: [InteractionQuestionSpec], values: [JSONText: InteractionAnswer]) {
        for question in questions {
            if let answer = values[question.id] { replaceAnswer(for: question, with: answer) }
        }
    }

    public func picked(_ question: InteractionQuestionSpec) -> [JSONText] {
        drafts[question.id]?.picked ?? []
    }

    public func otherOpen(_ question: InteractionQuestionSpec) -> Bool {
        question.isTextOnly || drafts[question.id]?.custom != nil
    }

    public func otherText(_ question: InteractionQuestionSpec) -> String {
        drafts[question.id]?.custom?.string ?? ""
    }

    public func hasEdited(_ question: InteractionQuestionSpec) -> Bool { drafts[question.id] != nil }

    public func answered(_ question: InteractionQuestionSpec) -> Bool {
        !answerValues(question).isEmpty
    }

    /// Only basic completion belongs here. Plugins provide schema/default and
    /// conditional-field validation separately to the form's errors/canSubmit.
    public func isComplete(for questions: [InteractionQuestionSpec]) -> Bool {
        questions.allSatisfy { question in
            !question.required || answered(question) || (question.hasDefault && !hasEdited(question))
        }
    }

    public mutating func toggle(_ question: InteractionQuestionSpec, value: JSONText) {
        guard question.options.contains(where: { $0.value == value }) else { return }
        var draft = drafts[question.id] ?? Draft()
        draft.restoredAnswer = nil
        if question.multiple {
            if draft.picked.contains(value) { draft.picked.removeAll { $0 == value } }
            else { draft.picked.append(value) }
        } else {
            draft.picked = [value]
            draft.custom = nil
            draft.restoredCustom = nil
        }
        drafts[question.id] = draft
    }

    public mutating func toggleOther(_ question: InteractionQuestionSpec) {
        guard !question.isTextOnly, question.allowOther else { return }
        var draft = drafts[question.id] ?? Draft()
        draft.restoredAnswer = nil
        if draft.custom == nil {
            draft.custom = ""
            if !question.multiple { draft.picked = [] }
        } else {
            draft.custom = nil
            draft.restoredCustom = nil
        }
        drafts[question.id] = draft
    }

    public mutating func closeOther(_ question: InteractionQuestionSpec) {
        guard !question.isTextOnly, var draft = drafts[question.id] else { return }
        draft.custom = nil
        draft.restoredCustom = nil
        draft.restoredAnswer = nil
        drafts[question.id] = draft
    }

    public mutating func writeOther(_ question: InteractionQuestionSpec, text: String) {
        guard question.isTextOnly || question.allowOther else { return }
        var draft = drafts[question.id] ?? Draft()
        draft.custom = JSONText(text)
        draft.restoredCustom = nil
        draft.restoredAnswer = nil
        if !question.multiple { draft.picked = [] }
        drafts[question.id] = draft
    }

    /// Restores absence, allowing source-owned defaults to apply again.
    public mutating func clear(_ question: InteractionQuestionSpec) { drafts[question.id] = nil }

    public mutating func removeAll() { drafts.removeAll() }

    /// Use for an authoritative reset/reload, not on each local edit: the wire
    /// representation cannot distinguish custom text identical to an option.
    public mutating func replaceAnswer(for question: InteractionQuestionSpec, with answer: InteractionAnswer?) {
        guard let answer else { clear(question); return }
        let values = answer.values
        let options = Set(question.options.map(\.value))
        let picked = values.filter { options.contains($0) }
        let custom = values.filter { !options.contains($0) }
        var customUnits: [UInt16] = []
        for (index, value) in custom.enumerated() {
            if index > 0 { customUnits.append(0x0A) }
            customUnits.append(contentsOf: value.codeUnits)
        }
        drafts[question.id] = Draft(picked: picked,
            custom: question.isTextOnly || !custom.isEmpty ? JSONText(codeUnits: customUnits) : nil,
            restoredCustom: custom.isEmpty ? nil : custom, restoredAnswer: answer)
    }

    /// By default empty drafts are omitted, as in Harness question cards. Typed
    /// forms can include explicit empty drafts to clear a source-owned default.
    public func answersFor(_ questions: [InteractionQuestionSpec], includingEmpty: Bool = false)
        -> [JSONText: InteractionAnswer] {
        var result: [JSONText: InteractionAnswer] = [:]
        for question in questions {
            if includingEmpty, let restored = drafts[question.id]?.restoredAnswer {
                result[question.id] = restored
                continue
            }
            let values = answerValues(question)
            guard !values.isEmpty || (includingEmpty && hasEdited(question)) else { continue }
            result[question.id] = question.multiple ? .multiple(values) : .single(values.first ?? "")
        }
        return result
    }

    public func json(for questions: [InteractionQuestionSpec], includingEmpty: Bool = false) -> JSONValue {
        .object(answersFor(questions, includingEmpty: includingEmpty).mapValues(\.json))
    }

    func customIsEmpty(_ question: InteractionQuestionSpec) -> Bool {
        normalizedCustom(question)?.codeUnits.isEmpty ?? true
    }

    private func answerValues(_ question: InteractionQuestionSpec) -> [JSONText] {
        let picked = picked(question)
        let custom = (drafts[question.id]?.restoredCustom ?? drafts[question.id]?.custom.map { [$0] } ?? [])
            .map { normalize($0, for: question) }.filter { !$0.codeUnits.isEmpty }
        return question.multiple ? picked + custom : (custom.isEmpty ? picked : custom)
    }

    private func normalizedCustom(_ question: InteractionQuestionSpec) -> JSONText? {
        guard let custom = drafts[question.id]?.custom else { return nil }
        return normalize(custom, for: question)
    }

    private func normalize(_ custom: JSONText, for question: InteractionQuestionSpec) -> JSONText {
        // Never normalize secret whitespace or repair unedited UTF-16 payloads.
        guard !question.secret, question.trimsCustomAnswer else { return custom }
        return JSONText(codeUnits: Array(custom.codeUnits.drop(while: Self.isTrimWhitespace)
            .reversed().drop(while: Self.isTrimWhitespace).reversed()))
    }

    private static func isTrimWhitespace(_ unit: UInt16) -> Bool {
        // ECMAScript String.trim's WhiteSpace and LineTerminator code points.
        switch unit {
        case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }
}
