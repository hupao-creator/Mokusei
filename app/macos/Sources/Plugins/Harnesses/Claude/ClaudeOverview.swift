import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

public struct ClaudeOverviewView: Hashable, Sendable {
    public let identity: ThreadCardIdentityView
    public let presentation: ThreadCardPresentation
    public let status: String
    public let statusLabel: String?
    public let summary: String
    public let pendingPublicInteraction: PublicInteraction?
    let workflow: ClaudeWorkflow?
}
struct ClaudeWorkflow: Hashable, Sendable {
    let phases: [String]
    let total: Int
    let agents: [JSONValue]
}
public func projectClaudeOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewProjection<ClaudeOverviewView> {
    guard input.thread.harnessID == "claude" else { throw claudeInvalid("Harness") }
    let state = try ClaudeState(input.thread.sessionState), turn = state.turns.last
    let pending = turn?.interactions.first { $0["status"]?.stringValue == "pending" }
    let publicInteraction = pending.flatMap { claudePublicInteractions(state, input.thread.observation)[$0.claudeID("id")] }
    let agent = claudeOverviewAgentMessage(state)
    let message = agent ?? claudeOverviewFallback(state, fallback: input.thread.title), summary = claudeBoundedText(message.text, 600)
    let card = claudeCardProjection(turn: turn, tasks: state.tasks, pending: pending, publicInteraction: publicInteraction)
    let presentation = try composeThreadCard(card.0, git: input.git, layoutContext: ThreadCardLayoutContext(availableCols: availableColumns))
    let cwd = input.thread.cwd.string
    let visibleCwd = cwd.isEmpty || claudeTemporaryWorkspace(cwd) ? nil : cwd
    let prompts = turn?.visiblePrompts ?? []
    let hasInteraction: Bool
    if case .standard(_, let extensions) = card.0 {
        hasInteraction = extensions.contains { $0.kind == .intervention }
    } else { hasInteraction = false }
    let initial = state.initialResponseScope && agent == nil && input.thread.moku != true
        ? threadCardInitialResponse(pendingInput: input.thread.pendingInput, observation: input.thread.observation,
                                    hasVisibleInteraction: hasInteraction) : nil
    let identity = ThreadCardIdentityView(title: input.thread.title.string,
        harness: ThreadCardHarnessBrand(brandKey: "claude", label: "Claude", logoSource: ""),
        model: state.raw["runtime"]?["model"]?.stringValue ?? input.thread.settings["model"]?.stringValue ?? "Claude",
        effort: input.thread.settings["thinking"].map(claudeThinkingLabel) ?? "未选择",
        runtime: input.thread.observation.latestExecution.map { ThreadCardRuntimeValue(startedAt: $0.startedAt, endedAt: $0.finishedAt) },
        cwd: visibleCwd, usesWorktree: input.thread.worktree != nil && input.thread.worktree != .null,
        steer: prompts.count > 1 ? prompts.last?.stringValue : nil,
        excerpt: initial == nil ? summary.string : "", message: initial == nil ? message.display : nil,
        initialResponse: initial, initialResponseContent: state.initialResponseScope && agent != nil && input.thread.moku != true)
    let view = ClaudeOverviewView(identity: identity, presentation: presentation,
        status: pending != nil ? "waiting" : input.thread.observation.isExecutionActive || turn?.status == "running" ? "running" : turn?.status ?? "idle",
        statusLabel: turn?.raw["statusLabel"]?.stringValue, summary: summary.string,
        pendingPublicInteraction: publicInteraction, workflow: card.1)
    return HarnessOverviewProjection(footprint: HarnessOverviewFootprint(columns: presentation.size.cols, rows: presentation.size.rows), structureKey: JSONText(presentation.key), excerpt: summary, view: view)
}
public func claudeExecutionTokenUsage(thread: HarnessThread, executionID: JSONText) throws -> HarnessExecutionTokenUsage? {
    let state = try ClaudeState(thread.sessionState)
    guard let usage = state.turns.last(where: { $0.id == executionID })?.raw["usage"], let total = claudeUsageTotal(usage) else { return nil }
    return HarnessExecutionTokenUsage(value: JSONText(claudeTokens(total)), count: total, suffix: "tokens")
}
func claudeUsageTotal(_ usage: JSONValue?) -> Double? {
    if let total = usage?["totalTokens"]?.numberValue { return total }
    let values = ["inputTokens","cachedTokens","cacheWriteTokens","outputTokens"].compactMap { usage?[$0]?.numberValue }
    return values.isEmpty ? nil : values.reduce(0,+)
}
func claudeTokens(_ value: Double) -> String {
    if value < 1_000 { return claudeJSNumber(value) }
    let scale: (Double,String) = value >= 1_000_000_000 ? (1_000_000_000,"B") : value >= 1_000_000 ? (1_000_000,"M") : (1_000,"K")
    return claudeFixedOne(value / scale.0) + scale.1
}
/// Round the exact binary Double with ECMAScript's ties-toward-positive rule.
private func claudeFixedOne(_ value: Double) -> String {
    if value >= 1e21 { return claudeJSNumber(value) }
    if value >= 1e18 { return String(format:"%.0f",locale:Locale(identifier:"en_US_POSIX"),value) + ".0" }
    let bits = value.bitPattern
    let significand = (bits & 0x000f_ffff_ffff_ffff) | (1 << 52)
    let exponent = Int((bits >> 52) & 0x7ff) - 1023 - 52
    let numerator = significand * 10
    let rounded: UInt64
    if exponent >= 0 { rounded = numerator << exponent }
    else { let denominator: UInt64 = 1 << (-exponent); rounded = numerator / denominator + ((numerator % denominator) * 2 >= denominator ? 1 : 0) }
    return "\(rounded / 10).\(rounded % 10)"
}
func claudeJSNumber(_ value: Double) -> String {
    if value == 0 { return "0" }
    if value < 0 { return "-" + claudeJSNumber(-value) }
    var string = String(value)
    if let index = string.firstIndex(of:"e"), let exponent = Int(string[string.index(after:index)...]) {
        var mantissa = String(string[..<index]); if mantissa.hasSuffix(".0") { mantissa.removeLast(2) }
        if value >= 0.000001 && value < 1e21 {
            let parts = mantissa.split(separator:".",omittingEmptySubsequences:false), digits = parts.joined(), place = parts[0].count + exponent
            if place <= 0 { return "0." + String(repeating:"0",count:-place) + digits }
            if place >= digits.count { return digits + String(repeating:"0",count:place - digits.count) }
            return String(digits.prefix(place)) + "." + String(digits.dropFirst(place))
        }
        return mantissa + "e" + (exponent >= 0 ? "+" : "") + String(exponent)
    }
    if string.hasSuffix(".0") { string.removeLast(2) }; return string
}
private struct ClaudeOverviewMessage {
    let id: JSONText
    let text: JSONText
    var display: ThreadCardMessage { ThreadCardMessage(id: id, text: text.string) }
}
private func claudeOverviewAgentMessage(_ state: ClaudeState) -> ClaudeOverviewMessage? {
    for turn in state.turns.reversed() {
        let unfinished = Set(turn.timeline.filter { $0.claudeKind == "assistant" && $0["messageId"] != nil && $0["status"]?.stringValue != "complete" }.map { $0.claudeID("messageId") })
        if let latest = turn.timeline.last(where: {
            ($0.claudeKind == "assistant" && $0["status"]?.stringValue == "complete" && !unfinished.contains($0.claudeID("messageId")) || $0.claudeKind == "reasoning" && ["running","completed"].contains(turn.status)) && !claudeTrim($0["content"]).isEmpty
        }) {
            let nativeID = latest.claudeKind == "assistant" ? latest["messageId"] : nil
            let content = nativeID.map { id in JSONText(codeUnits: turn.timeline.filter { $0.claudeKind == "assistant" && $0["messageId"] == id }.flatMap { $0.claudeID("content").codeUnits }) } ?? latest.claudeID("content")
            return ClaudeOverviewMessage(id: JSONText(claudeJSONString(.array([.string(turn.id), .text(latest.claudeKind), nativeID ?? latest["id"]!]))), text: claudeTrimText(content))
        }
        if turn.status == "completed", !turn.timeline.contains(where: { ["assistant","reasoning"].contains($0.claudeKind) }) {
            let text = claudeTrimText(turn.raw.claudeID(turn.raw.claudeID("text").codeUnits.isEmpty ? "reasoning" : "text"))
            if !text.codeUnits.isEmpty { return ClaudeOverviewMessage(id: JSONText(claudeJSONString(.array([.string(turn.id),.text("answer")]))), text: text) }
        }
    }
    return nil
}
private func claudeOverviewFallback(_ state: ClaudeState, fallback: JSONText) -> ClaudeOverviewMessage {
    let turn = state.turns.last
    let history = state.history.reversed().compactMap { item -> JSONValue? in
        let value = ["user-message","diff","review"].contains(item.claudeKind) || item.claudeKind == "assistant" && item["status"]?.stringValue == "complete" ? item["content"] : item.claudeKind == "error" ? item["message"] : item.claudeKind == "notice" ? item["notice"]?["message"] : nil
        return claudeTrim(value).isEmpty ? nil : value
    }.first
    let candidates: [(String,JSONValue?)] = [("history",history),("error",turn?.raw["error"]),("prompt:\(turn?.prompts.count ?? 0)",turn?.visiblePrompts.last),("status",turn?.raw["statusLabel"]),("notice",state.raw["nativeNotifications"]?.arrayValue?.last?["summary"]),("title",.string(fallback))]
    let candidate = candidates.first { !claudeTrim($0.1).isEmpty } ?? ("title",.string(fallback))
    let content: JSONText = if case .string(let text)? = candidate.1 { claudeTrimText(text) } else { "" }
    return ClaudeOverviewMessage(id: JSONText(claudeJSONString(.array([turn.map { .string($0.id) } ?? .null,.text(candidate.0)]))), text: content)
}
private func claudeCardProjection(turn: ClaudeTurn?, tasks: [JSONValue], pending: JSONValue?, publicInteraction: PublicInteraction?) -> (ThreadCardProjection, ClaudeWorkflow?) {
    let activities = turn?.status == "running" ? turn?.activities ?? [] : []
    var excluded = Set(["todowrite","taskcreate","taskupdate","update_plan"])
    for interaction in turn?.interactions ?? [] where interaction["status"]?.stringValue == "pending" {
        excluded.insert((interaction["toolName"]?.stringValue ?? "").lowercased()); excluded.insert((interaction["title"]?.stringValue ?? "").lowercased())
    }
    let tools = (turn?.activities ?? []).filter { ["command","file","search","tool"].contains($0.claudeKind) && !claudeTrim($0["label"]).isEmpty && !excluded.contains(claudeTrim($0["label"]).lowercased()) }.suffix(3).map { activity in
        let label = (activity["label"]?.stringValue ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let kind = ThreadCardIdentityToolKind(rawValue: activity.claudeKind) ?? .tool
        let subject = kind == .command && (label.contains(" ") || label.hasPrefix("/")) ? "Shell" : kind == .file && (label.contains("/") || label.contains("\\")) ? "File" : nil
        return ThreadCardIdentityTool(kind: kind, name: subject ?? claudeBounded(label,48), summary: subject == nil ? nil : claudeBounded(label,120), status: ThreadCardActivityStatus(rawValue: activity["status"]?.stringValue ?? "") ?? .completed)
    }
    let identity = ThreadCardIdentityProjection(recentTools: tools.isEmpty ? nil : tools, latestTool: tools.last,
        usage: claudeUsageTotal(turn?.raw["usage"]).map { ThreadCardIdentityUsage(parts: [ThreadCardIdentityUsagePart(suffix: "tokens", description: "输入与输出 token 合计，按 Harness 当前上报的统计范围显示", id: "total", value: claudeTokens($0), numericValue: $0)]) })
    let workflow = activities.first { $0.claudeKind == "agent" && $0["label"]?.stringValue == "Workflow" }
    let agents = activities.filter { $0 != workflow && ["agent","subagent","task"].contains($0.claudeKind) }
    if pending == nil, let workflow, workflow["status"]?.stringValue == "running" || agents.contains(where: { $0["status"]?.stringValue == "running" }) {
        let detail = workflow["detail"]?.stringValue.flatMap { try? JSONValue(data: Data($0.utf8)) }
        let phases = (detail?["phases"]?.arrayValue ?? []).compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let total = max(phases.count, detail?["total"]?.intValue ?? phases.count)
        return (.slots(identity: identity, layout: ThreadCardSlotLayout(size: .init(cols: 2, rows: 2), identitySize: .init(cols: 1, rows: 1), slots: [ThreadCardSlot(id: "phases", col: 1, row: 0, size: .init(cols: 1, rows: 1)),ThreadCardSlot(id: "agents", col: 0, row: 1, size: .init(cols: 2, rows: 1))])), ClaudeWorkflow(phases: phases, total: total, agents: agents))
    }
    var extensions: [ThreadCardExtensionProjection] = []
    if let turn, turn.status == "running", turn.plan.contains(where: { $0["status"]?.stringValue != "completed" }) { extensions.append(.todo(steps: turn.plan.map { ThreadCardPlanStep(step: $0["step"]?.stringValue ?? "", status: ThreadCardPlanStatus(rawValue: $0["status"]?.stringValue ?? "") ?? .pending) })) }
    if let pending {
        let question = pending.claudeKind == "question" && publicInteraction?.questions.isEmpty == false && publicInteraction!.questions.allSatisfy { !$0.secret }
        let submit = question ? publicInteraction?.actions.first { $0.intent == .submit } : nil
        let detail = pending.claudeKind == "permission" ? ["command","file_path","notebook_path","path","url","pattern","query","prompt"].compactMap { pending["input"]?[$0]?.stringValue }.map { claudeBounded($0, 1_000) }.joined(separator: " · ") : ""
        extensions.append(.intervention(ThreadCardIntervention(id: publicInteraction?.id ?? pending.claudeID("id"), title: pending["title"]?.stringValue ?? "", detail: detail.isEmpty ? pending["description"]?.stringValue : claudeBounded(detail,2_000),
            actions: (publicInteraction?.actions ?? []).filter { pending.claudeKind == "permission" ? [.allow,.deny,.cancel].contains($0.intent) : submit != nil && [.submit,.cancel].contains($0.intent) }.map { ThreadCardDecisionAction(id: $0.id, label: $0.label.string) },
            questions: question && submit != nil ? publicInteraction!.questions.map { question in ThreadCardQuestion(id: question.id, prompt: question.prompt.string, header: question.header?.string, multiple: question.multiple, allowOther: question.allowOther, secret: question.secret, options: question.options.map { ThreadCardQuestionOption(id: $0.value, label: $0.label.string, description: $0.description?.string, value: $0.value) }) } : [], submitActionId: submit?.id)))
    }
    var derived: [ThreadCardDerivedRow] = []
    func set(_ row: ThreadCardDerivedRow) { if let index = derived.firstIndex(where: { $0.id == row.id }) { derived[index] = row } else { derived.append(row) } }
    for activity in activities where activity["status"]?.stringValue == "running" && ["agent","subagent"].contains(activity.claudeKind) { set(ThreadCardDerivedRow(id: activity.claudeID("id"), label: activity["label"]?.stringValue ?? "", status: .running, kind: .agent)) }
    for task in tasks {
        let value = claudeTrim(task["status"]).lowercased(), type = task["type"]?.stringValue ?? ""
        let status: ThreadCardActivityStatus = ["completed","complete","done","success"].contains(value) ? .completed : ["failed","error"].contains(value) ? .failed : ["cancelled","canceled","killed"].contains(value) ? .cancelled : .running
        set(ThreadCardDerivedRow(id: task.claudeID("id"), label: task["description"]?.stringValue ?? "", status: status, kind: type == "local_bash" ? .shell : ["local_agent","remote_agent","in_process_teammate"].contains(type) ? .agent : .task))
    }
    let activityTasks = activities.filter { $0.claudeKind == "task" }
    if activityTasks.contains(where: { $0["status"]?.stringValue == "running" }) { for task in activityTasks { set(ThreadCardDerivedRow(id: task.claudeID("id"), label: task["label"]?.stringValue ?? "", status: ThreadCardActivityStatus(rawValue: task["status"]?.stringValue ?? "") ?? .running, kind: .agent)) } }
    if !derived.isEmpty { extensions.append(.derived(rows: derived)) }
    return (.standard(identity: identity, extensions: extensions), nil)
}
public struct ClaudeOverviewCard: View {
    let input: HarnessThreadInput
    let projection: ClaudeOverviewView
    let actions: HarnessThreadActions
    let openThread: () -> Void
    @Environment(\.locale) private var locale
    public init(input: HarnessThreadInput, projection: ClaudeOverviewView, actions: HarnessThreadActions, openThread: @escaping () -> Void) { self.input = input; self.projection = projection; self.actions = actions; self.openThread = openThread }
    public var body: some View {
        HarnessThreadCard(identity: projection.identity, presentation: projection.presentation, onRespond: { response in
            let state = try ClaudeState(input.thread.sessionState)
            guard let interaction = projection.pendingPublicInteraction,
                  claudePublicInteractions(state, input.thread.observation).values.contains(interaction), interaction.actions.contains(where: { $0.id == response.actionId }) else { throw PluginContractError(claudeLocalized("该请求已失效。", locale: locale)) }
            try await actions.respond(HarnessRespondRequest(interactionID: interaction.id, actionID: response.actionId, answers: response.answers?.mapValues { value in
                switch value { case .string(let text): .text(text); case .strings(let texts): .multiple(texts) }
            }))
        }, onOpen: openThread, slots: workflowSlots,
            interventionActionLabel: { action in
                guard let publicAction = projection.pendingPublicInteraction?.actions.first(where: { $0.id == action.id }) else { return action.label }
                return claudeLocalized(claudeActionLabel(publicAction, kind: "question"), locale: locale)
            }, status: threadCardStatus(input.thread.observation), emoji: claudeEmoji(input.thread), harnessLogo: AnyView(ClaudeLogo(size: 12)))
            .environment(\.threadCardProviderColor, NativePalette.pair(0xd97757,0xe5a184).swiftUI)
            .environment(\.threadCardCloudPalette, ClaudeLogo.threadCardCloudPalette)
    }
    private var workflowSlots: [String: AnyView] {
        guard let workflow = projection.workflow else { return [:] }
        return ["phases": AnyView(ClaudeWorkflowPhases(workflow: workflow)), "agents": AnyView(ClaudeWorkflowAgents(workflow: workflow))]
    }
}
private struct ClaudeWorkflowPhases: View {
    let workflow: ClaudeWorkflow
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) { VStack(alignment: .leading) { Text("PHASED EXECUTION").font(NativeTypography.mono(size: 9)); Text("Dynamic Workflow").font(NativeTypography.inter(size: 15,weight: 600)) }; Spacer(); Text("\(workflow.total)").font(NativeTypography.mono(size: 24)) }
            ForEach(Array(workflow.phases.prefix(4).enumerated()), id: \.offset) { index, phase in HStack { Text(String(format: "%02d",index + 1)).font(NativeTypography.mono(size: 10)); Text(phase).lineLimit(1).help(phase) } }
            if workflow.total > 4 { Text("+\(workflow.total - 4)") }
        }.font(NativeTypography.inter(size: 11)).padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(NativePalette.thread.surface.swiftUI)
    }
}
private struct ClaudeWorkflowAgents: View {
    let workflow: ClaudeWorkflow
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("AGENT EXECUTION"); Spacer(); Text("\(workflow.agents.filter { $0["status"]?.stringValue == "completed" }.count)/\(workflow.agents.count) \(claudeLocalized("完成", locale: locale))") }.font(NativeTypography.mono(size: 9))
            ForEach(Array(workflow.agents.prefix(6).enumerated()), id: \.offset) { _, agent in HStack { ClaudeActivityGlyph(status: agent["status"]?.stringValue ?? ""); Text(agent["label"]?.stringValue ?? "").lineLimit(1); Spacer(); Text(claudeLocalized(claudeStatus(agent["status"]?.stringValue ?? ""), locale: locale)) } }
            if workflow.agents.count > 6 { Text("+\(workflow.agents.count - 6)") }
        }.font(NativeTypography.inter(size: 11)).padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(NativePalette.thread.surface.swiftUI)
    }
}

private func claudeTemporaryWorkspace(_ value: String) -> Bool {
    MokuseiWorkspacePath.isTemporary(value)
}
