import CryptoKit
import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

func claudeOpaqueID(_ kind: String, execution: JSONText, native: JSONText, indices: [Int] = []) -> JSONText {
    var digest = SHA256(); digest.update(data: Data("mokusei.claude.public-interaction.v1".utf8))
    for part in [JSONText(kind), execution, native] + indices.map({ JSONText(String($0)) }) {
        let bytes = Data(part.string.utf8)
        digest.update(data: Data("\(bytes.count):".utf8)); digest.update(data: bytes)
    }
    return JSONText("claude-\(kind)-sha256-" + digest.finalize().map { String(format: "%02x", $0) }.joined())
}
/// Bind every pending native request as a unit. Partial or stale authority never enables controls.
func claudePublicInteractions(_ state: ClaudeState, _ observation: ThreadPublicObservation) -> [JSONText: PublicInteraction] {
    guard let execution = observation.latestExecution, execution.status == .waitingForUser,
          let turn = state.turns.last(where: { $0.id == execution.executionID }) else { return [:] }
    let pending = turn.interactions.filter { $0["status"]?.stringValue == "pending" }
    guard pending.count == execution.interactions.count else { return [:] }
    var result: [JSONText: PublicInteraction] = [:]
    for native in pending {
        let id = native.claudeID("id")
        let expectedID = claudeOpaqueID("interaction", execution: turn.id, native: id)
        guard let actual = execution.interactions.first(where: { $0.id == expectedID }),
              claudeMatchesPublic(native, actual, execution: turn.id) else { return [:] }
        result[id] = actual
    }
    return result
}
private func claudeMatchesPublic(_ native: JSONValue, _ actual: PublicInteraction, execution: JSONText) -> Bool {
    let kind = native.claudeKind, id = native.claudeID("id")
    guard actual.title == native.claudeID("title"),
          actual.description == (native["description"]?.stringValue?.isEmpty == false ? native.claudeID("description") : nil),
          actual.kind.rawValue == (kind == "permission" ? "permission" : "question") else { return false }
    let actions: [(String, String, String)]
    if kind == "permission" {
        actions = [("allow","allow","Allow")] + (native["canRemember"] == .bool(true) ? [("allow-session","allow","Allow for session")] : []) + [("deny","deny","Deny"),("cancel","cancel","Cancel")]
    } else if kind == "elicitation" {
        actions = [("submit","submit", native["elicitationMode"]?.stringValue == "url" ? "Accept and open" : "Submit"),("deny","deny","Decline"),("cancel","cancel","Cancel")]
    } else { actions = [("submit","submit","Submit"),("cancel","cancel","Cancel")] }
    guard actual.actions.count == actions.count, zip(actual.actions, actions).allSatisfy({ $0.id == JSONText($1.0) && $0.intent.rawValue == $1.1 && $0.label == JSONText($1.2) }) else { return false }
    let rawQuestions = native["questions"]?.arrayValue ?? []
    let count = kind == "question" ? rawQuestions.count : kind == "elicitation" && native["elicitationMode"]?.stringValue == "url" ? 0 : 1
    guard actual.questions.count == count else { return false }
    for (index, question) in actual.questions.enumerated() {
        guard question.id == claudeOpaqueID("question", execution: execution, native: id, indices: [index]), question.allowOther, !question.secret, question.form == nil else { return false }
        if kind == "question" {
            guard question.answerFormat == nil else { return false }
            let raw = rawQuestions[index]
            guard question.prompt == raw.claudeID("question"), question.multiple == (raw["multiSelect"] == .bool(true)),
                  question.header == (raw["header"]?.stringValue?.isEmpty == false ? raw.claudeID("header") : nil) else { return false }
            let options = raw["options"]?.arrayValue ?? []
            guard options.count == question.options.count else { return false }
            for (offset, option) in question.options.enumerated() {
                guard option.value == claudeOpaqueID("option", execution: execution, native: id, indices: [index, offset]),
                      option.label == options[offset].claudeID("label"),
                      option.description == (options[offset]["description"]?.stringValue?.isEmpty == false ? options[offset].claudeID("description") : nil) else { return false }
            }
        } else {
            guard !question.multiple, question.options.isEmpty, question.header == nil else { return false }
            if kind != "elicitation", question.answerFormat != nil { return false }
            if kind == "permission", question.prompt != "Optional denial reason" { return false }
            if kind == "dialog", question.prompt != (native["title"]?.stringValue?.isEmpty == false ? native.claudeID("title") : "Reply") { return false }
            if kind == "elicitation" {
                guard question.answerFormat?.rawValue == "json-object" else { return false }
                if let schema = native["schema"] {
                    let prefix = "JSON form values matching this schema:\n"
                    let prompt = question.prompt
                    let prefixUnits = Array(prefix.utf16)
                    if case .string(let display)? = native["schemaDisplay"] {
                        let expected = JSONText(codeUnits:Array((prefixUnits + display.codeUnits).prefix(20_000)))
                        guard prompt == expected else { return false }
                        continue
                    }
                    guard prompt.codeUnits.starts(with:prefixUnits) else { return false }
                    let suffix = JSONText(codeUnits:Array(prompt.codeUnits.dropFirst(prefixUnits.count)))
                    if prompt.codeUnits.count < 20_000 {
                        guard let parsed = try? JSONValue(data:Data(suffix.string.utf8)), parsed == schema else { return false }
                    } else {
                        guard claudeSchemaPrefixMatches(schema, prefix:suffix) else { return false }
                    }
                } else if question.prompt != "JSON form values" { return false }
            }
        }
    }
    return true
}
struct ClaudeInteractionView: View {
    let interaction: JSONValue
    let publicInteraction: PublicInteraction?
    let actions: HarnessThreadActions
    @State private var busy: JSONText?
    @State private var error: String?
    @State private var message = ""
    @State private var jsonText = "{}"
    @State private var answers = InteractionAnswers()
    @Environment(\.locale) private var locale
    private var kind: String { interaction.claudeKind }
    private var questions: [InteractionQuestionSpec] {
        (publicInteraction?.questions ?? []).map { question in
            InteractionQuestionSpec(id: question.id, prompt: question.prompt.string, header: question.header?.string,
                multiple: question.multiple, allowOther: question.allowOther, secret: question.secret,
                options: question.options.map { InteractionQuestionOption(value: $0.value, label: $0.label.string, description: $0.description?.string) })
        }
    }
    var body: some View {
        ThreadDetailRequest {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                NativeIcon(name: kind == "permission" ? "ShieldAlert" : "FileQuestion", size: 15)
                VStack(alignment: .leading, spacing: 5) {
                    Text(interaction["title"]?.stringValue ?? "").font(NativeTypography.inter(size:16,weight:600)).lineSpacing(8)
                    if let description = interaction["description"]?.stringValue { Text(description).font(NativeTypography.inter(size:13)).lineSpacing(8.45).padding(.top,4).foregroundStyle(NativePalette.thread.muted.swiftUI) }
                    if let tool = interaction["toolName"]?.stringValue { Text(tool).font(NativeTypography.mono(size: 11)) }
                }
            }.padding(.bottom,5)
            if publicInteraction == nil { ClaudeFailure(message: "该请求已失效。") }
            else {
                if let command = interaction["input"]?["command"]?.stringValue, kind == "permission" { Text(command).font(NativeTypography.mono(size: 11)).textSelection(.enabled) }
                if let cwd = interaction["input"]?["cwd"]?.stringValue, kind == "permission" { LabeledContent(t("工作目录"), value: cwd) }
                if interaction["input"] != nil, let display = claudeInteractionDisplay(interaction,field:"input") { DisclosureGroup(t("请求详情")) { Text(display.string).font(NativeTypography.mono(size: 11)).textSelection(.enabled) } }
                if kind == "question" {
                    ForEach(questions) { question in InteractionQuestionField(question:question,answers:$answers,disabled:busy != nil) }
                } else if kind == "permission" {
                    Text(t("拒绝原因") + " · " + t("可选")); TextEditor(text: $message).nativeControlScrollbars().modifier(ClaudeRequestEditor(height:64))
                } else if kind == "elicitation", interaction["elicitationMode"]?.stringValue == "url" {
                    Text(t("此请求需要在 Claude 提供的外部页面中完成。"))
                    if let url = interaction["url"]?.stringValue { Text(url).font(NativeTypography.mono(size: 11)).textSelection(.enabled) }
                    if let server = interaction["serverName"]?.stringValue { Text("MCP Server: \(server)") }
                    if let id = interaction["elicitationId"]?.stringValue { Text("ID: \(id)") }
                } else if kind == "elicitation" {
                    if interaction["schema"] != nil, let display = claudeInteractionDisplay(interaction,field:"schema") { DisclosureGroup(t("字段约束")) { Text(display.string).font(NativeTypography.mono(size: 11)).textSelection(.enabled) } }
                    Text(t("JSON 表单内容")); TextEditor(text: $jsonText).nativeControlScrollbars().font(NativeTypography.mono(size: 12)).modifier(ClaudeRequestEditor(height:110))
                } else { Text(t("回复 Claude")); TextEditor(text: $message).nativeControlScrollbars().modifier(ClaudeRequestEditor(height:75)) }
                if missingDisplay { ClaudeFailure(message:"JSON 展示文本不可用") }
                if let error { ClaudeFailure(message: error) }
                HStack(spacing: 8) {
                    ForEach(visibleActions, id: \.id) { action in
                        Button(t(claudeActionLabel(action, kind: kind))) { perform(action) }
                            .buttonStyle(ClaudeRequestButtonStyle(primary:action.intent == .submit || action.id == "allow"))
                            .disabled(busy != nil || submitDisabled(action))
                    }
                    if busy != nil { ProgressView().controlSize(.small) }
                }.padding(.top,10)
            }
        }.font(NativeTypography.inter(size: 12))
        }
            .disabled(busy != nil)
            .id(interaction.claudeID("id"))
    }
    private var missingDisplay:Bool {
        interaction["input"] != nil && interaction["inputDisplay"] == nil ||
        kind == "elicitation" && interaction["elicitationMode"]?.stringValue != "url" && interaction["schema"] != nil && interaction["schemaDisplay"] == nil
    }
    private var visibleActions: [PublicInteractionAction] {
        (publicInteraction?.actions ?? []).filter { !(kind == "permission" && $0.intent == .cancel) }.sorted { left,right in
            let primaryLeft = left.intent == .submit || left.id == "allow", primaryRight = right.intent == .submit || right.id == "allow"
            return primaryLeft && !primaryRight
        }
    }
    private func t(_ source: String) -> String { claudeLocalized(source, locale: locale) }
    private func submitDisabled(_ action: PublicInteractionAction) -> Bool {
        if missingDisplay && [.submit,.allow].contains(action.intent) { return true }
        guard action.intent == .submit else { return false }
        if kind == "question" { return !answers.isComplete(for:questions) }
        if kind == "dialog" { return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if kind == "elicitation", interaction["elicitationMode"]?.stringValue == "url" { return interaction["url"]?.stringValue?.isEmpty != false }
        return false
    }
    private func perform(_ action: PublicInteractionAction) {
        if kind == "question",action.intent == .submit {
            respond(action.id,answers:answers.answersFor(questions).mapValues { value in switch value { case .single(let text): .text(text); case .multiple(let values): .multiple(values) } })
        } else if action.intent == .submit, kind == "elicitation", interaction["elicitationMode"]?.stringValue != "url" {
            do {
                let parsed = try JSONValue(data: Data(jsonText.utf8))
                guard parsed.objectValue != nil else { throw PluginContractError(t("内容必须是 JSON object。")) }
                guard let question = publicInteraction?.questions.first else { throw PluginContractError(t("该请求已失效。")) }
                respond(action.id, answers: [question.id: .text(JSONText(claudeJSONString(parsed)))])
            } catch { self.error = error.localizedDescription }
        } else if kind == "dialog", action.intent == .submit, let question = publicInteraction?.questions.first {
            respond(action.id, answers: [question.id: .text(JSONText(message.trimmingCharacters(in: .whitespacesAndNewlines)))])
        } else { respond(action.id) }
    }
    private func respond(_ actionID: JSONText, answers: [JSONText: HarnessResponseAnswer]? = nil) {
        guard busy == nil, let current = publicInteraction, let action = current.actions.first(where: { $0.id == actionID }) else { return }
        guard !missingDisplay || ![.submit,.allow].contains(action.intent) else { return }
        busy = actionID; error = nil
        Task { @MainActor in
            defer { busy = nil }
            do {
                if kind == "elicitation", interaction["elicitationMode"]?.stringValue == "url", action.intent == .submit {
                    try await actions.openExternal(interaction.claudeID("url"))
                }
                let denial = kind == "permission" && action.intent == .deny ? message.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                try await actions.respond(HarnessRespondRequest(interactionID: current.id, actionID: actionID, answers: answers,
                    message: denial.isEmpty ? nil : JSONText(denial)))
            } catch { self.error = error.localizedDescription }
        }
    }
}
func claudeActionLabel(_ action: PublicInteractionAction, kind: String) -> String {
    switch action.intent {
    case .allow: action.id == "allow-session" ? "本会话始终允许" : "允许一次"
    case .deny: "拒绝"
    case .cancel: "取消"
    case .submit: action.label == "Accept and open" ? "同意并打开" : kind == "question" ? "提交回答" : "提交"
    }
}

private struct ClaudeRequestEditor: ViewModifier {
    let height:CGFloat
    func body(content:Content) -> some View {
        content.scrollContentBackground(.hidden).font(NativeTypography.inter(size:12))
            .padding(.vertical,10).padding(.horizontal,12).frame(height:height)
            .background(Color.clear,in:RoundedRectangle(cornerRadius:6))
            .overlay(RoundedRectangle(cornerRadius:6).stroke(NativePalette.thread.line.swiftUI))
    }
}
private struct ClaudeRequestButtonStyle: ButtonStyle {
    let primary:Bool
    func makeBody(configuration:Configuration) -> some View { ClaudeRequestButtonBody(configuration:configuration,primary:primary) }
}
private struct ClaudeRequestButtonBody: View {
    let configuration:ButtonStyleConfiguration
    let primary:Bool
    @State private var hovered=false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label.font(NativeTypography.inter(size:11,weight:500))
            .padding(.horizontal,12).padding(.vertical,8).frame(minHeight:34)
            .foregroundStyle((primary ? NativePalette.thread.canvas : NativePalette.thread.muted).swiftUI)
            .background(primary ? NativePalette.thread.accent.swiftUI.opacity(configuration.isPressed ? 0.85 : 1) : hovered || configuration.isPressed ? NativePalette.thread.surface.swiftUI : .clear,in:RoundedRectangle(cornerRadius:8))
            .contentShape(RoundedRectangle(cornerRadius:8)).opacity(enabled ? 1 : 0.45).onHover { hovered=$0 }
    }
}
