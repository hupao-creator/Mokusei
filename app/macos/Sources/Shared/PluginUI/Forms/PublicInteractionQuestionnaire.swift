import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Shared public-form presentation for the Dock and readers. Native defaults
/// participate in conditions even when their fields are hidden; user drafts for
/// inactive fields remain local and are excluded from the submitted answer.
public struct PublicInteractionQuestionnaire {
    public let questions: [InteractionQuestionSpec]
    public let answers: [JSONText: InteractionAnswer]
    public let errors: [JSONText: String]
    public var canSubmit: Bool { errors.isEmpty }

    public static func specs(for interaction: PublicInteraction) -> [InteractionQuestionSpec] {
        interaction.questions.map { question in
            let form = question.form
            let editor: InteractionQuestionEditor = switch form?.type {
            case .number: .number
            case .integer: .integer
            default: question.answerFormat == .jsonObject ? .jsonObject : .singleLine
            }
            return InteractionQuestionSpec(id: question.id, prompt: question.prompt.string,
                header: question.header?.string, multiple: question.multiple,
                allowOther: question.allowOther, secret: question.secret,
                options: question.options.map { .init(value: $0.value, label: $0.label.string, description: $0.description?.string) },
                required: form?.required ?? true, hasDefault: form?.defaultValue != nil,
                editor: editor, trimsCustomAnswer: form == nil,
                minimum: form?.minimum, maximum: form?.maximum)
        }
    }

    public static func initialAnswers(for interaction: PublicInteraction) -> InteractionAnswers {
        let specs = specs(for: interaction)
        var defaults: [JSONText: InteractionAnswer] = [:]
        for question in interaction.questions {
            guard let form = question.form, let value = form.defaultValue,
                  form.type != .external, form.hidden != true else { continue }
            let encode: (JSONValue) -> JSONText = { value in
                let text = scalarText(value)
                return question.options.first { form.optionValues?[$0.value] == text }?.value ?? text
            }
            defaults[question.id] = question.multiple
                ? .multiple((value.arrayValue ?? []).map(encode)) : .single(encode(value))
        }
        return InteractionAnswers(questions: specs, values: defaults)
    }

    public init(interaction: PublicInteraction, answers draft: InteractionAnswers) {
        let specs = Self.specs(for: interaction)
        let supplied = draft.answersFor(specs, includingEmpty: true)
        var effective: [JSONText: JSONValue] = [:]
        var visible: [InteractionQuestionSpec] = []
        var outgoing: [JSONText: InteractionAnswer] = [:]
        var failures: [JSONText: String] = [:]
        for (question, spec) in zip(interaction.questions, specs) {
            let form = question.form
            let active = (form?.when ?? []).allSatisfy { condition in
                guard let actual = effective[condition.questionID] else { return false }
                let matches = actual.arrayValue?.contains(condition.value) ?? (actual == condition.value)
                return condition.op == .eq ? matches : !matches
            }
            guard active else { continue }
            let hidden = form?.hidden == true
            var answer = hidden ? nil : supplied[question.id]
            if (form?.type == .number || form?.type == .integer), answer == .single("") { answer = nil }
            let native: JSONValue?
            if let answer { native = Self.nativeValue(answer, form: form) }
            else { native = form?.defaultValue }
            if let native { effective[question.id] = native }
            guard !hidden else { continue }
            visible.append(spec)
            if let answer { outgoing[question.id] = answer }
            // Core owns schema validation. This gate only prevents missing
            // required answers; defaults and optional absence remain valid.
            if form?.type == .external {
                if native != .bool(true) { failures[question.id] = "Confirm that this step is complete." }
            } else if spec.required {
                let empty = native == nil || native == .text("") || native == .array([])
                if empty { failures[question.id] = "An answer is required." }
            }
        }
        questions = visible; answers = outgoing; errors = failures
    }

    private static func scalarText(_ value: JSONValue) -> JSONText {
        switch value {
        case .string(let text): text
        case .bool(let value): JSONText(value ? "true" : "false")
        default: JSONText((try? value.encodedData()).flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }
    }

    private static func nativeValue(_ answer: InteractionAnswer, form: PublicQuestionForm?) -> JSONValue? {
        let decode: (JSONText) -> JSONText = { form?.optionValues?[$0] ?? $0 }
        switch answer {
        case .multiple(let values): return .array(values.map { .string(decode($0)) })
        case .single(let raw):
            let text = decode(raw)
            switch form?.type {
            case .number, .integer:
                let value = text.string.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
                if value.count > 2, value.first == "0", let marker = value.dropFirst().first,
                   let base = ["x": 16, "X": 16, "o": 8, "O": 8, "b": 2, "B": 2][String(marker)] {
                    var number = 0.0
                    for character in value.dropFirst(2) {
                        guard let digit = character.hexDigitValue, digit < base else { return nil }
                        number = number * Double(base) + Double(digit)
                    }
                    return number.isFinite ? .number(number) : nil
                }
                guard let number = Double(value), number.isFinite else { return nil }
                return .number(number)
            case .boolean, .external:
                return text == "true" ? .bool(true) : text == "false" ? .bool(false) : nil
            default: return .string(text)
            }
        }
    }
}
