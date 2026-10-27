import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

public struct OpenCodeOverviewView {
    public let presentation: ThreadCardPresentation
    public let excerpt: String
    public let message: ThreadCardMessage?
    public let initialResponseContent: Bool
    public let initialResponse: ThreadCardInitialResponse?
    public let steer: String?
    public let model: String
    public let effort: String
    public let pendingInteractionID: JSONText?
    public let openForm: Bool
}
func projectOpenCodeOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewProjection<OpenCodeOverviewView> {
    let state = try OpenCodeState(input.thread.sessionState)
    let latest = input.thread.observation.latestExecution
    let messages = state.messages.filter { $0.executionID == latest?.executionID && !$0.inherited }
    let prompts = messages.filter { $0.role == "user" && ($0.nativeSessionID == nil || $0.nativeSessionID == state.nativeSessionID) }
    let steer = prompts.count > 1 ? prompts.last.map { ocTrim($0.text) } : nil
    let agent = ocOverviewMessage(messages, sessionID: state.nativeSessionID, status: latest?.status)
    let sourceMessage = agent ?? prompts.last.map {
        (id: ocJSONStringID([.string($0.executionID), .text($0.role), .string($0.id)]), text: ocTrimText($0.raw.ocID("text")))
    }
    let text = sourceMessage?.text ?? ""
    let head = ocHeadText(text, points: 600)
    let excerptRaw = head.codeUnits.count < text.codeUnits.count ? ocJoinedID([head, "…"]) : head
    let excerpt = excerptRaw.string
    let message = sourceMessage.map { ThreadCardMessage(id: $0.id, text: $0.text.string) }
    let usage = ocExecutionUsage(messages, auxiliary: state.auxiliary.filter { $0.ocText("executionId") == latest?.executionID })
    let pending = latest?.status == .waitingForUser ? latest?.interactions.first : nil
    let native = pending.flatMap { state.nativeInteraction($0.id) }
    let openForm = native?["kind"]?.stringValue == "form" && (native?["fields"]?.arrayValue ?? []).contains { field in
        field["type"]?.stringValue != "string" || field["hidden"] == .bool(true) || !(field["when"]?.arrayValue ?? []).isEmpty || field["default"] != nil || field["required"] != .bool(true) || ["minLength", "maxLength", "pattern", "format"].contains { field[$0] != nil }
    }
    var extensions: [ThreadCardExtensionProjection] = []
    if let pending {
        extensions.append(.intervention(ThreadCardIntervention(id: pending.id, title: pending.title.string,
            detail: pending.description?.string,
            actions: openForm ? [.init(id: "open-native-form", label: "打开 OpenCode 表单")] : pending.actions.map { .init(id: $0.id, label: $0.label.string) },
            questions: openForm ? [] : pending.questions.map { question in
                ThreadCardQuestion(id: question.id, prompt: question.prompt.string, header: question.header?.string,
                    multiple: question.multiple, allowOther: question.allowOther, secret: question.secret,
                    options: question.options.map { .init(id: $0.value, label: $0.label.string, description: $0.description?.string, value: $0.value) })
            }, submitActionId: openForm ? nil : pending.actions.first { $0.intent == .submit }?.id)))
    }
    if latest?.status == .running || latest?.status == .waitingForUser,
       let todos = messages.last(where: { $0.role == "tool" && $0.raw["todos"] != nil })?.raw["todos"]?.arrayValue,
       todos.contains(where: { $0["done"] != .bool(true) }) {
        extensions.append(.todo(steps: todos.map { .init(step: $0["text"]?.stringValue ?? "", status: $0["done"] == .bool(true) ? .completed : .pending) }))
    }
    let identity = ThreadCardIdentityProjection(usage: usage.map { ThreadCardIdentityUsage(parts: [
        .init(suffix: "tokens", description: "输入与输出 token 合计，按 Harness 当前上报的统计范围显示", id: "total", value: ocCompactTokens($0.total), numericValue: $0.total)
    ]) })
    let presentation = try composeThreadCard(.standard(identity: identity, extensions: extensions), git: input.git, layoutContext: .init(availableCols: availableColumns))
    let settings = input.thread.settings
    let model = [settings["provider"]?.stringValue, settings["model"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
    let initial = state.initialResponseScope && agent == nil && input.thread.moku != true
        ? threadCardInitialResponse(pendingInput: input.thread.pendingInput, observation: input.thread.observation,
                                    hasVisibleInteraction: pending != nil) : nil
    let view = OpenCodeOverviewView(presentation: presentation, excerpt: initial == nil ? excerpt : "", message: initial == nil ? message : nil,
        initialResponseContent: state.initialResponseScope && agent != nil && input.thread.moku != true, initialResponse: initial, steer: steer,
        model: model.isEmpty ? "OpenCode" : model, effort: settings["thinking"].map(ocThinkingLabel) ?? "未选择", pendingInteractionID: pending?.id, openForm: openForm)
    return .init(footprint: .init(columns: presentation.size.cols, rows: presentation.size.rows), structureKey: JSONText(presentation.key), excerpt: excerptRaw, view: view)
}
private func ocOverviewMessage(_ messages: [OpenCodeMessage], sessionID: JSONText?, status: PublicExecution.Status?) -> (id: JSONText, text: JSONText)? {
    let live = status == .running || status == .waitingForUser
    let reasoningEligible = status == .completed || live
    for message in messages.reversed() {
        guard message.role == "assistant", message.nativeSessionID == nil || message.nativeSessionID == sessionID else { continue }
        let complete = message.status == "complete"
        guard complete || live else { continue }
        let eligible: (JSONValue) -> Bool = { part in
            ((part["type"]?.stringValue == "text" && complete) || (part["type"]?.stringValue == "reasoning" && reasoningEligible)) && !ocTrimText(part.ocID("text")).codeUnits.isEmpty
        }
        let part = live ? message.parts.last(where: { $0["type"]?.stringValue == "text" && eligible($0) }) ?? message.parts.last(where: eligible) : message.parts.last(where: eligible)
        let answer = complete ? ocTrimText(message.raw.ocID("text")) : JSONText("")
        let reasoning = reasoningEligible ? ocTrimText(message.raw.ocID("thinking")) : JSONText("")
        let kind = part?["type"]?.stringValue ?? (answer.codeUnits.isEmpty ? "reasoning" : "text")
        let text = kind == "reasoning" && part != nil ? ocTrimText(part?.ocID("text") ?? "") : !answer.codeUnits.isEmpty ? answer : part?["type"]?.stringValue == "text" ? ocTrimText(part?.ocID("text") ?? "") : reasoning
        if !text.codeUnits.isEmpty { return (id: ocJSONStringID([.string(message.executionID), .text(message.role), .string(message.id), .text(kind), part?["ordinal"] ?? .null]), text: text) }
    }
    return nil
}
public struct OpenCodeOverviewCard: View {
    public let input: HarnessThreadInput
    public let projection: OpenCodeOverviewView
    public let actions: HarnessThreadActions
    public let openThread: () -> Void
    @Environment(\.locale) private var locale
    @State private var failure: String?
    public init(input: HarnessThreadInput, projection: OpenCodeOverviewView, actions: HarnessThreadActions, openThread: @escaping () -> Void) {
        self.input = input; self.projection = projection; self.actions = actions; self.openThread = openThread
    }
    public var body: some View {
        let execution = input.thread.observation.latestExecution
        let identity = ThreadCardIdentityView(title: input.thread.title.string, harness: .init(brandKey: "opencode", label: "OpenCode", logoSource: OpenCodeLogo.source),
            model: projection.model, effort: ocLocalized(projection.effort, locale: locale),
            runtime: execution.map { .init(startedAt: $0.startedAt, endedAt: $0.finishedAt) }, steer: projection.steer,
            excerpt: projection.excerpt, message: projection.message, initialResponse: projection.initialResponse, initialResponseContent: projection.initialResponseContent)
        HarnessThreadCard(identity: identity, presentation: projection.presentation, onRespond: respond,
            onOpen: openThread,
            interventionActionLabel: { $0.id == "open-native-form" ? ocLocalized("打开 OpenCode 表单", locale: locale) : $0.label },
            status: threadCardStatus(input.thread.observation), emoji: ocEmoji(input.thread.metadataState), harnessLogo: AnyView(OpenCodeLogo(size: 12)))
            .environment(\.threadCardProviderColor, NativePalette.pair(0x33312f, 0xd9d7d4).swiftUI)
            .environment(\.threadCardCloudPalette, OpenCodeLogo.threadCardCloudPalette)
            .overlay(alignment: .bottomLeading) { if let failure { Text(failure).font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.overview.danger.swiftUI).padding(18) } }
    }
    private func respond(_ response: ThreadCardInterventionResponse) async throws {
        failure = nil
        do {
            guard let current = input.thread.observation.latestExecution, current.status == .waitingForUser,
                  let interaction = current.interactions.first(where: { $0.id == projection.pendingInteractionID }) else { throw OpenCodeError.expiredInteraction }
            if projection.openForm && response.actionId == "open-native-form" { openThread(); return }
            guard interaction.actions.contains(where: { $0.id == response.actionId }) else { throw OpenCodeError.expiredInteraction }
            try await actions.respond(HarnessRespondRequest(interactionID: interaction.id, actionID: response.actionId,
                answers: response.answers.map { answers in answers.mapValues { switch $0 { case .string(let value): .text(value); case .strings(let values): .multiple(values) } } }))
        } catch { failure = error.localizedDescription; throw error }
    }
}
func ocThinkingLabel(_ value: JSONValue) -> String {
    value["mode"]?.stringValue == "effort" ? value["effort"]?.stringValue ?? "" : value["mode"]?.stringValue ?? "未选择"
}

func ocEmoji(_ metadata: JSONValue?) -> String? { nativeGeneratedThreadEmoji(metadata: metadata) }

func ocMessageAnchor(_ message: OpenCodeMessage) -> JSONText {
    guard let part = message.parts.last(where: { $0["type"]?.stringValue == "text" && !ocTrim($0["text"]?.stringValue ?? "").isEmpty }) else { return message.id }
    return ocJoinedID([message.id, JSONText(":text:\(part["ordinal"]?.intValue ?? 0)")])
}
func ocMokuReplyAnchor(_ state: OpenCodeState, target: JSONValue?) -> JSONText? {
    guard let target, let executionID = target.ocText("executionId"), let messageID = target.ocText("messageId"),
          let message = state.messages.first(where: { $0.id == messageID && $0.executionID == executionID && $0.role == "assistant" && !$0.inherited }) else { return nil }
    return ocMessageAnchor(message)
}
func projectOpenCodeMoku(_ state: OpenCodeState) -> HarnessMokuPresentation {
    let execution = state.executions.first { $0.executionID == state.latestExecutionID }
    var activity: HarnessActivity?
    if execution?.status == .running, let execution,
       let foreground = state.raw["foregrounds"]?.arrayValue?.first(where: { $0.ocText("executionId") == execution.executionID })?["foreground"],
       let sequence = foreground["sequence"]?.intValue {
        let body: HarnessActivityBody?
        switch foreground["kind"]?.stringValue {
        case "reasoning": body = .reasoning(text: foreground.ocID("text"), textOffset: foreground["textOffset"]?.intValue)
        case "assistant-text": body = .assistantText
        case "tool-call": body = .toolCall(callID: foreground.ocID("callId"), toolName: foreground.ocID("toolName"))
        default: body = nil
        }
        if let body { activity = HarnessActivity(executionID: execution.executionID, sequence: sequence, body: body) }
    }
    var reply: HarnessMokuReply?
    for candidate in state.executions.reversed() where candidate.status == .completed {
        if let message = state.messages.last(where: { $0.executionID == candidate.executionID && $0.role == "assistant" && $0.status == "complete" && !$0.inherited && !ocTrim($0.text).isEmpty && ($0.nativeSessionID == nil || $0.nativeSessionID == state.nativeSessionID) }) {
            reply = .init(id: ocJSONStringID([.string(candidate.executionID), .string(message.id)]), executionID: candidate.executionID,
                excerpt: ocHeadText(ocTrimText(message.raw.ocID("text")), points: HarnessMokuPresentation.maximumReplyExcerptPoints),
                target: .object(["executionId": .string(candidate.executionID), "messageId": .string(message.id)])); break
        }
    }
    return .init(activity: activity, reply: reply)
}
