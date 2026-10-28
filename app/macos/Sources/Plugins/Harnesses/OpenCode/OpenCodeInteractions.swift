import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct OpenCodeInteractionPanel: View {
    let interaction: PublicInteraction
    let native: JSONValue?
    let actions: HarnessThreadActions
    @Environment(\.locale) private var locale
    @State private var values: [JSONText: JSONValue]
    @State private var answers = InteractionAnswers()
    @State private var message = ""
    @State private var busy: JSONText?
    @State private var failure: String?
    init(interaction: PublicInteraction, native: JSONValue?, actions: HarnessThreadActions) {
        self.interaction = interaction; self.native = native; self.actions = actions
        var defaults: [JSONText: JSONValue] = [:]
        if native?["kind"]?.stringValue == "form" { for field in native?["fields"]?.arrayValue ?? [] {
            if field["type"]?.stringValue != "external", let value = field["default"] { defaults[field.ocID("key")] = value }
        } }
        _values = State(initialValue: defaults)
        _answers = State(initialValue: PublicInteractionQuestionnaire.initialAnswers(for: interaction))
    }
    private var form: JSONValue? { native?["kind"]?.stringValue == "form" ? native : nil }
    private var fields: [JSONValue] { ocActiveFields(form?["fields"]?.arrayValue ?? [], values: values) }
    private var questionnaire: PublicInteractionQuestionnaire { .init(interaction: interaction, answers: answers) }
    private var questions: [InteractionQuestionSpec] { questionnaire.questions }
    private var complete: Bool {
        if form == nil { return questionnaire.canSubmit }
        return fields.allSatisfy { field in
            let value = values[field.ocID("key")]
            if field["type"]?.stringValue == "external" { return value == .bool(true) }
            if field["required"] != .bool(true), value == nil || value == .text("") { return true }
            guard let value, value != .text(""), value.arrayValue?.isEmpty != true else { return field["required"] != .bool(true) }
            if ["number", "integer"].contains(field["type"]?.stringValue ?? ""), value.numberValue == nil { return false }
            if let number = value.numberValue {
                if field["type"]?.stringValue == "integer", number.rounded() != number { return false }
                if let min = field["minimum"]?.numberValue, number < min { return false }
                if let max = field["maximum"]?.numberValue, number > max { return false }
            }
            if let text = value.ocString {
                if let min = field["minLength"]?.intValue, text.codeUnits.count < min { return false }
                if let max = field["maxLength"]?.intValue, text.codeUnits.count > max { return false }
                switch field["format"]?.stringValue {
                case "email": if !ocValidEmail(text.string) { return false }
                case "uri": if URL(string: text.string)?.scheme == nil { return false }
                case "date": if !ocValidDate(text.string) { return false }
                default: break
                }
            }
            return true
        }
    }
    var body: some View {
        ThreadDetailRequest {
        VStack(alignment: .leading, spacing: 12) {
            Text(interaction.title.string).font(NativeTypography.inter(size: 13, weight: 600))
            if let description = interaction.description { Text(description.string).foregroundStyle(NativePalette.thread.muted.swiftUI) }
            if native?["kind"]?.stringValue == "permission", let resources = native?["resources"]?.arrayValue, !resources.isEmpty {
                OpenCodeToolOutput(text: resources.compactMap(\.stringValue).joined(separator: "\n"))
            }
            if form != nil {
                ForEach(fields, id: \.ocFieldID) { field in
                    OpenCodeNativeField(field: field, value: Binding(get: { values[field.ocID("key")] }, set: { values[field.ocID("key")] = $0 }), disabled: busy != nil,
                        openExternal: { value in Task { do { try await actions.openExternal(value) } catch { failure = error.localizedDescription } } })
                }
            } else {
                ForEach(questions) { question in InteractionQuestionField(question: question, answers: $answers, disabled: busy != nil) }
            }
            if interaction.kind == .permission {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ocLocalized("OpenCode 拒绝原因（可选）", locale: locale))
                    TextEditor(text: $message).scrollContentBackground(.hidden).frame(height: 48).modifier(OpenCodeFieldDecoration()).disabled(busy != nil)
                }
            }
            if let failure { Text(failure).foregroundStyle(NativePalette.thread.danger.swiftUI).textSelection(.enabled) }
            OpenCodeActionFlow {
                ForEach(interaction.actions, id: \.id) { action in
                    Button(ocActionLabel(action, locale: locale)) { respond(action) }
                        .buttonStyle(OpenCodeButtonStyle()).disabled(busy != nil || (action.intent == .submit && !complete))
                }
            }.padding(.top, 2)
        }.font(NativeTypography.inter(size: 12)).foregroundStyle(NativePalette.thread.ink.swiftUI)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
            .onSubmit { if complete, let submit = interaction.actions.first(where: { $0.intent == .submit }) { respond(submit) } }
    }
    private func respond(_ action: PublicInteractionAction) {
        guard busy == nil else { return }
        busy = action.id; failure = nil
        var payload: [JSONText: HarnessResponseAnswer]?
        if action.intent == .submit {
            if let form {
                payload = [:]
                for field in fields {
                    let key = field.ocID("key")
                    guard let value = values[key], !(["number", "integer"].contains(field["type"]?.stringValue ?? "") && value == .text("")) else { continue }
                    let options = ocFieldOptions(field)
                    let encode: (JSONText) -> JSONText = { value in
                        options.contains(where: { $0.ocText("value") == value }) ? ocPublicID("option", [form.ocID("executionId"), form.ocID("id"), key, value]) : value
                    }
                    let question = ocPublicID("question", [form.ocID("executionId"), form.ocID("id"), key])
                    if let values = value.arrayValue { payload?[question] = .multiple(values.map { encode(ocScalarText($0)) }) }
                    else { payload?[question] = .text(encode(ocScalarText(value))) }
                }
            } else { payload = questionnaire.answers.mapValues { switch $0 { case .single(let value): .text(value); case .multiple(let values): .multiple(values) } } }
        }
        let denial = action.intent == .deny && !ocTrim(message).isEmpty ? JSONText(ocTrim(message)) : nil
        let response = HarnessRespondRequest(interactionID: interaction.id, actionID: action.id, answers: payload, message: denial)
        Task { @MainActor in
            defer { busy = nil }
            do { try await actions.respond(response) } catch { failure = error.localizedDescription }
        }
    }
}
private extension JSONValue { var ocFieldID: JSONText { ocID("key") } }
func ocActiveFields(_ fields: [JSONValue], values: [JSONText: JSONValue]) -> [JSONValue] {
    var effective: [JSONText: JSONValue] = [:]
    return fields.filter { field in
        if field["type"]?.stringValue == "external" { return true }
        let active = (field["when"]?.arrayValue ?? []).allSatisfy { condition in
            guard let actual = effective[condition.ocID("key")], let expected = condition["value"] else { return false }
            let matches = actual.arrayValue?.contains(expected) ?? (actual == expected)
            return condition["op"]?.stringValue == "eq" ? matches : !matches
        }
        let raw = values[field.ocID("key")]
        let value = ["number", "integer"].contains(field["type"]?.stringValue ?? "") && raw == .text("") ? field["default"] : raw
        if active, let value { effective[field.ocID("key")] = value }
        return active && field["hidden"] != .bool(true)
    }
}
func ocFieldOptions(_ field: JSONValue) -> [JSONValue] {
    switch field["type"]?.stringValue {
    case "external": [.object(["value": .text("true"), "label": .text("I have completed this step")])]
    case "boolean": [.object(["value": .text("true"), "label": .text("Yes")]), .object(["value": .text("false"), "label": .text("No")])]
    case "string", "multiselect": field["options"]?.arrayValue ?? []
    default: []
    }
}
func ocScalarText(_ value: JSONValue) -> JSONText {
    if let text = value.ocString { return text }
    if let flag = value.boolValue { return JSONText(flag ? "true" : "false") }
    if let number = value.numberValue { return JSONText(number.rounded() == number ? String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), number) : String(number)) }
    return ""
}
private struct OpenCodeNativeField: View {
    let field: JSONValue
    @Binding var value: JSONValue?
    let disabled: Bool
    let openExternal: (JSONText) -> Void
    @Environment(\.locale) private var locale
    @FocusState private var inputFocused: Bool
    @State private var datePopover = false
    private var type: String { field["type"]?.stringValue ?? "" }
    private var label: String { field["title"]?.stringValue ?? field.ocID("key").string }
    private var options: [JSONValue] { ocFieldOptions(field) }
    private var selected: [JSONText] { value?.arrayValue?.compactMap(\.ocString) ?? [] }
    private var stringValue: Binding<String> { Binding(get: { value.map { ocScalarText($0).string } ?? "" }, set: { text in
        if ["number", "integer"].contains(type) { value = text.isEmpty ? .text("") : Double(text).flatMap { $0.isFinite ? JSONValue.number($0) : nil } ?? .text(text) }
        else { value = .text(text) }
    }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label + (field["required"] == .bool(true) ? " *" : ""))
            if let description = field["description"]?.stringValue { Text(description).foregroundStyle(NativePalette.thread.muted.swiftUI) }
            if type == "external" {
                Button(ocLocalized("打开 OpenCode 请求页面", locale: locale)) { openExternal(field.ocID("url")) }.buttonStyle(OpenCodeButtonStyle())
                Text(field["url"]?.stringValue ?? "").foregroundStyle(NativePalette.thread.muted.swiftUI).font(NativeTypography.inter(size: 11))
                Toggle(ocLocalized("我已完成此步骤", locale: locale), isOn: Binding(get: { value == .bool(true) }, set: { value = .bool($0) })).toggleStyle(OpenCodeCheckboxStyle())
            } else if type == "boolean" {
                select(options: [NativeSettingsOption(id: "", label: ocLocalized("请选择", locale: locale), disabled: field["required"] == .bool(true)),
                    .init(id: "true", label: ocLocalized("是", locale: locale)), .init(id: "false", label: ocLocalized("否", locale: locale))],
                    binding: Binding(get: { value.map(ocScalarText) ?? "" }, set: { value = $0.codeUnits.isEmpty ? field["default"] : .bool($0 == "true") }))
            } else if type == "multiselect" {
                ForEach(options, id: \.ocOptionID) { option in
                    Toggle(isOn: Binding(get: { selected.contains(option.ocID("value")) }, set: { flag in
                        value = .array((flag ? selected + [option.ocID("value")] : selected.filter { $0 != option.ocID("value") }).map(JSONValue.string))
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option["label"]?.stringValue ?? "")
                            if let description = option["description"]?.stringValue { Text(description).foregroundStyle(NativePalette.thread.muted.swiftUI).font(NativeTypography.inter(size: 11)) }
                        }
                    }.toggleStyle(OpenCodeCheckboxStyle())
                }
                if field["custom"] == .bool(true) {
                    let custom = Binding<String>(get: { selected.filter { value in !options.contains { $0.ocText("value") == value } }.map(\.string).joined(separator: "\n") }, set: { text in
                        let existing = selected.filter { value in options.contains { $0.ocText("value") == value } }
                        value = .array((existing + text.split(separator: "\n", omittingEmptySubsequences: true).map { JSONText(String($0)) }).map(JSONValue.string))
                    })
                    TextEditor(text: custom).scrollContentBackground(.hidden).frame(height: 48).modifier(OpenCodeFieldDecoration()).accessibilityLabel(ocLocalized("其他回答，每行一项", locale: locale))
                }
            } else if type == "string", !options.isEmpty, field["custom"] != .bool(true) {
                select(options: [.init(id: "", label: ocLocalized("请选择", locale: locale))] + options.map { .init(id: ocJSONStringID([$0["value"] ?? .null]), label: $0["label"]?.stringValue ?? "") },
                    binding: Binding(get: { value.map { ocJSONStringID([$0]) } ?? "" }, set: { selection in value = options.first { ocJSONStringID([$0["value"] ?? .null]) == selection }?["value"] ?? field["default"] }))
            } else {
                HStack(spacing: 6) {
                    TextField(field["placeholder"]?.stringValue ?? "", text: stringValue).textFieldStyle(.plain)
                        .focused($inputFocused).accessibilityLabel(label)
                        .onChange(of: inputFocused) { _, focused in if !focused && ["number", "integer"].contains(type) && value == .text(""), let fallback = field["default"] { value = fallback } }
                        .onKeyPress(.upArrow) { stepNumber(1) }
                        .onKeyPress(.downArrow) { stepNumber(-1) }
                    if field["format"] == .text("date") {
                        Button { datePopover = true } label: { NativeIcon(name: "Calendar", size: 14) }.buttonStyle(.plain)
                            .accessibilityLabel(label)
                            .popover(isPresented: $datePopover) {
                                DatePicker(label, selection: dateBinding, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden().padding(8)
                            }
                    } else if !options.isEmpty, field["custom"] == .bool(true) {
                        Menu { ForEach(options, id: \.ocOptionID) { option in Button(option["label"]?.stringValue ?? "") { value = option["value"] } } } label: {
                            NativeIcon(name: "ChevronDown", size: 12)
                        }.nativeBorderlessMenu().menuIndicator(.hidden).fixedSize().accessibilityLabel(label)
                    }
                }.modifier(OpenCodeFieldDecoration())
            }
        }.padding(.vertical, 6).disabled(disabled)
    }
    private var dateBinding: Binding<Date> {
        Binding(get: { ocDateFormatter().date(from: value?.stringValue ?? "") ?? Date() }, set: { value = .text(ocDateFormatter().string(from: $0)); datePopover = false })
    }
    private func stepNumber(_ amount: Double) -> KeyPress.Result {
        guard inputFocused, ["number", "integer"].contains(type) else { return .ignored }
        var next = (value?.numberValue ?? field["default"]?.numberValue ?? 0) + amount
        if let minimum = field["minimum"]?.numberValue { next = max(minimum, next) }
        if let maximum = field["maximum"]?.numberValue { next = min(maximum, next) }
        value = .number(next)
        return .handled
    }
    private func select(options: [NativeSettingsOption], binding: Binding<JSONText>) -> some View {
        Menu {
            ForEach(options) { option in Button(option.label) { binding.wrappedValue = option.id }.disabled(option.disabled) }
        } label: {
            HStack { Text(options.first { $0.id == binding.wrappedValue }?.label ?? binding.wrappedValue.string); Spacer(); NativeIcon(name: "ChevronDown", size: 12) }.modifier(OpenCodeFieldDecoration())
        }.nativeBorderlessMenu().menuIndicator(.hidden).accessibilityLabel(label)
    }
}
private extension JSONValue { var ocOptionID: JSONText { ocID("value") } }
struct OpenCodeFieldDecoration: ViewModifier {
    func body(content: Content) -> some View { content.padding(.horizontal, 8).padding(.vertical, 6).background(NativePalette.thread.surface.swiftUI, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(NativePalette.thread.line.swiftUI)) }
}
private typealias OpenCodeCheckboxStyle = CheckboxToggleStyle
struct OpenCodeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 10).padding(.vertical, 5).foregroundStyle(NativePalette.thread.ink.swiftUI)
            .background(NativePalette.thread.surface.swiftUI.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(NativePalette.thread.line.swiftUI)).opacity(enabled ? 1 : 0.5)
    }
}
struct OpenCodeActionFlow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { layout(subviews, width: proposal.width ?? 744).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = layout(subviews, width: bounds.width).frames
        for (index, view) in subviews.enumerated() { view.place(at: .init(x: bounds.minX + frames[index].minX, y: bounds.minY + frames[index].minY), proposal: .init(frames[index].size)) }
    }
    private func layout(_ views: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0; var frames: [CGRect] = []
        for view in views { let size = view.sizeThatFits(.unspecified); if x > 0 && x + size.width > width { x = 0; y += height + 8; height = 0 }; frames.append(.init(x: x, y: y, width: size.width, height: size.height)); x += size.width + 8; height = max(height, size.height) }
        return (.init(width: width, height: y + height), frames)
    }
}
private func ocActionLabel(_ action: PublicInteractionAction, locale: Locale) -> String {
    ocLocalized(["allow": "允许一次", "allow-session": "本会话始终允许", "deny": "拒绝", "submit": "提交", "cancel": "取消"][action.id.string] ?? action.label.string, locale: locale)
}

private func ocDateFormatter() -> DateFormatter {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
    return formatter
}
private func ocValidDate(_ value: String) -> Bool {
    guard value.range(of: #"^\d{4,}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
          let date = ocDateFormatter().date(from: value) else { return false }
    return ocDateFormatter().string(from: date) == value
}

private func ocValidEmail(_ value: String) -> Bool {
    value.range(of: #"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$"#, options: .regularExpression) != nil
}
