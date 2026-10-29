import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Thread scope is a directory. Only visible opaque rows acquire their complete
/// native content; neither overview previews nor manifests become transcript.
public struct CodexThreadView: View {
    public let input: HarnessThreadInput
    public let actions: HarnessThreadActions
    public let context: HarnessRenderContext
    @State private var stateCache = CodexStateCache()
    @State private var resolvedAnchor: (thread: JSONText, request: JSONText, anchor: JSONText)?

    public init(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext) {
        self.input = input; self.actions = actions; self.context = context
    }

    public var body: some View {
        switch decoded {
        case .success(let state):
            if case .row(let key) = context.content {
                if let turn = (state.forkHistory + state.turns).first(where: { $0.rowID == key }) {
                    if codexTurnVisible(turn.executionId, context: context) { turnView(turn, state: state) }
                } else { CodexContentFailure(message: "历史执行不可用") }
            } else {
                conversation(state)
            }
        case .failure(let error): CodexContentFailure(message: error.localizedDescription)
        }
    }

    private var decoded: Result<CodexState, Error> {
        stateCache.decode(input.thread.sessionState, createdAt: input.thread.createdAt)
    }

    @ViewBuilder private func conversation(_ state: CodexState) -> some View {
        let ownIDs = Set(state.turns.map(\.executionId))
        let allTurns = state.forkHistory + state.turns
        let rows: [ThreadConversationRow] = allTurns.map { turn in
            ThreadConversationRow(id: turn.rowID, createdAt: turn.createdAt,
                execution: ThreadConversationExecution(id: turn.executionId,
                    prompt: turn.messages.first(where: { $0.role == "user" && !$0.isInternal })?.content ?? "",
                    answer: turn.answer, completedAt: turn.status == "completed" ? turn.finishedAt : nil,
                    readable: ownIDs.contains(turn.executionId)), node: AnyView(turnView(turn, state: state)))
        } + supplementalRows(state)
        ThreadConversation(threadId: input.thread.id,
            title: codexDocumentTitle(input.thread, state: state), icon: codexDocumentEmoji(input.thread),
            rows: rows, readingTarget: readingTarget(state),
            running: input.thread.observation.latestExecution?.status == .running,
            runningTurnId: runningTurnID(state), context: context,
            renderRow: context.content == .manifest ? { key in
                if allTurns.contains(where: { $0.rowID == key }) {
                    return AnyView(CodexLazyTurnRow(key: key, input: input, actions: actions, context: context,
                        onAnchor: { request, anchor in resolvedAnchor = (input.thread.id, request, anchor) }))
                }
                return rows.first(where: { $0.id == key })?.node ?? AnyView(EmptyView())
            } : nil)
    }

    private func readingTarget(_ state: CodexState) -> ThreadConversationReadingTarget? {
        guard let target = input.readingTarget else { return nil }
        let anchor = codexMokuReplyAnchor(state: state.raw, message: target.message)
            ?? (resolvedAnchor?.thread == input.thread.id && resolvedAnchor?.request == target.requestID ? resolvedAnchor?.anchor : nil)
        return ThreadConversationReadingTarget(requestId: target.requestID,
            mode: target.mode == .current ? .current : .history, executionId: target.executionID, anchorId: anchor, position: target.position,
                follow: input.thread.observation.isExecutionActive && input.thread.observation.latestExecution?.executionID == target.executionID)
    }

    private func runningTurnID(_ state: CodexState) -> JSONText? {
        guard let execution = input.thread.observation.latestExecution, execution.status == .running else { return nil }
        return state.turns.last(where: { $0.executionId == execution.executionID && $0.status == "running" })?.executionId
    }

    private func turnView(_ turn: CodexTurn, state: CodexState) -> some View {
        CodexTurnRows(turn: turn, active: turn.executionId == runningTurnID(state),
            state: state, observation: input.thread.observation.json, actions: actions, context: context)
    }

    private func supplementalRows(_ state: CodexState) -> [ThreadConversationRow] {
        var rows: [ThreadConversationRow] = []
        if !state.backgroundTerminals.isEmpty {
            rows.append(ThreadConversationRow(id: "codex:background-terminals", createdAt: state.updatedAt,
                node: AnyView(CodexBackgroundTerminals(terminals: state.backgroundTerminals))))
        }
        if state.nativeActivity?["status"]?.stringValue?.contains("systemError") == true {
            rows.append(ThreadConversationRow(id: "codex:system-error", createdAt: state.nativeActivity?["updatedAt"]?.numberValue ?? state.updatedAt,
                node: AnyView(CodexContentFailure(message: "Codex 线程发生系统错误"))))
        }
        return rows
    }
}

private struct CodexLazyTurnRow: View {
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
                case .loading: CodexContentStatus()
                case .error(let message): CodexContentStatus(message: message, retry: { try await resource.retry() })
                case .ready(let raw):
                    ThreadDeferredExecutionContent(raw: raw, rowKey: key, context: context) { value in
                        CodexLoadedTurnRow(key: key, input: input, actions: actions, context: context, onAnchor: onAnchor, raw: value)
                    }
                }
            } else { CodexContentStatus() }
        }
        .nativeReadingObservation("load", role: "row.load", value: loadState)
        .task(id: key) {
            guard !Task.isCancelled else { return }
            resource = context.contentResource(.row(key))
        }
        .onDisappear {
            let old = resource; old?.beginRelease(); resource = nil
            Task { await old?.release() }
        }
    }
    private var loadState: JSONValue {
        let state: String
        var error: JSONValue = .null
        switch resource?.state {
        case .ready?: state = "ready"
        case .error(let message)?: state = "error"; error = .text(message)
        default: state = "loading"
        }
        return .object(["rowId": .string(key), "state": .text(state), "error": error])
    }
}

private struct CodexLoadedTurnRow: View {
    let key: JSONText
    let input: HarnessThreadInput
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    let onAnchor: (JSONText, JSONText) -> Void
    let raw: JSONValue
    @State private var stateCache = CodexStateCache()
    @ViewBuilder var body: some View {
        if case .success(let state) = stateCache.decode(raw),
           let turn = (state.forkHistory + state.turns).first(where: { $0.rowID == key }) {
            let active = input.thread.observation.latestExecution?.status == .running &&
                input.thread.observation.latestExecution?.executionID == turn.executionId && turn.status == "running"
            if codexTurnVisible(turn.executionId, context: context) {
                let anchor = codexMokuReplyAnchor(state: state.raw, message: input.readingTarget?.message)
                CodexTurnRows(turn: turn, active: active, state: state,
                              observation: input.thread.observation.json, actions: actions, context: context.row(key))
                    .task(id: AnchorRequest(request: input.readingTarget?.requestID, anchor: anchor)) {
                        guard !Task.isCancelled else { return }
                        if let target = input.readingTarget, target.executionID == turn.executionId, let anchor {
                            onAnchor(target.requestID, anchor)
                        }
                    }
            }
        } else { CodexContentFailure(message: "Codex sessionState 无效") }
    }

    private struct AnchorRequest: Hashable { let request: JSONText?; let anchor: JSONText? }
}

@MainActor private func codexTurnVisible(_ executionID: JSONText, context: HarnessRenderContext) -> Bool {
    switch context.presentation {
    case .main(let excluded): !excluded.contains(executionID)
    case .execution(let id): id == executionID
    }
}

struct CodexContentFailure: View {
    let message: String
    var translatesMessage = true
    var retry: (() async throws -> Void)?
    @Environment(\.locale) private var locale
    @State private var retryError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                NativeIcon(name: "CircleAlert", size: 13)
                Text(translatesMessage ? codexLocalized(retryError ?? message, locale: locale) : retryError ?? message).textSelection(.enabled)
            }
            if let retry {
                Button(codexLocalized("重试", locale: locale)) {
                    Task { do { try await retry(); retryError = nil } catch { retryError = error.localizedDescription } }
                }.buttonStyle(.plain)
            }
        }.font(NativeTypography.inter(size: 12)).foregroundStyle(NativePalette.thread.danger.swiftUI)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(NativePalette.thread.lineSoft.swiftUI).frame(height: 1) }
            .padding(.vertical, 12)
            .accessibilityElement(children: .contain)
    }
}

private struct CodexContentStatus: View {
    var message: String?
    var retry: (() async throws -> Void)?
    @State private var retryError: String?
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message {
                Text(codexLocalized("读取对话内容失败。", locale: locale) + " " + codexLocalized(retryError ?? message, locale: locale))
                if let retry {
                    Button(codexLocalized("重试", locale: locale)) {
                        Task { do { try await retry() } catch { retryError = error.localizedDescription } }
                    }.buttonStyle(.plain).padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(NativePalette.thread.ink.swiftUI)
                        .background(NativePalette.thread.surface.swiftUI, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(NativePalette.thread.line.swiftUI, lineWidth: 1))
                }
            } else { Text(codexLocalized("正在读取", locale: locale) + "…") }
        }.foregroundStyle(NativePalette.thread.muted.swiftUI).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16).accessibilityElement(children: .contain)
    }
}

private struct CodexBackgroundTerminals: View {
    let terminals: [JSONValue]
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                NativeIcon(name: "Terminal", size: 14)
                Text(codexLocalized("后台终端", locale: locale)).fontWeight(.medium)
            }.foregroundStyle(NativePalette.thread.muted.swiftUI)
            ForEach(Array(terminals.enumerated()), id: \.offset) { _, terminal in
                HStack(alignment: .top, spacing: 8) {
                    CodexStatusSpinner(size: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(terminal["command"]?.stringValue ?? "").font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        Text(terminal["cwd"]?.stringValue ?? "").foregroundStyle(NativePalette.thread.muted.swiftUI).lineLimit(1)
                    }
                }
            }
        }.font(NativeTypography.inter(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16).overlay(alignment: .top) { Rectangle().fill(NativePalette.thread.lineSoft.swiftUI).frame(height: 1) }.padding(.top, 24)
    }
}

private func codexDocumentEmoji(_ thread: HarnessThread) -> String? {
    nativeGeneratedThreadEmoji(metadata: thread.metadataState)
}

private func codexDocumentTitle(_ thread: HarnessThread, state: CodexState) -> String {
    nativeGeneratedThreadDocumentTitle(metadata: thread.metadataState, title: thread.title,
        initialPrompt: state.turns.first?.messages.first(where: { $0.role == "user" && !$0.isInternal })?.raw["content"].flatMap { value in
            if case let .string(text) = value { return text }; return nil
        })
}
