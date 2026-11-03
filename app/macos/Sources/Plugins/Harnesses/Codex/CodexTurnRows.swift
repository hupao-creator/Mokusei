import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct CodexTurnRows: View {
    @Environment(\.threadAgentDetail) private var agentDetail
    let turn: CodexTurn
    let active: Bool
    let state: CodexState
    let observation: JSONValue
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    @Environment(\.locale) private var locale
    @Environment(\.threadExecutionPresence) private var executionPresence
    @State private var busyInteractionID: JSONText?
    @State private var actionError: (id: JSONText, message: String)?

    var body: some View {
        ThreadDetailTurn(id: turn.executionId, author: author, rows: rows,
            reasoningUsage: turn.usage?["reasoningTokens"]?.numberValue.map { ThreadReasoningUsage(tokens: $0, scope: .lastCall) },
            createdAt: turn.createdAt, updatedAt: turn.finishedAt ?? turn.updatedAt,
            status: statusLabel, completedAt: turn.status == "completed" ? turn.finishedAt : nil,
            usage: AnyView(ThreadTokenUsage(input: turn.usage?["inputTokens"]?.numberValue,
                output: turn.usage?["outputTokens"]?.numberValue, cached: turn.usage?["cachedInputTokens"]?.numberValue,
                reasoning: turn.usage?["reasoningTokens"]?.numberValue)), active: active)
            .onChange(of: turn.interactions) { _, interactions in
                if let busyInteractionID, !interactions.contains(where: { $0.id == busyInteractionID && $0.status == "pending" && $0.blocksTurn }) {
                    self.busyInteractionID = nil
                }
            }
    }

    private var author: JSONValue {
        var value = turn.author?.objectValue ?? [:]
        if let runtimeModel = turn.runtimeModel, !codexTrim(.text(runtimeModel)).codeUnits.isEmpty { value["model"] = .string(codexTrim(.text(runtimeModel))) }
        return .object(value)
    }

    private var statusLabel: String {
        switch turn.status {
        case "waiting-input": codexLocalized("等待输入", locale: locale)
        case "completed": codexLocalized("已完成", locale: locale)
        case "failed": codexLocalized("失败", locale: locale)
        case "interrupted": codexLocalized("已取消", locale: locale)
        default: turn.statusLabel.flatMap { $0.isEmpty ? nil : $0 }.map { $0 == "运行中" ? codexLocalized($0, locale: locale) : $0 } ?? codexLocalized("运行中", locale: locale)
        }
    }

    private var publicInteractions: [JSONText: JSONValue] {
        codexPublicInteractionsByNativeId(state: state.raw, observation: observation)
    }

    private var rows: [ThreadDetailRow] {
        let messages = firstByID(turn.messages)
        let notices = Dictionary(turn.notices.map { ($0.codexIdentity("id"), $0) }, uniquingKeysWith: { first, _ in first })
        // Reader policy only. Error severity is an explicit exception to the
        // allowlist, including rejected follow-ups after a completed execution.
        var activityIDs = Set<JSONText>()
        var noticeIDs = Set<JSONText>()
        let timeline = turn.timeline.filter {
            // Native references may be repeated during history reconciliation.
            // Deduplicate identities, never equal labels or output text.
            if $0.kind == "activity", !activityIDs.insert($0.raw.codexIdentity("activityId")).inserted { return false }
            if $0.kind == "notice", !noticeIDs.insert($0.raw.codexIdentity("noticeId")).inserted { return false }
            if !agentDetail { return $0.kind != "plan" }
            return switch $0.kind {
            case "assistant", "reasoning", "activity", "interaction", "review", "context-compaction", "error": true
            case "notice": notices[$0.raw.codexIdentity("noticeId")]?["level"]?.stringValue == "error"
            default: false
            }
        }
        let interactions = firstByID(turn.interactions)
        let activities = firstByID(turn.activities)
        let lastAssistant = timeline.lastIndex(where: { $0.kind == "assistant" && $0.status != "streaming" && !codexTrim($0.raw["content"]).codeUnits.isEmpty })
        var result: [ThreadDetailRow] = []
        var index = 0
        while index < timeline.count {
            let item = timeline[index]
            if item.kind == "activity" {
                var group: [CodexActivity] = []
                var next = index
                while next < timeline.count && timeline[next].kind == "activity" {
                    if let activity = activities[timeline[next].raw.codexIdentity("activityId")] {
                        // Keep failed records independent of hidden successful work.
                        if agentDetail, let first = group.first,
                           (first.status == "failed") != (activity.status == "failed") { break }
                        group.append(activity)
                    }
                    next += 1
                }
                if !group.isEmpty {
                    let count = Set(group.filter { $0.toolCall || ["command", "file", "tool", "search"].contains($0.kind) }.map(\.id)).count
                    let groupID = JSONText(codeUnits: turn.executionId.codeUnits + Array(":".utf16) + item.id.codeUnits + Array(":tools".utf16))
                    result.append(ThreadDetailRow(id: item.id, kind: agentDetail && group.contains { $0.status == "failed" } ? .attention : .work,
                        node: AnyView(CodexToolActivityGroup(activities: group, groupID: groupID)),
                        executionSummary: ThreadExecutionSummary(toolCalls: count)))
                }
                index = next; continue
            }
            if let node = node(item, messages: messages, interactions: interactions, notices: notices) {
                let kind: ThreadDetailRow.Kind
                let failure = item.kind == "error" ||
                    (item.kind == "notice" && notices[item.raw.codexIdentity("noticeId")]?["level"]?.stringValue == "error") ||
                    (agentDetail && item.kind == "assistant" && item.status == "failed")
                if item.kind == "user-message" { kind = .user }
                else if (failure && (agentDetail || turn.status != "completed")) ||
                    (item.kind == "interaction" && interactions[item.raw.codexIdentity("interactionId")]?.status == "pending") { kind = .attention }
                else if item.kind == "review" || (item.kind == "assistant" && turn.status != "waiting-input" && index == lastAssistant) { kind = .content }
                else { kind = .work }
                result.append(ThreadDetailRow(id: item.id, kind: kind, node: node,
                    executionSummary: item.kind == "reasoning" && (!codexTrim(item.raw["content"]).codeUnits.isEmpty || executionPresence.contains(item.id, "content")) ? ThreadExecutionSummary(reasoningSegments: 1) : nil,
                    finalReply: item.kind == "assistant" && index == lastAssistant))
            }
            index += 1
        }
        // Older snapshots can retain diagnostics without their timeline marker.
        let referencedNotices = Set(timeline.filter { $0.kind == "notice" }.map { $0.raw.codexIdentity("noticeId") })
        for notice in turn.notices where agentDetail && notice["level"]?.stringValue == "error" && !referencedNotices.contains(notice.codexIdentity("id")) {
            result.append(ThreadDetailRow(id: JSONText(codeUnits: turn.executionId.codeUnits + Array(":notice:".utf16) + notice.codexIdentity("id").codeUnits),
                kind: .attention, node: AnyView(CodexContentFailure(message: notice["message"]?.stringValue ?? "", translatesMessage: false))))
        }
        let referencedActivities = Set(timeline.filter { $0.kind == "activity" }.map { $0.raw.codexIdentity("activityId") })
        for activity in turn.activities where agentDetail && !referencedActivities.contains(activity.id) {
            result.append(ThreadDetailRow(id: JSONText(codeUnits: turn.executionId.codeUnits + Array(":activity:".utf16) + activity.id.codeUnits),
                kind: activity.status == "failed" ? .attention : .work,
                node: AnyView(CodexActivityRow(activity: activity)), execution: .member,
                executionSummary: ThreadExecutionSummary(toolCalls: activity.toolCall || ["command", "file", "tool", "search"].contains(activity.kind) ? 1 : 0)))
        }
        if agentDetail, !timeline.contains(where: { $0.kind == "error" }), let error = turn.error, !error.isEmpty {
            result.append(ThreadDetailRow(id: JSONText(codeUnits: turn.executionId.codeUnits + Array(":error".utf16)),
                kind: .attention, node: AnyView(CodexContentFailure(message: error, translatesMessage: false))))
        }
        return bindThreadExecutionSource(rows: result, source: timeline, id: { $0.id }, isExecution: { $0.kind == "reasoning" || $0.kind == "activity" })
    }

    private func node(_ item: CodexTimelineItem, messages: [JSONText: CodexMessage], interactions: [JSONText: CodexInteraction], notices: [JSONText: JSONValue]) -> AnyView? {
        switch item.kind {
        case "user-message":
            guard let message = messages[item.raw.codexIdentity("messageId")], !message.isInternal else { return nil }
            return AnyView(CodexUserMessage(message: message, actions: actions, context: context))
        case "assistant":
            // A message can settle before its execution; keep completed replies
            // readable while the Harness continues with tools or another reply.
            guard item.status != "streaming", !codexTrim(item.raw["content"]).codeUnits.isEmpty else { return nil }
            return AnyView(ThreadMessage(id: item.id, author: .assistant, content: item.content, openExternal: openExternal, resolveMedia: context.resolveMedia))
        case "reasoning":
            return AnyView(ThreadSurfaceDisclosure(label: codexLocalized("思考过程", locale: locale)) {
                NativeMarkdownView(text: item.content, streaming: active && turn.timeline.last?.id == item.id,
                    muted: true, openExternal: openExternal, resolveMedia: context.resolveMedia)
            })
        case "interaction":
            guard let interaction = interactions[item.raw.codexIdentity("interactionId")] else { return nil }
            return AnyView(CodexInteractionPanel(interaction: interaction, publicInteraction: publicInteractions[interaction.id],
                busy: busyInteractionID == interaction.id, error: actionError?.id == interaction.id ? actionError?.message : nil,
                respond: { actionID, answers in respond(interaction: interaction, actionID: actionID, answers: answers) }))
        case "notice":
            guard let notice = notices[item.raw.codexIdentity("noticeId")] else { return nil }
            return agentDetail ? AnyView(CodexContentFailure(message: notice["message"]?.stringValue ?? "", translatesMessage: false)) : AnyView(CodexNotice(message: notice["message"]?.stringValue ?? ""))
        case "review":
            guard let review = turn.review, !review.isEmpty else { return nil }
            return AnyView(CodexReviewDisclosure {
                NativeMarkdownView(text: review, openExternal: openExternal, resolveMedia: context.resolveMedia)
            })
        case "context-compaction": return AnyView(CodexNotice(message: codexLocalized("上下文已压缩", locale: locale)))
        case "error":
            guard let error = turn.error, !error.isEmpty else { return nil }
            return AnyView(CodexContentFailure(message: error, translatesMessage: false))
        default:
            // The native diff marker has no reader node in the existing Codex
            // renderer. Preserving that is intentional; it is not a Git diff UI.
            return nil
        }
    }

    private func openExternal(_ url: URL) { Task { try? await actions.openExternal(JSONText(url.absoluteString)) } }

    private func respond(interaction: CodexInteraction, actionID: JSONText, answers: JSONValue?) {
        let matches = state.turns.flatMap(\.interactions).filter { $0.id == interaction.id && $0.status == "pending" && $0.blocksTurn }
        guard matches.count == 1, let owned = matches.first, let publicInteraction = publicInteractions[interaction.id],
              owned.actions.contains(where: { $0["id"] == .string(actionID) }),
              publicInteraction["actions"]?.arrayValue?.contains(where: { $0["id"] == .string(actionID) }) == true else {
            actionError = (interaction.id, codexLocalized("该 Codex 请求已失效。", locale: locale)); return
        }
        guard busyInteractionID != interaction.id else { return }
        busyInteractionID = interaction.id; actionError = nil
        var request: [String: JSONValue] = ["interactionId": publicInteraction["id"] ?? .null, "actionId": .string(actionID)]
        request["answers"] = answers
        Task {
            do { try await actions.respond(HarnessRespondRequest(json: codexObject(request))) }
            catch {
                actionError = (interaction.id, error.localizedDescription)
                if busyInteractionID == interaction.id { busyInteractionID = nil }
            }
        }
    }
}

private func firstByID<T: Identifiable>(_ items: [T]) -> [T.ID: T] {
    var result: [T.ID: T] = [:]
    for item in items where result[item.id] == nil { result[item.id] = item }
    return result
}

private struct CodexNotice: View {
    let message: String
    var body: some View {
        Text(message).font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.thread.muted.swiftUI)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).textSelection(.enabled)
    }
}

private struct CodexToolActivityGroup: View {
    let activities: [CodexActivity]
    let groupID: JSONText
    var body: some View {
        let summary = codexActivitySummary(activities)
        HarnessToolActivityGroup(groupID: groupID,
            items: activities.map { activity in ThreadActivitySlot(id: activity.id,
                node: AnyView(CodexActivityRow(activity: activity)), running: activity.status == "running") },
            summary: AnyView(Text(summary.text)), summaryLabel: summary.fullText,
            summaryState: state, defaultExpanded: true)
    }
    private var state: AnyView {
        if activities.contains(where: { $0.status == "running" }) { return AnyView(CodexStatusSpinner(size: 11)) }
        let name = activities.contains(where: { $0.status == "failed" }) ? "CircleAlert"
            : activities.contains(where: { $0.status == "cancelled" }) ? "Circle" : "Check"
        return AnyView(NativeIcon(name: name, size: 13))
    }
}

private struct CodexActivityRow: View {
    let activity: CodexActivity
    @Environment(\.locale) private var locale
    var body: some View {
        ThreadActivityRow(id: activity.id, state: state,
            label: AnyView(Text(activity.label + (activity.status == "failed" ? " · " + codexLocalized("失败", locale: locale) : ""))),
            detail: activity.detail.map { AnyView(Text($0).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)) })
    }
    private var state: AnyView {
        if activity.status == "running" { return AnyView(CodexStatusSpinner(size: 11)) }
        let name = activity.status == "failed" ? "CircleAlert" : ["command": "Terminal", "file": "FilePenLine", "search": "Search", "agent": "Bot", "subagent": "Bot", "review": "GitPullRequest"][activity.kind] ?? "Wrench"
        return AnyView(NativeIcon(name: name, size: 14))
    }
}

private func codexActivitySummary(_ activities: [CodexActivity]) -> (text: String, fullText: String) {
    var order: [String] = []; var counts: [String: Int] = [:]
    var filePaths: Set<JSONText> = []
    var unknownFileChanges = false
    for activity in activities {
        let kind = ["file", "command", "search"].contains(activity.kind) ? activity.kind : "other"
        if counts[kind] == nil { order.append(kind) }
        if kind == "file" {
            if let paths = activity.filePaths { filePaths.formUnion(paths) }
            else { unknownFileChanges = true }
            counts[kind] = filePaths.count
        } else { counts[kind, default: 0] += 1 }
    }
    let labels = order.enumerated().map { index, kind in
        let count = counts[kind]!
        let text: String
        switch kind {
        case "file": text = unknownFileChanges ? "Changed files" : "Touched \(count) \(count == 1 ? "file" : "files")"
        case "command": text = "Ran \(count) \(count == 1 ? "command" : "commands")"
        case "search": text = "Searched \(count) \(count == 1 ? "time" : "times")"
        default: text = "Used \(count) \(count == 1 ? "tool" : "tools")"
        }
        return index == 0 ? text : text.prefix(1).lowercased() + text.dropFirst()
    }
    let text = labels.count <= 1 ? labels.first ?? "" : labels.count == 2 ? labels.joined(separator: " and ") : labels.dropLast().joined(separator: ", ") + ", and " + labels.last!
    let statuses = [("running", "running"), ("failed", "failed"), ("cancelled", "stopped")].compactMap { status, label -> String? in
        let count = activities.filter { $0.status == status }.count
        return count > 0 ? "\(count) \(label)" : nil
    }
    return (text, statuses.isEmpty ? text : text + " · " + statuses.joined(separator: " · "))
}
