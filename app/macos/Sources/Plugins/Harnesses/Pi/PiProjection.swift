import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

public struct PiOverviewView {
    let presentation: ThreadCardPresentation
    let excerpt: JSONText
    let message: ThreadCardMessage?
    let initialResponseContent: Bool
    let initialResponse: ThreadCardInitialResponse?
    let steer: JSONText?
    let model: String
    let effort: String
    let status: String
    let pendingInteractionID: JSONText?
}

func piOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewProjection<PiOverviewView> {
    let state = try PiState(input.thread.sessionState)
    let executionID = state.latestExecutionID
    let current = state.messages.filter { executionID == nil || $0.executionID == executionID }
    let prompts = executionID == nil ? [] : current.filter { $0.role == "user" }
    let steer = prompts.count > 1 ? prompts.last.map { piTrim($0.text) } : nil
    let latest = input.thread.observation.latestExecution
    let status = latest?.executionID == executionID ? latest?.status : state.executions.first { $0.executionID == executionID }?.status
    let prompt = current.last { $0.role == "user" }
    let agent = piOverviewMessage(state, executionID: executionID, status: status)
    let source = agent ?? prompt.map {
        (id: piKey([$0.executionID, $0.role, $0.id]), text: piTrim($0.text))
    }
    let message = source.map { ThreadCardMessage(id: $0.id, text: $0.text.string) }
    let trimmed = piTrim(source?.text ?? "")
    let excerpt = piPointCount(trimmed) > 600 ? JSONText(codeUnits: piHead(trimmed, 600).codeUnits + [0x2026]) : trimmed
    let usage = executionID.flatMap { state.executionUsage[$0] }
    let pending = latest?.status == .waitingForUser ? latest?.interactions.first : nil
    var extensions: [ThreadCardExtensionProjection] = []
    if let pending, !pending.questions.contains(where: \.secret) {
        extensions.append(.intervention(ThreadCardIntervention(id: pending.id, title: pending.title.string,
            detail: pending.description?.string,
            actions: pending.actions.map { ThreadCardDecisionAction(id: $0.id, label: $0.label.string) },
            questions: pending.questions.map { question in
                ThreadCardQuestion(id: question.id, prompt: question.prompt.string, header: question.header?.string,
                    multiple: question.multiple, allowOther: question.allowOther, secret: question.secret,
                    options: question.options.map { ThreadCardQuestionOption(id: $0.value, label: $0.label.string, description: $0.description?.string, value: $0.value) })
            }, submitActionId: pending.actions.first { $0.intent == .submit }?.id)))
    }
    if let latest, [.running, .waitingForUser].contains(latest.status),
       let todos = state.messages.last(where: { $0.executionID == latest.executionID && $0.role == "tool" && $0.toolName == "todo" && $0.todos != nil })?.todos,
       todos.contains(where: { !$0.done }) {
        extensions.append(.todo(steps: todos.map { ThreadCardPlanStep(step: $0.text.string, status: $0.done ? .completed : .pending) }))
    }
    let identity = ThreadCardIdentityProjection(usage: usage.map { ThreadCardIdentityUsage(parts: [
        ThreadCardIdentityUsagePart(suffix: "tokens", description: "本次执行已上报的输入与输出 token 累计（含缓存）",
            id: "total", value: piCompactTokens($0.total), numericValue: $0.total)
    ]) })
    let presentation = try composeThreadCard(.standard(identity: identity, extensions: extensions),
        git: input.git, layoutContext: ThreadCardLayoutContext(availableCols: availableColumns))
    let model = [piText(input.thread.settings["provider"]), piText(input.thread.settings["model"])].compactMap { $0 }.filter { !$0.codeUnits.isEmpty }.map(\.string).joined(separator: "/")
    let initial = state.initialResponseScope && agent == nil && input.thread.moku != true
        ? threadCardInitialResponse(pendingInput: input.thread.pendingInput, observation: input.thread.observation,
                                    hasVisibleInteraction: pending.map { !$0.questions.contains(where: \.secret) } ?? false) : nil
    let view = PiOverviewView(presentation: presentation, excerpt: initial == nil ? excerpt : "", message: initial == nil ? message : nil,
        initialResponseContent: state.initialResponseScope && agent != nil && input.thread.moku != true, initialResponse: initial, steer: steer,
        model: model.isEmpty ? "Pi" : model, effort: piThinkingLabel(input.thread.settings["thinking"]) ?? "未选择",
        status: latest?.status.rawValue ?? "idle", pendingInteractionID: pending?.id)
    return HarnessOverviewProjection(footprint: HarnessOverviewFootprint(columns: presentation.size.cols, rows: presentation.size.rows),
        structureKey: JSONText(presentation.key), excerpt: excerpt, view: view)
}

private func piOverviewMessage(_ state: PiState, executionID: JSONText?, status: PublicExecution.Status?) -> (id: JSONText, text: JSONText)? {
    let completed = Set(state.executions.filter { $0.status == .completed }.map(\.executionID))
    let live = status == .running || status == .waitingForUser
    for message in state.messages.reversed() where message.role == "assistant" {
        let current = message.executionID == executionID
        let complete = message.status == "complete"
        guard complete || (current && live) else { continue }
        let answer = complete ? piTrim(message.text) : JSONText("")
        let reasoning = completed.contains(message.executionID) || (current && live) ? message.thinking.map(piTrim) : nil
        let text = answer.codeUnits.isEmpty ? reasoning : answer
        if let text, !text.codeUnits.isEmpty {
            return (id: piKey([message.executionID, message.role, message.id, answer.codeUnits.isEmpty ? "reasoning" : "text"]), text: text)
        }
    }
    return nil
}

func piCompactTokens(_ value: Double) -> String {
    if value < 1_000 { return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) }
    let scale: Double = value >= 1_000_000_000 ? 1_000_000_000 : value >= 1_000_000 ? 1_000_000 : 1_000
    let suffix = value >= 1_000_000_000 ? "B" : value >= 1_000_000 ? "M" : "K"
    return piFixedOne(value / scale) + suffix
}

/// ECMAScript toFixed(1) rounds the exact binary Double, choosing the larger
/// integer at a tie. printf uses a different conversion/rounding path (1.05 and
/// 1.15 expose it), and decimal multiplication can erase that binary remainder.
func piFixedOne(_ value: Double) -> String {
    let bits = value.bitPattern
    let significand = (bits & 0x000f_ffff_ffff_ffff) | (1 << 52)
    let exponent = Int((bits >> 52) & 0x7ff) - 1023 - 52
    let numerator = significand * 10
    // Pi token totals are sums of nonnegative safe integers, scaled by >=1,000.
    // Their compacted value lies in [1, 36_028_798], so these shifts fit UInt64.
    let rounded: UInt64
    if exponent >= 0 { rounded = numerator << exponent }
    else {
        let denominator: UInt64 = 1 << (-exponent)
        rounded = numerator / denominator + ((numerator % denominator) * 2 >= denominator ? 1 : 0)
    }
    return "\(rounded / 10).\(rounded % 10)"
}

func piMokuPresentation(_ state: PiState) -> HarnessMokuPresentation {
    let activity = state.executions.first { $0.executionID == state.latestExecutionID }?.status == .running
        ? state.latestExecutionID.flatMap { state.foregrounds[$0] } : nil
    var reply: HarnessMokuReply?
    for execution in state.executions.reversed() where execution.status == .completed {
        guard let message = state.messages.last(where: { $0.executionID == execution.executionID && $0.role == "assistant" && !piTrim($0.text).codeUnits.isEmpty }) else { continue }
        reply = HarnessMokuReply(id: piKey([execution.executionID, message.id]), executionID: execution.executionID,
            excerpt: piHead(piTrim(message.text), HarnessMokuPresentation.maximumReplyExcerptPoints),
            target: .object(["executionId": .string(execution.executionID), "messageId": .string(message.id)]))
        break
    }
    return HarnessMokuPresentation(activity: activity, reply: reply)
}

func piMokuAnchor(_ state: PiState, _ value: JSONValue?) -> JSONText? {
    guard let object = value?.objectValue,
          let executionID = piText(object["executionId"]),
          let messageID = piText(object["messageId"]) else { return nil }
    return state.messages.contains { $0.id == messageID && $0.executionID == executionID && $0.role == "assistant" } ? messageID : nil
}

struct PiOverviewCard: View {
    let input: HarnessThreadInput
    let projection: PiOverviewView
    let actions: HarnessThreadActions
    let openThread: () -> Void
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HarnessThreadCard(identity: identity, presentation: projection.presentation,
                status: threadCardStatus(input.thread.observation), emoji: nativeGeneratedThreadEmoji(metadata: input.thread.metadataState),
                harnessLogo: AnyView(PiLogo(size: 12)),
                onInterventionResponse: respond, onOpenThread: openThread)
                .environment(\.threadCardProviderColor, NativePalette.pair(0x6c5ce7, 0xb5a7ff).swiftUI)
                .environment(\.threadCardCloudPalette, PiLogo.threadCardCloudPalette)
            if let failure { PiFailure(message: failure) }
        }
    }
    private var identity: ThreadCardIdentityView {
        let execution = input.thread.observation.latestExecution
        return ThreadCardIdentityView(title: input.thread.title.string,
            harness: ThreadCardHarnessBrand(brandKey: "pi", label: "Pi Agent", logoSource: PiHarnessPlugin.logo),
            model: projection.model, effort: projection.effort,
            runtime: execution.map { ThreadCardRuntimeValue(startedAt: $0.startedAt, endedAt: $0.finishedAt) },
            steer: projection.steer?.string, excerpt: projection.excerpt.string, message: projection.message, initialResponse: projection.initialResponse, initialResponseContent: projection.initialResponseContent)
    }
    private func respond(_ response: ThreadCardInterventionResponse) async throws {
        failure = nil
        do {
            let execution = input.thread.observation.latestExecution
            guard execution?.status == .waitingForUser,
                  let interaction = execution?.interactions.first(where: { $0.id == projection.pendingInteractionID }),
                  interaction.actions.contains(where: { $0.id == response.actionId }) else { throw PluginContractError("Pi request is no longer available") }
            let answers = response.answers?.mapValues { answer -> HarnessResponseAnswer in
                switch answer { case .string(let value): .text(value); case .strings(let values): .multiple(values) }
            }
            try await actions.respond(HarnessRespondRequest(interactionID: interaction.id, actionID: response.actionId, answers: answers))
        } catch { failure = error.localizedDescription }
    }
}
