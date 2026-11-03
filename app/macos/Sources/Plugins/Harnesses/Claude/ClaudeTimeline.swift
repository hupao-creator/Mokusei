import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct ClaudeTimelineEntry: View {
    @Environment(\.threadAgentDetail) private var agentDetail
    let item: JSONValue
    var turn: ClaudeTurn?
    var active = false
    var publicInteractions: [JSONText: PublicInteraction] = [:]
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    @Environment(\.locale) private var locale
    @State private var reviewExpanded = true
    var body: some View {
        switch item.claudeKind {
        case "user-message": if !agentDetail { userMessage }
        case "assistant": VStack(alignment:.leading,spacing:8) {
            if turn == nil { Text("Mokusei").font(NativeTypography.inter(size:11)).foregroundStyle(NativePalette.thread.muted.swiftUI) }
            markdown(item["content"]?.stringValue ?? "")
            if turn == nil, let status = item["status"]?.stringValue, ["failed","cancelled"].contains(status) { Text(t(claudeStatus(status))).font(NativeTypography.inter(size:11)).foregroundStyle(NativePalette.thread.muted.swiftUI) }
        }
        case "reasoning": ThreadSurfaceDisclosure(label: t("推理过程"), live: active && turn?.timeline.last == item) { markdown(item["content"]?.stringValue ?? "", streaming: active && turn?.timeline.last == item) }
        case "activity": if let activity = item["activity"] { ClaudeActivity(activity: activity) }
        case "interaction": if let interaction = item["interaction"] {
            if interaction["status"]?.stringValue == "pending", turn != nil {
                ClaudeInteractionView(interaction: interaction, publicInteraction: publicInteractions[interaction.claudeID("id")], actions: actions)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack { NativeIcon(name: interaction["status"]?.stringValue == "cancelled" ? "CircleStop" : "Check", size: 12); Text(interaction["title"]?.stringValue ?? ""); Text(t(claudeStatus(interaction["status"]?.stringValue ?? "resolved"))).foregroundStyle(NativePalette.thread.muted.swiftUI) }
                    if turn == nil {
                        if let description = interaction["description"]?.stringValue { Text(description) }
                        if let tool = interaction["toolName"]?.stringValue { Text(tool).font(NativeTypography.mono(size: 11)) }
                        ForEach(Array((interaction["questions"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, question in
                            Text(question["question"]?.stringValue ?? "")
                            Text((question["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue }.joined(separator: " · ")).foregroundStyle(NativePalette.thread.muted.swiftUI)
                        }
                    }
                }.font(NativeTypography.inter(size: 12)).textSelection(.enabled)
            }
        }
        case "notice": if let notice = item["notice"] {
            HStack(alignment: .top, spacing: 8) { NativeIcon(name: "CircleAlert", size: 13); Text(notice["message"]?.stringValue ?? "").textSelection(.enabled) }
                .font(NativeTypography.inter(size: 12)).foregroundStyle((notice["level"]?.stringValue == "error" ? NativePalette.thread.danger : NativePalette.thread.muted).swiftUI)
        }
        case "review": DisclosureGroup(t("Claude 代码审查"), isExpanded: $reviewExpanded) { markdown(item["content"]?.stringValue ?? "") }
        case "error": ClaudeFailure(message: item["message"]?.stringValue ?? "")
        case "context-compaction": HStack(spacing: 8) { NativeIcon(name: "Minimize2", size: 12); Text(t("Claude 上下文已压缩")) }.font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.thread.muted.swiftUI)
        default: EmptyView() // Diff and usage are deliberately excluded from Claude's chronological body.
        }
    }
    private var userMessage: some View {
        let index = item["promptIndex"]?.intValue ?? 0
        let content = turn.flatMap { index < $0.prompts.count ? $0.prompts[index].stringValue : nil } ?? item["content"]?.stringValue ?? ""
        let attachments = turn.flatMap { value -> [JSONValue]? in
            let lists = value.raw["promptAttachments"]?.arrayValue ?? []; return index < lists.count ? lists[index].arrayValue : nil
        } ?? item["attachments"]?.arrayValue ?? []
        return ThreadMessage(id: item.claudeID("id"), author: .user, content: content, steeringLabel: t(index == 0 ? "你" : "补充"),
            annotations: attachments.compactMap { attachment in
                guard let annotation = attachment["annotation"] else { return nil }
                return ThreadMessageAnnotation(id: annotation.claudeID("id"), url: annotation["url"]?.stringValue ?? "",
                    title: annotation["title"]?.stringValue, comment: annotation["comment"]?.stringValue ?? "",
                    screenshotId: annotation["screenshotId"].map { if case .string(let id) = $0 { id } else { JSONText("") } })
            }, attachments: attachments.filter { $0["annotation"] == nil }.map {
                ThreadMessageAttachment(id: $0.claudeID("id"), label: $0["name"]?.stringValue ?? "", title: "\($0["mimeType"]?.stringValue ?? "") · \(Int($0["size"]?.numberValue ?? 0)) B")
            }, openExternal: { url in Task { try await actions.openExternal(JSONText(url.absoluteString)) } }, resolveMedia: context.resolveMedia, previewAttachment: context.previewAttachment)
    }
    private func markdown(_ text: String, streaming: Bool = false) -> some View { NativeMarkdownView(text: text, streaming: streaming, openExternal: { url in Task { try await actions.openExternal(JSONText(url.absoluteString)) } }, resolveMedia: context.resolveMedia) }
    private func t(_ value: String) -> String { claudeLocalized(value, locale: locale) }
}
struct ClaudeActivities: View {
    let activities: [JSONValue]
    @Environment(\.threadAgentDetail) private var agentDetail
    @Environment(\.locale) private var locale
    var body: some View {
        if activities.count == 1 { ClaudeActivity(activity: activities[0]) }
        else if let first = activities.first {
            HarnessToolActivityGroup(groupID: JSONText(codeUnits: Array("claude-activities:".utf16) + first.claudeID("id").codeUnits),
                items: activities.map { ThreadActivitySlot(id: $0.claudeID("id"), node: AnyView(ClaudeActivity(activity: $0)), running: $0["status"]?.stringValue == "running") },
                summary: AnyView(Text(claudeLocalized("执行活动", locale: locale))), summaryLabel: summaryLabel,
                summaryState: AnyView(ClaudeActivityGlyph(status: groupStatus)), defaultExpanded: activities.contains { $0["status"]?.stringValue == "running" || agentDetail && $0["status"]?.stringValue == "failed" })
        }
    }
    private var groupStatus: String { ["running","failed","cancelled"].first(where: { status in activities.contains { $0["status"]?.stringValue == status } }) ?? "completed" }
    private var summaryLabel: String {
        ([claudeLocalized("Claude 执行活动", locale: locale)] + ["running","failed","cancelled"].compactMap { status in
            let count = activities.filter { $0["status"]?.stringValue == status }.count
            return count == 0 ? nil : "\(count) \(claudeLocalized(claudeStatus(status), locale: locale))"
        }).joined(separator: " · ")
    }
}
struct ClaudeActivity: View {
    let activity: JSONValue
    @Environment(\.locale) private var locale
    var body: some View {
        ThreadActivityRow(id: activity["id"] == nil ? activity.claudeID("label") : activity.claudeID("id"),
            state: AnyView(ClaudeActivityGlyph(status: activity["status"]?.stringValue ?? "", kind: activity.claudeKind)),
            label: AnyView(HStack { Text(activity["label"]?.stringValue ?? ""); Text(claudeLocalized(claudeStatus(activity["status"]?.stringValue ?? ""), locale: locale)).font(NativeTypography.inter(size: 10)) }),
            detail: activity["detail"]?.stringValue.map { AnyView(Text($0).textSelection(.enabled)) })
    }
}
struct ClaudeActivityGlyph: View {
    var status: String
    var kind = "tool"
    var body: some View {
        if status == "running" { ProgressView().controlSize(.mini).scaleEffect(0.7) }
        else { NativeIcon(name: status == "failed" ? "CircleAlert" : status == "cancelled" ? "CircleStop" : kind == "command" ? "SquareTerminal" : kind == "subagent" ? "Bot" : "Check", size: 13) }
    }
}
struct ClaudeForkHistory: View {
    @Environment(\.threadExecutionPresence) private var executionPresence
    @Environment(\.threadAgentDetail) private var agentDetail
    @Environment(\.threadExecutionGroup) private var executionGroup
    let items: [JSONValue]
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    @Environment(\.threadDetailVisibility) private var visibility
    @Environment(\.locale) private var locale
    var body: some View {
        if let executionGroup {
            ThreadExecutionGroupContent(groupID: executionGroup, rows: rows)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                HStack { NativeIcon(name: "GitBranch", size: 13); Text(claudeLocalized("来自源 Claude 会话的分支历史", locale: locale)); Text(claudeLocalized("只读历史 · 不属于当前 Execution", locale: locale)).foregroundStyle(NativePalette.thread.muted.swiftUI) }.font(NativeTypography.inter(size: 11))
                ForEach(groupThreadExecutionRows(rows, summaryOnly: agentDetail)) { row in row.node.threadReadingAnchor(row.id) }
            }.padding(.vertical, 16)
        }
    }
    private var rows: [ThreadDetailRow] {
        var last: [String: Int] = [:], final = Set<JSONText>(), lastAssistant: JSONText?
        for (index, item) in items.enumerated() where item.claudeKind == "review" { last[item.claudeKind] = index }
        let selected = items.enumerated().filter { index, item in !["diff","usage","plan"].contains(item.claudeKind) && (last[item.claudeKind] == nil || last[item.claudeKind] == index) }.map(\.element)
        for item in selected {
            if item.claudeKind == "user-message" { if let lastAssistant { final.insert(lastAssistant) }; lastAssistant = nil }
            else if item.claudeKind == "assistant", !agentDetail || item["status"]?.stringValue != "streaming" && item["status"]?.stringValue != "failed" && !claudeTrim(item["content"]).isEmpty { lastAssistant = item.claudeID("id") }
        }
        if let lastAssistant { final.insert(lastAssistant) }
        let rows: [ThreadDetailRow] = selected.compactMap { item in
            guard !agentDetail || claudeDetailIncludes(item) else { return nil }
            let kind = claudeRowKind(item, final: final.contains(item.claudeID("id")), agentDetail: agentDetail, messageAnchorID: visibility.messageAnchorID)
            guard (kind != .user || !agentDetail && visibility.userMessages), (kind != .work || visibility.work && visibility.workTurnID == nil) else { return nil }
            return ThreadDetailRow(id: item.claudeID("id"), kind: kind, node: AnyView(ClaudeTimelineEntry(item: item, actions: actions, context: context)), executionSummary: claudeExecutionSummary(item, presence: executionPresence))
        }
        let interimReplies = Set(rows.filter { agentDetail && $0.kind == .work }.map(\.id))
        return bindThreadExecutionSource(rows: rows, source: agentDetail ? selected.filter(claudeDetailIncludes) : items.filter { $0.claudeKind != "plan" }, id: { $0.claudeID("id") }, isExecution: { ["reasoning","activity"].contains($0.claudeKind) || $0.claudeKind == "assistant" && interimReplies.contains($0.claudeID("id")) })
    }
}
struct ClaudeBackgroundTasks: View {
    @Environment(\.threadAgentDetail) private var agentDetail
    let tasks: [JSONValue]
    @Environment(\.threadDetailVisibility) private var visibility
    @Environment(\.locale) private var locale
    private var visibleTasks: [JSONValue] {
        // Task notifications describe execution work, not a Harness-level error.
        visibility.work ? tasks : []
    }
    var body: some View { if !visibleTasks.isEmpty {
        if agentDetail {
            let failed = visibleTasks.filter { $0["status"]?.stringValue == "failed" }.count
            let count = visibleTasks.count.formatted(.number.locale(locale))
            let failureCount = failed.formatted(.number.locale(locale))
            let failure = failed > 0 ? " · " + claudeLocalized("失败", locale: locale) + " " + failureCount : ""
            Text("\(claudeLocalized("后台任务", locale: locale)) · \(count)\(failure)")
                .font(NativeTypography.inter(size: 12)).foregroundStyle(NativePalette.thread.muted.swiftUI).padding(.vertical, 16)
        } else {
        DisclosureGroup(claudeLocalized("后台任务", locale: locale)) {
            ForEach(Array(visibleTasks.enumerated()), id: \.offset) { _, task in
                HStack { Text(task["description"]?.stringValue ?? ""); Spacer(); Text(task["status"]?.stringValue ?? "").foregroundStyle(NativePalette.thread.muted.swiftUI) }
            }
        }.font(NativeTypography.inter(size: 12)).padding(.vertical, 16)
        }
    } }
}
struct ClaudeFailure: View {
    let message: String
    var detail: String? = nil
    var retry: (() async throws -> Void)?
    @State private var error: String?
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) { NativeIcon(name: "CircleAlert", size: 13); Text(claudeLocalized(claudeRedacted(error ?? message), locale: locale)).textSelection(.enabled) }
            if let detail, !detail.isEmpty {
                Text(claudeLocalized(claudeRedacted(detail), locale: locale)).font(NativeTypography.mono(size: 10))
                    .foregroundStyle(NativePalette.thread.muted.swiftUI).textSelection(.enabled).padding(.leading, 21)
            }
            if let retry { Button(claudeLocalized("重试", locale: locale)) { Task { do { try await retry(); error = nil } catch { self.error = error.localizedDescription } } }.buttonStyle(.plain) }
        }.font(NativeTypography.inter(size: 12)).foregroundStyle(NativePalette.thread.danger.swiftUI).padding(.vertical, 8)
    }
}
func claudeStatus(_ value: String) -> String {
    ["running":"运行中","completed":"已完成","failed":"失败","interrupted":"已中断","cancelled":"已取消","allowed":"已允许","denied":"已拒绝","submitted":"已提交","resolved":"已处理"][value] ?? value
}
func claudeEmoji(_ thread: HarnessThread) -> String? { nativeGeneratedThreadEmoji(metadata: thread.metadataState) }
func claudeDocumentTitle(_ thread: HarnessThread, state: ClaudeState) -> String {
    let prompt: JSONText? = state.turns.first?.visiblePrompts.first.map { if case .string(let text) = $0 { text } else { JSONText("") } }
    return nativeGeneratedThreadDocumentTitle(metadata: thread.metadataState, title: thread.title, initialPrompt: prompt)
}

// Activity identity survives lightweight history; stripped output is not empty output.
func claudeActivityHasContent(_ activity: JSONValue, presence: ThreadExecutionPresence, historyID: JSONText? = nil) -> Bool {
    activity.claudeKind != "hook" || activity["toolName"] != nil || activity["status"]?.stringValue != "completed" ||
        !claudeTrim(activity["detail"]).isEmpty || presence.contains(historyID ?? activity.claudeID("id"), "detail")
}

func claudeExecutionSummary(_ item: JSONValue, presence: ThreadExecutionPresence) -> ThreadExecutionSummary? {
    if item.claudeKind == "reasoning" {
        let content = !claudeTrim(item["content"]).isEmpty || presence.contains(item.claudeID("id"), "content")
        return ThreadExecutionSummary(reasoningSegments: content ? 1 : 0, hasContent: content)
    }
    if let activity = item["activity"], item.claudeKind == "activity" {
        return ThreadExecutionSummary(toolCalls: activity["toolName"] == nil ? 0 : 1,
            hasContent: claudeActivityHasContent(activity, presence: presence,
                historyID: activity["id"] == nil ? item.claudeID("id") : nil))
    }
    return nil
}
