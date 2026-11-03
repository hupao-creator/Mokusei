import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

public struct OpenCodeThreadView: View {
    @Environment(\.threadAgentDetail) private var agentDetail
    @Environment(\.threadExecutionPresence) private var executionPresence
    @Environment(\.threadDetailVisibility) private var visibility
    @Environment(\.threadExecutionGroup) private var executionGroup
    public let input: HarnessThreadInput
    public let actions: HarnessThreadActions
    public let context: HarnessRenderContext
    @Environment(\.locale) private var locale
    private var providedState: OpenCodeState?
    @State private var stateCache = OpenCodeStateCache()
    @State private var resolvedAnchor: (request: JSONText, anchor: JSONText)?
    public init(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext) {
        self.input = input; self.actions = actions; self.context = context; providedState = nil
    }
    init(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext, state: OpenCodeState) {
        self.input = input; self.actions = actions; self.context = context; providedState = state
    }
    public var body: some View {
        switch providedState.map({ Result<OpenCodeState, Error>.success($0) }) ?? stateCache.decode(input.thread.sessionState) {
        case .failure(let error): OpenCodeFailure(message: ocLocalized("OpenCode 状态不可用", locale: locale) + " · " + error.localizedDescription)
        case .success(let state):
            if case .row(let key) = context.content { row(key, state: state) }
            else { conversation(state) }
        }
    }
    private func conversation(_ state: OpenCodeState) -> some View {
        let latest = input.thread.observation.latestExecution
        var rows: [ThreadConversationRow] = []
        if state.messages.contains(where: \.inherited) {
            rows.append(.init(id: "opencode-fork-history", createdAt: input.thread.createdAt, history: true,
                              node: AnyView(row("opencode-fork-history", state: state))))
        }
        for execution in state.executions {
            let primary = state.messages.filter { $0.executionID == execution.executionID && !$0.inherited && ($0.nativeSessionID == nil || $0.nativeSessionID == state.nativeSessionID) }
            rows.append(.init(id: execution.executionID, createdAt: execution.startedAt,
                execution: .init(id: execution.executionID, prompt: primary.first { $0.role == "user" }?.text ?? "",
                    answer: primary.filter { $0.role == "assistant" }.map(\.text).joined(separator: "\n"), completedAt: execution.status == .completed ? execution.finishedAt : nil),
                node: AnyView(row(execution.executionID, state: state))))
        }
        let target = input.readingTarget.map { target in
            ThreadConversationReadingTarget(requestId: target.requestID, mode: target.mode == .current ? .current : .history,
                executionId: target.executionID, anchorId: ocMokuReplyAnchor(state, target: target.message)
                    ?? (resolvedAnchor?.request == target.requestID ? resolvedAnchor?.anchor : nil), position: target.position,
                follow: input.thread.observation.isExecutionActive && input.thread.observation.latestExecution?.executionID == target.executionID, hasMessageTarget: target.message != nil)
        }
        return ThreadConversation(threadId: input.thread.id, title: agentDetail ? input.thread.title.string : ocDocumentTitle(input.thread, state: state), icon: ocEmoji(input.thread.metadataState),
            rows: rows, readingTarget: target, running: latest?.status == .running,
            runningTurnId: input.thread.observation.isExecutionActive ? latest?.executionID : nil,
            activeExecutionId: input.thread.observation.isExecutionActive ? latest?.executionID : nil, context: context,
            renderRow: context.content == .manifest ? { key in
                AnyView(OpenCodeLazyRow(key: key, input: input, actions: actions, context: context,
                    onAnchor: { request, anchor in resolvedAnchor = (request, anchor) }))
            } : nil)
            .environment(\.threadCardProviderColor, NativePalette.pair(0x33312f, 0xd9d7d4).swiftUI)
    }
    @ViewBuilder private func row(_ key: JSONText, state: OpenCodeState) -> some View {
        if key == "opencode-fork-history" {
            let inherited = state.messages.filter(\.inherited)
            let session = state.raw["forkSource"]?.ocText("sessionId") ?? state.nativeSessionID
            VStack(alignment: .leading, spacing: 12) {
                if executionGroup == nil {
                    Text(ocLocalized("来自源 OpenCode 会话的分支历史", locale: locale)).font(NativeTypography.inter(size: 12)).foregroundStyle(NativePalette.thread.muted.swiftUI)
                }
                ThreadDetailTurn(id: key, rows: ocMessageRows(inherited, sessionID: session, finalReplies: ocFinalReplyIDs(inherited, sessionID: session, splitTurns: true, presence: executionPresence, agentDetail: agentDetail), actions: actions, context: context, locale: locale, presence: executionPresence, agentDetail: agentDetail, messageAnchorID: visibility.messageAnchorID),
                    createdAt: input.thread.createdAt, updatedAt: input.thread.createdAt, status: ocLocalized("OpenCode 分支历史（只读）", locale: locale), active: false)
            }
        } else if let execution = state.executions.first(where: { $0.executionID == key }), ocExecutionVisible(key, context: context) {
            OpenCodeTurn(execution: execution, state: state, input: input, actions: actions, context: context)
        } else { OpenCodeFailure(message: "历史执行不可用") }
    }
}
private struct OpenCodeLazyRow: View {
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
                case .loading: NativeThreadLoadingIndicator(alignedLeading: true)
                case .error(let error): OpenCodeFailure(message: error, retry: { try await resource.retry() })
                case .ready(let raw):
                    ThreadDeferredExecutionContent(raw: raw, rowKey: key, context: context) { value in
                        OpenCodeLoadedRow(key: key, input: input, actions: actions, context: context, onAnchor: onAnchor, raw: value)
                    }
                }
            } else { NativeThreadLoadingIndicator(alignedLeading: true) }
        }
        .task(id: key) { resource = context.contentResource(.row(key)) }
        .onDisappear { let old = resource; old?.beginRelease(); resource = nil; Task { await old?.release() } }
    }
}

private struct OpenCodeLoadedRow: View {
    let key: JSONText
    let input: HarnessThreadInput
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    let onAnchor: (JSONText, JSONText) -> Void
    let raw: JSONValue
    @State private var stateCache = OpenCodeStateCache()
    @ViewBuilder var body: some View {
        Group {
            switch stateCache.decode(raw) {
            case .failure(let error): OpenCodeFailure(message: error.localizedDescription)
            case .success(let state):
                let anchor = ocMokuReplyAnchor(state, target: input.readingTarget?.message)
                if let thread = try? input.thread.replacingSessionState(raw) {
                    OpenCodeThreadView(input: HarnessThreadInput(thread: thread, readingTarget: input.readingTarget), actions: actions, context: context.row(key), state: state)
                        .task(id: AnchorRequest(request: input.readingTarget?.requestID, anchor: anchor)) {
                            if let target = input.readingTarget, let anchor { onAnchor(target.requestID, anchor) }
                        }
                } else { OpenCodeFailure(message: "Invalid OpenCode content") }
            }
        }.onDisappear { stateCache.clear() }
    }
    private struct AnchorRequest: Hashable { let request: JSONText?; let anchor: JSONText? }
}
private struct OpenCodeTurn: View {
    @Environment(\.threadAgentDetail) private var agentDetail
    @Environment(\.threadExecutionPresence) private var executionPresence
    @Environment(\.threadDetailVisibility) private var visibility
    let execution: PublicExecution
    let state: OpenCodeState
    let input: HarnessThreadInput
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    @Environment(\.locale) private var locale
    var body: some View {
        let messages = state.messages.filter { $0.executionID == execution.executionID && !$0.inherited }
        let latest = input.thread.observation.latestExecution
        let current = latest?.executionID == execution.executionID
        let waiting = current && latest?.status == .waitingForUser
        let executionActive = [.running, .waitingForUser].contains(execution.status)
        let usage = ocExecutionUsage(messages, auxiliary: state.auxiliary.filter { $0.ocText("executionId") == execution.executionID })
        var rows = ocMessageRows(messages, sessionID: state.nativeSessionID,
            finalReplies: waiting && executionActive ? [] : ocFinalReplyIDs(messages, sessionID: state.nativeSessionID, splitTurns: false, presence: executionPresence, agentDetail: agentDetail), actions: actions, context: context, locale: locale, presence: executionPresence, agentDetail: agentDetail,
            executionActive: executionActive, messageAnchorID: visibility.messageAnchorID)
        if execution.status == .failed, let error = execution.error {
            rows.append(.init(id: ocJoinedID([execution.executionID, ":error"]), kind: .attention, node: AnyView(OpenCodeFailure(message: error.string))))
        }
        if execution.status == .interrupted {
            rows.append(.init(id: ocJoinedID([execution.executionID, ":interrupted"]), kind: .attention, node: AnyView(Text(ocLocalized("已中断", locale: locale)))))
        }
        for interaction in waiting ? latest?.interactions ?? [] : [] {
            rows.append(.init(id: interaction.id, kind: .attention, node: AnyView(OpenCodeInteractionPanel(interaction: interaction,
                native: state.nativeInteraction(interaction.id), actions: actions).id(interaction.id))))
        }
        let nativeAuthor = messages.last { $0.role == "assistant" && !ocTrim($0.raw["model"]?.stringValue ?? "").isEmpty && ($0.nativeSessionID == nil || $0.nativeSessionID == state.nativeSessionID) }
        var author = state.raw["executionAuthors"]?.objectValue?[execution.executionID]?.objectValue ?? [:]
        if let effort = nativeAuthor?.raw["variant"], effort.stringValue?.isEmpty == false { author["effort"] = effort }
        if let nativeAuthor {
            author["model"] = .text([nativeAuthor.raw["provider"]?.stringValue, nativeAuthor.raw["model"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/"))
        }
        return ThreadDetailTurn(id: execution.executionID, author: author.isEmpty ? nil : .object(author), rows: rows,
            reasoningUsage: usage.map { .init(tokens: $0.reasoning, scope: .turn) }, createdAt: execution.startedAt,
            updatedAt: execution.finishedAt ?? execution.startedAt, status: ocLocalized(statusLabel, locale: locale),
            completedAt: execution.status == .completed ? execution.finishedAt : nil,
            usage: usage.map { AnyView(ThreadTokenUsage(input: $0.input + $0.cacheRead + $0.cacheWrite,
                output: $0.output + $0.reasoning, cached: $0.cacheRead, cacheWrite: $0.cacheWrite, reasoning: $0.reasoning)) },
            active: current && input.thread.observation.isExecutionActive)
    }
    private var statusLabel: String {
        switch execution.status { case .failed: "失败"; case .interrupted: "已中断"; case .waitingForUser: "等待你的响应"; case .running: "运行中"; case .completed: "已完成" }
    }
}
func ocFinalReplyIDs(_ messages: [OpenCodeMessage], sessionID: JSONText?, splitTurns: Bool, presence: ThreadExecutionPresence = .init(), agentDetail: Bool = true) -> Set<JSONText> {
    var replies = Set<JSONText>(); var reply: JSONText?
    for message in messages {
        if let native = message.nativeSessionID, let sessionID, native != sessionID { continue }
        if splitTurns && message.role == "user" { if let reply { replies.insert(reply) }; reply = nil }
        else if message.role == "assistant", message.status != "streaming", (!agentDetail || message.status != "failed" && message.raw["isError"] != .bool(true)), !ocTrim(message.text).isEmpty || presence.contains(message.id, "text") { reply = message.id }
    }
    if let reply { replies.insert(reply) }; return replies
}
private func ocMessagePartRowID(_ message: OpenCodeMessage, _ part: JSONValue) -> JSONText {
    let type = part["type"]?.stringValue ?? ""
    if !message.parts.isEmpty { return ocJoinedID([message.id, JSONText(":\(type):\(part["ordinal"]?.intValue ?? 0)")]) }
    return type == "text" ? message.id : ocJoinedID([message.id, ":reasoning"])
}
@MainActor private func ocMessageRows(_ messages: [OpenCodeMessage], sessionID: JSONText?, finalReplies: Set<JSONText>, actions: HarnessThreadActions, context: HarnessRenderContext, locale: Locale, presence: ThreadExecutionPresence = .init(), agentDetail: Bool = true, executionActive: Bool = false, messageAnchorID: JSONText? = nil) -> [ThreadDetailRow] {
    let tools = Dictionary(uniqueKeysWithValues: messages.filter { $0.role == "tool" }.map { ($0.id, $0) })
    let placedTools = Set(messages.filter { !agentDetail || $0.role == "assistant" }.flatMap { message in message.parts.filter { $0["type"]?.stringValue == "tool" }.map { ocJoinedID([message.id, ":tool:", $0.ocID("toolCallId")]) } })
    var children: [JSONText: [OpenCodeMessage]] = [:]
    for message in messages { if let native = message.nativeSessionID, let sessionID, native != sessionID {
        children[ocJSONStringID([.string(message.executionID), .string(native)]), default: []].append(message)
    } }
    var placedSessions = Set<JSONText>()
    var renderedTools = Set<JSONText>()
    var result: [ThreadDetailRow] = []
    for message in messages {
        if let native = message.nativeSessionID, let sessionID, native != sessionID {
            let id = ocJSONStringID([.string(message.executionID), .string(native)])
            guard placedSessions.insert(id).inserted else { continue }
            let session = children[id] ?? []
            let rows = ocMessageRows(session, sessionID: native, finalReplies: ocFinalReplyIDs(session, sessionID: native, splitTurns: false, presence: presence, agentDetail: agentDetail), actions: actions, context: context, locale: locale, presence: presence, agentDetail: agentDetail, executionActive: executionActive, messageAnchorID: messageAnchorID)
            guard !rows.isEmpty else { continue }
            let failed = agentDetail && rows.contains { $0.kind == .attention && $0.execution == nil }
            let targetedReplyIDs = Set(session.filter {
                agentDetail && messageAnchorID != nil && $0.role == "assistant" && ocMessageAnchor($0) == messageAnchorID
            }.flatMap { message -> [JSONText] in
                if message.parts.isEmpty { return [message.id] }
                return message.parts.filter { $0["type"] == .text("text") }.map { ocMessagePartRowID(message, $0) }
            })
            let targeted = rows.contains { targetedReplyIDs.contains($0.id) && $0.execution == nil }
            // A message anchor cannot resolve inside an unmounted disclosure.
            // Admit all text parts of that reply, not just its anchor part.
            let childContent = OpenCodeChildSessionContent(rows: rows, executionID: message.executionID,
                targetedReplyIDs: targetedReplyIDs)
            result.append(.init(id: ocJoinedID(["opencode-child-session:", id]), kind: failed ? .attention : targeted ? .content : .work,
                node: targeted ? AnyView(childContent) : AnyView(ThreadSurfaceDisclosure(label: ocLocalized("OpenCode 子会话", locale: locale) + " · " + native.string + (failed ? " · " + ocLocalized("失败", locale: locale) : ""),
                    live: session.contains { $0.status == "streaming" }) { childContent }),
                execution: failed || targeted ? nil : .member, executionSummary: .init(reasoningSegments: rows.reduce(0) { $0 + ($1.executionSummary?.reasoningSegments ?? 0) }, toolCalls: rows.reduce(0) { $0 + ($1.executionSummary?.toolCalls ?? 0) })))
            continue
        }
        if !agentDetail && message.role == "user" {
            let annotations = (message.raw["annotations"]?.arrayValue ?? []).map { annotation in
                ThreadMessageAnnotation(id: annotation.ocID("id"), url: annotation["url"]?.stringValue ?? "", title: annotation["title"]?.stringValue,
                    comment: annotation["comment"]?.stringValue ?? "", screenshotId: annotation.ocText("screenshotId"))
            }
            let attachments = (message.raw["attachments"]?.arrayValue ?? []).enumerated().map { index, attachment in
                ThreadMessageAttachment(id: ocJoinedID([message.id, JSONText(":attachment:\(index)")]), label: attachment["name"]?.stringValue ?? "", title: attachment["mimeType"]?.stringValue)
            }
            result.append(.init(id: message.id, kind: .user, node: AnyView(ThreadMessage(id: message.id, author: .user, content: message.text,
                annotations: annotations, attachments: attachments, openExternal: { url in Task { try? await actions.openExternal(JSONText(url.absoluteString)) } },
                resolveMedia: context.resolveMedia, previewAttachment: context.previewAttachment))))
            continue
        }
        if message.role == "tool" { if !placedTools.contains(message.id), renderedTools.insert(message.id).inserted { result.append(ocToolRow(message, locale: locale, agentDetail: agentDetail)) }; continue }
        guard message.role == "assistant" else { continue }
        var parts = message.parts
        if parts.isEmpty {
            if let thinking = message.raw["thinking"], (thinking.stringValue?.isEmpty == false || presence.contains(message.id, "thinking")) { parts.append(.object(["type": .text("reasoning"), "ordinal": .number(-1), "text": thinking])) }
            if !message.text.isEmpty || presence.contains(message.id, "text") { parts.append(.object(["type": .text("text"), "ordinal": .number(0), "text": .text(message.text)])) }
        }
        var renderedText = false
        for part in parts {
            let type = part["type"]?.stringValue ?? ""
            guard !agentDetail || ["text", "reasoning", "tool"].contains(type) else { continue }
            // Text, reasoning and tools share a native message. Withhold only
            // its reply parts, preserving live execution records and requests.
            if type == "text" && message.status == "streaming" { continue }
            if type == "tool" {
                if let tool = tools[ocJoinedID([message.id, ":tool:", part.ocID("toolCallId")])], renderedTools.insert(tool.id).inserted { result.append(ocToolRow(tool, locale: locale, agentDetail: agentDetail)) }; continue
            }
            let text = part["text"]?.stringValue ?? ""
            let field = message.parts.isEmpty ? (type == "text" ? "text" : "thinking") : "parts:\(type):\(part["ordinal"]?.intValue ?? 0)"
            guard !ocTrim(text).isEmpty || presence.contains(message.id, field) else { continue }
            if type == "text" { renderedText = true }
            let id = ocMessagePartRowID(message, part)
            let reply = type == "text" && finalReplies.contains(message.id)
            let body: AnyView
            if type == "reasoning" {
                body = AnyView(ThreadSurfaceDisclosure(label: ocLocalized("思考过程", locale: locale), live: message.status == "streaming") {
                    NativeMarkdownView(text: text, streaming: message.status == "streaming", openExternal: { url in Task { try? await actions.openExternal(JSONText(url.absoluteString)) } }, resolveMedia: context.resolveMedia)
                })
            } else { body = AnyView(ThreadMessage(id: id, author: .assistant, content: text,
                openExternal: { url in Task { try? await actions.openExternal(JSONText(url.absoluteString)) } }, resolveMedia: context.resolveMedia)) }
            let failed = agentDetail && (message.status == "failed" || message.raw["isError"] == .bool(true))
            let readableReply = type == "text" && (reply || agentDetail && (failed || executionActive || messageAnchorID == ocMessageAnchor(message)))
            result.append(.init(id: id, kind: failed ? .attention : readableReply ? .content : .work, node: body,
                execution: readableReply ? nil : .member,
                executionSummary: type == "reasoning" ? .init(reasoningSegments: 1) : nil, finalReply: reply))
        }
        // A native assistant failure can contain only reasoning/tool parts.
        // Preserve that independent failure status without exposing its tools.
        if agentDetail, message.status == "failed" || message.raw["isError"] == .bool(true), !renderedText {
            result.append(.init(id: ocJoinedID([message.id, ":assistant-error"]), kind: .attention,
                node: AnyView(OpenCodeFailure(message: ocLocalized("OpenCode 回复失败", locale: locale)))))
        }
    }
    return result
}

private struct OpenCodeChildSessionContent: View {
    let rows: [ThreadDetailRow]
    let executionID: JSONText
    let targetedReplyIDs: Set<JSONText>
    @Environment(\.threadDetailVisibility) private var visibility
    @Environment(\.threadAgentDetail) private var agentDetail

    var body: some View {
        let workVisible = visibility.work && (visibility.workTurnID == nil || visibility.workTurnID == executionID)
        // A child-session error remains reachable without revealing sibling
        // tools. Tool failures alone never promote the whole child session.
        let visible = workVisible ? rows : rows.filter { $0.execution == nil && ($0.kind == .attention || $0.kind == .content && targetedReplyIDs.contains($0.id)) }
        let displayed = agentDetail ? groupThreadExecutionRows(visible) : visible
        ThreadActivityList(items: displayed.map { ThreadActivitySlot(id: $0.id, node: AnyView($0.node.threadReadingAnchor($0.id))) }, spacing: 12)
    }
}

@MainActor private func ocToolRow(_ message: OpenCodeMessage, locale: Locale, agentDetail: Bool) -> ThreadDetailRow {
    let failed = message.raw["isError"] == .bool(true) || (agentDetail && message.status == "failed")
    return .init(id: message.id, kind: .work, node: AnyView(ThreadSurfaceDisclosure(
        label: (message.raw["toolName"]?.stringValue ?? ocLocalized("工具", locale: locale)) + (failed ? " · " + ocLocalized("失败", locale: locale) : ""), live: message.status == "streaming") {
        VStack(alignment: .leading, spacing: 4) {
            if message.raw["arguments"] != nil {
                Text(ocLocalized("输入", locale: locale)).font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.thread.muted.swiftUI).padding(.top, 8)
                OpenCodeProjectedToolOutput(message: message, field: "arguments")
            }
            if message.raw["result"] != nil || !message.text.isEmpty {
                Text(ocLocalized("输出", locale: locale)).font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.thread.muted.swiftUI).padding(.top, 8)
                Group {
                    if message.text.isEmpty { OpenCodeProjectedToolOutput(message: message, field: "result") }
                    else { OpenCodeToolOutput(text: message.text) }
                }.foregroundStyle(failed ? NativePalette.thread.danger.swiftUI : NativePalette.thread.ink.swiftUI)
            }
        }
    }), execution: .member, executionSummary: .init(toolCalls: 1))
}
private struct OpenCodeProjectedToolOutput: View {
    let message: OpenCodeMessage
    let field: String
    var body: some View {
        switch Result(catching: { try message.toolDisplay(field) }) {
        case .success(let display): OpenCodeToolOutput(text: display?.string ?? "")
        case .failure(let error): OpenCodeFailure(message: error.localizedDescription)
        }
    }
}
struct OpenCodeToolOutput: View {
    let text: String
    @State private var contentHeight: CGFloat = 18
    var body: some View {
        NativeScrollView(.vertical) {
            Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }.frame(height: min(360, max(18, contentHeight)))
    }
}
struct OpenCodeFailure: View {
    let message: String
    var retry: (() async throws -> Void)?
    @Environment(\.locale) private var locale
    @State private var retryError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(retryError ?? message).textSelection(.enabled)
            if let retry { Button(ocLocalized("重试", locale: locale)) { Task { do { try await retry(); retryError = nil } catch { retryError = error.localizedDescription } } }.buttonStyle(.plain) }
        }.font(NativeTypography.inter(size: 12)).foregroundStyle(NativePalette.thread.danger.swiftUI).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
            .nativeReadingContentReady()
    }
}
@MainActor private func ocExecutionVisible(_ id: JSONText, context: HarnessRenderContext) -> Bool {
    switch context.presentation { case .main(let excluded): !excluded.contains(id); case .execution(let selected): id == selected }
}
private func ocDocumentTitle(_ thread: HarnessThread, state: OpenCodeState) -> String {
    let initial = state.messages.first { $0.role == "user" && !$0.inherited && ($0.nativeSessionID == nil || $0.nativeSessionID == state.nativeSessionID) }?.raw.ocText("text")
    return nativeGeneratedThreadDocumentTitle(metadata: thread.metadataState, title: thread.title, initialPrompt: initial)
}

@MainActor private final class OpenCodeStateCache {
    private var raw: JSONValue?
    private var result: Result<OpenCodeState, Error>?
    func decode(_ value: JSONValue) -> Result<OpenCodeState, Error> {
        if raw == value, let result { return result }
        let result = Result { try OpenCodeState(value) }; raw = value; self.result = result; return result
    }
    func clear() { raw = nil; result = nil }
}
