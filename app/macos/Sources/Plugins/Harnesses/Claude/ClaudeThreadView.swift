import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

public struct ClaudeThreadView: View {
    @Environment(\.threadAgentDetail) private var agentDetail
    let input: HarnessThreadInput
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    private var providedState: ClaudeState?
    @State private var stateCache = ClaudeStateCache()
    @State private var resolvedAnchor: (request: JSONText, anchor: JSONText)?
    public init(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext) {
        self.input = input; self.actions = actions; self.context = context; providedState = nil
    }
    init(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext, state: ClaudeState) {
        self.input = input; self.actions = actions; self.context = context; providedState = state
    }
    public var body: some View {
        switch providedState.map({ Result<ClaudeState,Error>.success($0) }) ?? stateCache.decode(input.thread.sessionState) {
        case .failure(let error):
            let failure = claudeFailurePresentation(input, decodeError: error)
            ClaudeFailure(message: failure.message, detail: failure.detail)
        case .success(let state):
            if case .row(let id) = context.content { row(id, state: state) }
            else { conversation(state) }
        }
    }
    private func conversation(_ state: ClaudeState) -> some View {
        var rows: [ThreadConversationRow] = []
        if !state.history.isEmpty { rows.append(ThreadConversationRow(id: "fork-history", createdAt: 0, history: true, node: AnyView(row("fork-history", state: state)))) }
        rows += state.turns.map { turn in
            ThreadConversationRow(id: turn.id, createdAt: turn.createdAt,
                execution: ThreadConversationExecution(id: turn.id, title: input.thread.executionTitles[turn.id]?.string, prompt: turn.visiblePrompts.first?.stringValue ?? "", answer: turn.raw["text"]?.stringValue ?? "", completedAt: turn.status == "completed" ? turn.finishedAt : nil),
                node: AnyView(row(turn.id, state: state)))
        }
        if !state.tasks.isEmpty { rows.append(ThreadConversationRow(id: "native-background-tasks", createdAt: input.thread.updatedAt, node: AnyView(ClaudeBackgroundTasks(tasks: state.tasks)))) }
        let anchor = claudeReplyAnchor(state, message: input.readingTarget?.message) ?? (resolvedAnchor?.request == input.readingTarget?.requestID ? resolvedAnchor?.anchor : nil)
        return ThreadConversation(threadId: input.thread.id, title: agentDetail ? input.thread.title.string : claudeDocumentTitle(input.thread, state: state), icon: claudeEmoji(input.thread), rows: rows,
            readingTarget: input.readingTarget.map { ThreadConversationReadingTarget(requestId: $0.requestID, mode: $0.mode == .current ? .current : .history, executionId: $0.executionID, anchorId: anchor, position: $0.position,
                follow: input.thread.observation.isExecutionActive && input.thread.observation.latestExecution?.executionID == $0.executionID, hasMessageTarget: $0.message != nil) },
            running: input.thread.observation.latestExecution?.status == .running,
            runningTurnId: runningID(state),
            activeExecutionId: input.thread.observation.isExecutionActive ? input.thread.observation.latestExecution?.executionID : nil,
            context: context,
            renderRow: context.content == .manifest ? { key in
                if key == "native-background-tasks" { return AnyView(ClaudeBackgroundTasks(tasks: state.tasks)) }
                return AnyView(ClaudeLazyRow(key: key, input: input, actions: actions, context: context, onAnchor: { request, anchor in resolvedAnchor = (request, anchor) }))
            } : nil)
    }
    @ViewBuilder private func row(_ key: JSONText, state: ClaudeState) -> some View {
        if key == "fork-history" {
            if case .main = context.presentation { ClaudeForkHistory(items: state.history, actions: actions, context: context) }
        } else if let turn = state.turns.first(where: { $0.id == key }), claudeVisible(key, context: context) {
            ClaudeTurnView(turn: turn, active: runningID(state) == key,
                waiting: input.thread.observation.latestExecution?.executionID == key && input.thread.observation.latestExecution?.status == .waitingForUser,
                publicInteractions: claudePublicInteractions(state, input.thread.observation), actions: actions, context: context)
        } else { ClaudeFailure(message: "历史执行不可用") }
    }
    private func runningID(_ state: ClaudeState) -> JSONText? {
        guard let execution = input.thread.observation.latestExecution, execution.status == .running else { return nil }
        return state.turns.last(where: { $0.id == execution.executionID && $0.status == "running" })?.id
    }
}
private struct ClaudeLazyRow: View {
    let key: JSONText
    let input: HarnessThreadInput
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    let onAnchor: (JSONText, JSONText) -> Void
    @State private var resource: HarnessContentResource?
    var body: some View {
        Group {
            if let resource {
                switch resource.state {
                case .loading: NativeThreadLoadingIndicator()
                case .error(let message): ClaudeFailure(message: message, retry: { try await resource.retry() })
                case .ready(let raw):
                    ThreadDeferredExecutionContent(raw: raw, rowKey: key, context: context) { value in
                        ClaudeLoadedRow(key: key, input: input, actions: actions, context: context, onAnchor: onAnchor, raw: value)
                    }
                }
            } else { NativeThreadLoadingIndicator() }
        }.task(id: key) { resource = context.contentResource(.row(key)) }
            .onDisappear { let old = resource; old?.beginRelease(); resource = nil; Task { await old?.release() } }
    }
}

private struct ClaudeLoadedRow: View {
    let key: JSONText
    let input: HarnessThreadInput
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    let onAnchor: (JSONText, JSONText) -> Void
    let raw: JSONValue
    @State private var stateCache = ClaudeStateCache()
    @ViewBuilder var body: some View {
        Group {
            if let thread = try? input.thread.replacingSessionState(raw) {
                switch stateCache.decode(raw) {
                case .success(let state):
                    let anchor = claudeReplyAnchor(state, message: input.readingTarget?.message)
                    ClaudeThreadView(input: HarnessThreadInput(thread: thread, readingTarget: input.readingTarget), actions: actions, context: context.row(key), state: state)
                        .task(id: Anchor(request: input.readingTarget?.requestID, anchor: anchor)) {
                            if let request = input.readingTarget?.requestID, let anchor { onAnchor(request, anchor) }
                        }
                case .failure(let error):
                    let failure = claudeFailurePresentation(HarnessThreadInput(thread: thread, readingTarget: input.readingTarget), decodeError: error)
                    ClaudeFailure(message: failure.message, detail: failure.detail)
                }
            } else { ClaudeFailure(message: "Claude sessionState 无效") }
        }.onDisappear { stateCache.clear() }
    }
    private struct Anchor: Hashable { let request: JSONText?; let anchor: JSONText? }
}
@MainActor func claudeVisible(_ id: JSONText, context: HarnessRenderContext) -> Bool {
    switch context.presentation { case .main(let excluded): !excluded.contains(id); case .execution(let execution): execution == id }
}
struct ClaudeTurnView: View {
    @Environment(\.threadAgentDetail) private var agentDetail
    @Environment(\.threadExecutionPresence) private var executionPresence
    @Environment(\.threadDetailVisibility) private var visibility
    let turn: ClaudeTurn
    let active: Bool
    let waiting: Bool
    let publicInteractions: [JSONText: PublicInteraction]
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    @Environment(\.locale) private var locale
    var body: some View {
        let usage = turn.raw["usage"]
        let inputs = [usage?["inputTokens"]?.numberValue, usage?["cachedTokens"]?.numberValue, usage?["cacheWriteTokens"]?.numberValue]
        ThreadDetailTurn(id: turn.id, author: turn.raw["author"], rows: rows,
            reasoningUsage: usage?["reasoningTokens"]?.numberValue.map { ThreadReasoningUsage(tokens: $0, scope: .reportedTurn) },
            createdAt: turn.createdAt, updatedAt: turn.finishedAt ?? turn.updatedAt,
            status: claudeLocalized(waiting ? "等待你的响应" : turn.raw["statusLabel"]?.stringValue ?? claudeStatus(turn.status), locale: locale),
            completedAt: turn.status == "completed" ? turn.finishedAt : nil,
            usage: AnyView(ThreadTokenUsage(input: inputs.allSatisfy { $0 != nil } ? inputs.compactMap { $0 }.reduce(0,+) : nil,
                output: usage?["outputTokens"]?.numberValue, cached: usage?["cachedTokens"]?.numberValue,
                cacheWrite: usage?["cacheWriteTokens"]?.numberValue, reasoning: usage?["reasoningTokens"]?.numberValue)), active: active, executionRunning: turn.status == "running" && !waiting)
            .nativeReadingExecutionReady(turn.id, settled: turn.status != "running")
    }
    private var rows: [ThreadDetailRow] {
        let timeline = claudeProjectTimeline(turn).filter { agentDetail ? claudeDetailIncludes($0) : $0.claudeKind != "plan" }, starts = claudeActivityRunStarts(turn)
        let final = waiting && turn.status == "running" ? nil : timeline.last(where: { $0.claudeKind == "assistant" && $0["status"]?.stringValue != "streaming" && (!agentDetail || $0["status"]?.stringValue != "failed") && !claudeTrim($0["content"]).isEmpty })?.claudeID("id")
        var rows: [ThreadDetailRow] = [], index = 0
        while index < timeline.count {
            let item = timeline[index]; index += 1
            if item.claudeKind == "assistant" && item["status"]?.stringValue == "streaming" { continue }
            if item.claudeKind == "usage" || item.claudeKind == "assistant" && claudeTrim(item["content"]).isEmpty { continue }
            if item.claudeKind == "user-message", turn.internalIndexes.contains(item["promptIndex"]?.intValue ?? -1) { continue }
            if item.claudeKind == "activity" {
                var activities = [item["activity"]!]
                while index < timeline.count, timeline[index].claudeKind == "activity", !starts.contains(timeline[index].claudeID("id")) {
                    activities.append(timeline[index]["activity"]!); index += 1
                }
                rows.append(ThreadDetailRow(id: item.claudeID("id"), kind: .work, node: AnyView(ClaudeActivities(activities: activities)), executionSummary: ThreadExecutionSummary(toolCalls: activities.filter { $0["toolName"] != nil }.count, hasContent: activities.contains { claudeActivityHasContent($0, presence: executionPresence) })))
            } else { rows.append(detail(item, final: item.claudeID("id") == final)) }
        }
        let kinds = Set(timeline.map(\.claudeKind))
        if !agentDetail {
            let referencedPrompts = Set(timeline.filter { $0.claudeKind == "user-message" }.compactMap { $0["promptIndex"]?.intValue })
            for (index, _) in turn.prompts.enumerated() where !referencedPrompts.contains(index) && !turn.internalIndexes.contains(index) {
                rows.append(detail(synthetic("prompt:\(index)", kind: "user-message", fields: ["promptIndex": .integer(index)]), final: false))
            }
        }
        func appendFallback(_ fallbackKinds: [String]) {
        for kind in fallbackKinds where !kinds.contains(kind) {
            if kind == "assistant" && turn.status == "running" { continue }
            let field = kind == "assistant" ? "text" : kind
            var fields: [String: JSONValue] = [:]
            if kind == "context-compaction" { guard turn.raw["compacted"] == .bool(true) else { continue } }
            else { guard kind == "reasoning" ? (!claudeTrim(turn.raw[field]).isEmpty || executionPresence.contains(turn.id, "reasoning")) : turn.raw[field]?.stringValue?.isEmpty == false else { continue }; fields[kind == "error" ? "message" : "content"] = turn.raw[field]; if kind == "assistant" { fields["status"] = .text(active ? "streaming" : "complete") } }
            let row = detail(synthetic(kind, kind: kind, fields: fields), final: kind == "assistant" && (!waiting || turn.status != "running"))
            rows.append(ThreadDetailRow(id: row.id, kind: row.kind, node: row.node, execution: kind == "reasoning" ? .member : nil, executionSummary: row.executionSummary, finalReply: row.finalReply))
        }
        }
        appendFallback(["reasoning","assistant"])
        let activityIDs = Set(timeline.filter { $0.claudeKind == "activity" }.map { $0["activity"]!.claudeID("id") })
        let remaining = turn.activities.filter { !activityIDs.contains($0.claudeID("id")) }
        if agentDetail {
            for activity in remaining {
                let row = detail(syntheticID(JSONText(codeUnits: Array("activity:".utf16) + activity.claudeID("id").codeUnits), kind: "activity", fields: ["activity": activity]), final: false)
                rows.append(ThreadDetailRow(id: row.id, kind: row.kind, node: row.node, execution: .member,
                    executionSummary: ThreadExecutionSummary(toolCalls: activity["toolName"] == nil ? 0 : 1, hasContent: claudeActivityHasContent(activity, presence: executionPresence))))
            }
        } else if !remaining.isEmpty {
            rows.append(ThreadDetailRow(id: synthetic("activities", kind: "activity").claudeID("id"), kind: .work,
                node: AnyView(ClaudeActivities(activities: remaining)), execution: .member,
                executionSummary: ThreadExecutionSummary(toolCalls: remaining.filter { $0["toolName"] != nil }.count, hasContent: remaining.contains { claudeActivityHasContent($0, presence: executionPresence) })))
        }
        for (kind, values) in [("interaction",turn.interactions),("notice",turn.notices.filter { !agentDetail || $0["level"]?.stringValue == "error" })] {
            let referenced = Set(timeline.filter { $0.claudeKind == kind }.map { $0[kind]!.claudeID("id") })
            for value in values where !referenced.contains(value.claudeID("id")) { rows.append(detail(syntheticID(JSONText(codeUnits: Array((kind + ":").utf16) + value.claudeID("id").codeUnits), kind: kind, fields: [kind:value]), final: false)) }
        }
        appendFallback(["error","review","context-compaction"])
        let interimReplies = Set(rows.filter { agentDetail && $0.kind == .work }.map(\.id))
        return bindThreadExecutionSource(rows: rows, source: agentDetail ? timeline : turn.timeline.filter { $0.claudeKind != "plan" }, id: { $0.claudeID("id") }, isExecution: { ["reasoning","activity"].contains($0.claudeKind) || $0.claudeKind == "assistant" && interimReplies.contains($0.claudeID("id")) })
    }
    private func synthetic(_ id: String, kind: String, fields: [String: JSONValue] = [:]) -> JSONValue {
        syntheticID(JSONText(id), kind: kind, fields: fields)
    }
    private func syntheticID(_ id: JSONText, kind: String, fields: [String: JSONValue] = [:]) -> JSONValue {
        claudeObject(fields.merging(["id": .string(JSONText(codeUnits: turn.id.codeUnits + Array(":unreferenced:".utf16) + id.codeUnits)), "kind": .text(kind), "createdAt": .number(turn.createdAt)], uniquingKeysWith: { _, new in new }))
    }
    private func detail(_ item: JSONValue, final: Bool) -> ThreadDetailRow {
        ThreadDetailRow(id: item.claudeID("id"), kind: claudeRowKind(item, final: final, agentDetail: agentDetail, executionActive: turn.status == "running", messageAnchorID: visibility.messageAnchorID),
            node: AnyView(ClaudeTimelineEntry(item: item, turn: turn, active: active, publicInteractions: publicInteractions, actions: actions, context: context)),
            executionSummary: claudeExecutionSummary(item, presence: executionPresence), finalReply: final && item.claudeKind == "assistant")
    }
}
// Shared by current turns, legacy fallbacks and inherited transcripts. Keep
// this at the reader boundary; notices remain available to other consumers.
func claudeDetailIncludes(_ item: JSONValue) -> Bool {
    switch item.claudeKind {
    case "assistant", "reasoning", "activity", "interaction", "review", "context-compaction", "error": true
    case "notice": item["notice"]?["level"]?.stringValue == "error"
    default: false
    }
}
func claudeRowKind(_ item: JSONValue, final: Bool, agentDetail: Bool = true, executionActive: Bool = false, messageAnchorID: JSONText? = nil) -> ThreadDetailRow.Kind {
    switch item.claudeKind {
    case "user-message": .user
    case "assistant": agentDetail && item["status"]?.stringValue == "failed" ? .attention : final || agentDetail && (executionActive || item.claudeID("id") == messageAnchorID) ? .content : .work
    case "activity": .work
    case "interaction": item["interaction"]?["status"]?.stringValue == "pending" ? .attention : .work
    case "error": .attention
    case "notice": !agentDetail && item["notice"]?["level"]?.stringValue == "info" ? .work : .attention
    case "review": .content
    default: .work
    }
}

/// Cache the owning Harness decode by its immutable private payload. UI-only updates
/// do not repeatedly traverse a long transcript; streamed changes still validate.
@MainActor private final class ClaudeStateCache {
    private var raw: JSONValue?
    private var result: Result<ClaudeState,Error>?
    func clear() { raw = nil; result = nil }
    func decode(_ value: JSONValue) -> Result<ClaudeState,Error> {
        if raw == value, let result { return result }
        let next = Result { try ClaudeState(value) }
        if case .failure(let error) = next {
            ClaudeStateLog.decode.error("Claude state decode failed: \(claudeRedacted(error.localizedDescription), privacy: .public)")
        }
        raw = value; result = next; return next
    }
}
