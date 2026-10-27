import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct PiThreadView: View {
    let input: HarnessThreadInput
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    @Environment(\.locale) private var locale
    @State private var anchor: (request: JSONText, id: JSONText)?
    @State private var decoder = PiStateCache()
    var body: some View {
        Group {
            switch decoder.decode(input.thread.sessionState) {
            case .success(let state):
                if case .row(let id) = context.content {
                    if let execution = state.executions.first(where: { $0.executionID == id }), visible(id) {
                        PiTurn(input: input, state: state, execution: execution, actions: actions, context: context)
                    }
                } else { conversation(state) }
            case .failure(let failure): PiFailure(message: piLocalized("Pi 状态不可用", locale) + " · " + failure.localizedDescription)
            }
        }
    }
    private func visible(_ id: JSONText) -> Bool {
        switch context.presentation { case .main(let excluded): !excluded.contains(id); case .execution(let execution): execution == id }
    }
    private func conversation(_ state: PiState) -> some View {
        let rows = state.executions.map { execution -> ThreadConversationRow in
            let messages = state.messagesByExecution[execution.executionID] ?? []
            return ThreadConversationRow(id: execution.executionID, createdAt: execution.startedAt,
                execution: ThreadConversationExecution(id: execution.executionID,
                    prompt: messages.first { $0.role == "user" }?.text.string ?? "",
                    answer: messages.filter { $0.role == "assistant" }.map(\.text.string).joined(separator: "\n"),
                    completedAt: execution.status == .completed ? execution.finishedAt : nil),
                node: AnyView(PiTurn(input: input, state: state, execution: execution, actions: actions, context: context)))
        }
        let latest = input.thread.observation.latestExecution
        return ThreadConversation(threadId: input.thread.id,
            title: nativeGeneratedThreadDocumentTitle(metadata: input.thread.metadataState, title: input.thread.title,
                initialPrompt: state.messages.first { $0.role == "user" }?.text),
            icon: nativeGeneratedThreadEmoji(metadata: input.thread.metadataState), rows: rows,
            readingTarget: readingTarget(state), running: latest?.status == .running,
            runningTurnId: latest.map { [.running, .waitingForUser].contains($0.status) ? $0.executionID : nil } ?? nil,
            context: context, renderRow: context.content == .manifest ? { key in
                AnyView(PiLazyRow(key: key, input: input, actions: actions, context: context,
                    onAnchor: { request, id in anchor = (request, id) }))
            } : nil)
    }
    private func readingTarget(_ state: PiState) -> ThreadConversationReadingTarget? {
        input.readingTarget.map { target in
            ThreadConversationReadingTarget(requestId: target.requestID, mode: target.mode == .current ? .current : .history,
                executionId: target.executionID,
                anchorId: piMokuAnchor(state, target.message) ?? (anchor?.request == target.requestID ? anchor?.id : nil))
        }
    }
}

private struct PiLazyRow: View {
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
                case .loading: ProgressView().controlSize(.small).padding(.vertical, 16)
                case .error(let message): PiFailure(message: message, retry: { try await resource.retry() })
                case .ready(let raw):
                    ThreadDeferredExecutionContent(raw: raw, rowKey: key, context: context) { value in
                        PiLoadedRow(key: key, input: input, actions: actions, context: context, onAnchor: onAnchor, raw: value)
                    }
                }
            } else { ProgressView().controlSize(.small).padding(.vertical, 16) }
        }
        .task(id: key) { resource = context.contentResource(.row(key)) }
        .onDisappear {
            let old = resource; old?.beginRelease(); resource = nil
            Task { await old?.release() }
        }
    }
}

private struct PiLoadedRow: View {
    let key: JSONText
    let input: HarnessThreadInput
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    let onAnchor: (JSONText, JSONText) -> Void
    let raw: JSONValue
    @State private var decoder = PiStateCache()
    @ViewBuilder var body: some View {
        Group {
            if case .success(let state) = decoder.decode(raw), let execution = state.executions.first(where: { $0.executionID == key }) {
                let anchor = piMokuAnchor(state, input.readingTarget?.message)
                PiTurn(input: input, state: state, execution: execution, actions: actions, context: context.row(key))
                    .onChange(of: AnchorRequest(request: input.readingTarget?.requestID, anchor: anchor), initial: true) { _, request in
                        if let id = request.request, let anchor = request.anchor { onAnchor(id, anchor) }
                    }
            } else { PiFailure(message: "Invalid Pi session state") }
        }.onDisappear { decoder.clear() }
    }
    private struct AnchorRequest: Hashable { let request: JSONText?; let anchor: JSONText? }
}

/// A non-observed memo is safe during rendering: only the input controls the
/// view update, and reading/focus/disclosure changes never reparse private data.
@MainActor private final class PiStateCache {
    private var source: JSONValue?
    private var result: Result<PiState, Error>?
    func decode(_ value: JSONValue) -> Result<PiState, Error> {
        if source != value || result == nil { source = value; result = Result { try PiState(value) } }
        return result!
    }
    func clear() { source = nil; result = nil }
}

private struct PiTurn: View {
    @Environment(\.threadExecutionPresence) private var executionPresence
    let input: HarnessThreadInput
    let state: PiState
    let execution: PublicExecution
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    @Environment(\.locale) private var locale
    @State private var busy = false
    @State private var failure: String?
    private var messages: [PiMessage] { state.messagesByExecution[execution.executionID] ?? [] }
    private var current: Bool { input.thread.observation.latestExecution?.executionID == execution.executionID }
    private var active: Bool { current && [.running, .waitingForUser].contains(input.thread.observation.latestExecution?.status ?? .completed) }
    var body: some View {
        let usage = state.executionUsage[execution.executionID]
        let assistants = messages.filter { $0.role == "assistant" }
        let reasoning = !assistants.isEmpty && assistants.allSatisfy { $0.status != "streaming" && $0.usage?.reasoning != nil }
            ? assistants.reduce(0) { $0 + ($1.usage?.reasoning ?? 0) } : nil
        VStack(alignment: .leading, spacing: 8) {
            if let failure { PiFailure(message: failure) }
            ThreadDetailTurn(id: execution.executionID, author: author, rows: rows,
                reasoningUsage: reasoning.map { ThreadReasoningUsage(tokens: $0, scope: .turn) },
                createdAt: execution.startedAt, updatedAt: execution.finishedAt ?? execution.startedAt,
                status: execution.status.rawValue, completedAt: execution.status == .completed ? execution.finishedAt : nil,
                usage: usage.map { AnyView(ThreadTokenUsage(input: $0.prompt, output: $0.output, cached: $0.cacheRead,
                    cacheWrite: $0.cacheWrite, reasoning: $0.reasoning)) }, active: active)
        }
    }
    private var author: JSONValue {
        var author = state.authors[execution.executionID]?.objectValue ?? [:]
        if let native = messages.last(where: { $0.role == "assistant" && !piTrim($0.model ?? "").codeUnits.isEmpty }) {
            let components = [native.provider, native.model].compactMap { $0 }.filter { !$0.codeUnits.isEmpty }
            var units: [UInt16] = []
            for (index, component) in components.enumerated() {
                if index > 0 { units.append(47) }; units += component.codeUnits
            }
            author["model"] = .string(JSONText(codeUnits: units))
        }
        return .object(author)
    }
    private var rows: [ThreadDetailRow] {
        let waiting = current && input.thread.observation.latestExecution?.status == .waitingForUser
        let finalID = waiting ? nil : messages.last { $0.role == "assistant" && !piTrim($0.text).codeUnits.isEmpty }?.id
        var rows: [ThreadDetailRow] = []
        for message in messages {
            let final = message.role == "assistant" && message.id == finalID
            if message.role == "assistant", let thinking = message.thinking,
               !piTrim(thinking).codeUnits.isEmpty || executionPresence.contains(message.id, "thinking") {
                rows.append(ThreadDetailRow(id: JSONText(codeUnits: message.id.codeUnits + Array(":thinking".utf16)), kind: .work,
                    node: AnyView(ThreadSurfaceDisclosure(label: piLocalized("思考过程", locale)) {
                        NativeMarkdownView(text: thinking.string, streaming: message.status == "streaming", openExternal: openExternal, resolveMedia: context.resolveMedia)
                    }), execution: .member, executionSummary: ThreadExecutionSummary(reasoningSegments: 1)))
            }
            if message.role == "assistant" && piTrim(message.text).codeUnits.isEmpty && !executionPresence.contains(message.id, "text") { continue }
            rows.append(ThreadDetailRow(id: message.id, kind: message.role == "user" ? .user : message.role == "tool" || !final ? .work : .content,
                node: AnyView(messageView(message)), execution: message.role == "tool" || (message.role == "assistant" && !final) ? .member : nil,
                executionSummary: message.role == "tool" && message.toolCallID != nil ? ThreadExecutionSummary(toolCalls: 1) : nil))
        }
        if execution.status == .failed, let error = execution.error, !error.codeUnits.isEmpty {
            rows.append(ThreadDetailRow(id: "execution-error", kind: .content, node: AnyView(PiFailure(message: error.string))))
        }
        if waiting {
            for interaction in input.thread.observation.latestExecution?.interactions ?? [] {
                rows.append(ThreadDetailRow(id: interaction.id, kind: .content,
                    node: AnyView(PiInteraction(interaction: interaction, busy: busy) { actionID, answers in
                        guard !busy else { return }; busy = true; failure = nil
                        defer { busy = false }
                        do { try await actions.respond(HarnessRespondRequest(interactionID: interaction.id, actionID: actionID, answers: answers)) }
                        catch { failure = error.localizedDescription }
                    }.id(interaction.id))))
            }
        }
        return rows
    }
    @ViewBuilder private func messageView(_ message: PiMessage) -> some View {
        if message.role == "tool" {
            ThreadSurfaceDisclosure(label: message.toolName?.codeUnits.isEmpty == false ? message.toolName!.string : piLocalized("工具", locale)) {
                Text(message.text.string).font(NativeTypography.mono(size: 11)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(message.isError ? NativePalette.thread.danger.swiftUI : NativePalette.thread.ink.swiftUI)
            }
        } else {
            ThreadMessage(id: message.id, author: message.role == "user" ? .user : .assistant, content: message.text.string,
                streaming: message.status == "streaming",
                annotations: message.annotations.compactMap { value in
                    guard let id = piText(value["id"]) else { return nil }
                    return ThreadMessageAnnotation(id: id, url: value["url"]?.stringValue ?? "", title: value["title"]?.stringValue,
                        comment: value["comment"]?.stringValue ?? "", screenshotId: piText(value["screenshotId"]))
                }, openExternal: openExternal, resolveMedia: context.resolveMedia, previewAttachment: context.previewAttachment)
        }
    }
    private func openExternal(_ url: URL) { Task { do { try await actions.openExternal(JSONText(url.absoluteString)) } catch { failure = error.localizedDescription } } }
}

private struct PiInteraction: View {
    let interaction: PublicInteraction
    let busy: Bool
    let respond: (JSONText, [JSONText: HarnessResponseAnswer]?) async -> Void
    @State private var answers = InteractionAnswers()
    private var questions: [InteractionQuestionSpec] {
        interaction.questions.map { q in InteractionQuestionSpec(id: q.id, prompt: q.prompt.string, header: q.header?.string,
            multiple: q.multiple, allowOther: q.allowOther, secret: q.secret,
            options: q.options.map { InteractionQuestionOption(value: $0.value, label: $0.label.string, description: $0.description?.string) }) }
    }
    var body: some View {
        ThreadDetailRequest {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(interaction.title.string).font(NativeTypography.inter(size: 16, weight: 600))
                        .foregroundStyle(NativePalette.thread.inkStrong.swiftUI)
                    if let description = interaction.description {
                        Text(description.string).font(NativeTypography.inter(size: 13))
                            .foregroundStyle(NativePalette.thread.muted.swiftUI).textSelection(.enabled)
                    }
                }.padding(.bottom, 17)
                ForEach(questions) { question in InteractionQuestionField(question: question, answers: $answers, disabled: busy) }
                HStack(spacing: 8) {
                    ForEach(interaction.actions, id: \.id) { action in
                        Button(action.label.string) {
                            let values = action.intent == .submit ? answers.answersFor(questions).mapValues { answer -> HarnessResponseAnswer in
                                switch answer { case .single(let v): .text(v); case .multiple(let v): .multiple(v) }
                            } : nil
                            Task { await respond(action.id, values) }
                        }.buttonStyle(PiRequestButtonStyle())
                            .disabled(busy || (action.intent == .submit && !questions.allSatisfy { answers.answered($0) }))
                    }
                }.padding(.top, 22)
            }
        }
    }
}

private struct PiRequestButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        PiRequestButtonLabel(label: configuration.label, pressed: configuration.isPressed, enabled: enabled)
    }
    private struct PiRequestButtonLabel: View {
        let label: ButtonStyleConfiguration.Label
        let pressed: Bool
        let enabled: Bool
        @State private var hovered = false
        var body: some View {
            label.font(NativeTypography.inter(size: 11, weight: 500))
                .foregroundStyle(NativePalette.thread.muted.swiftUI)
                .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 34)
                .background(hovered || pressed ? NativePalette.thread.surface.swiftUI : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8)).onHover { hovered = $0 }
                .opacity(enabled ? 1 : 0.45)
        }
    }
}

struct PiFailure: View {
    let message: String
    var retry: (() async throws -> Void)?
    @State private var failure: String?
    @State private var retrying = false
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(failure ?? message).textSelection(.enabled)
            if let retry { Button(piLocalized("重试", locale)) { Task {
                retrying = true; defer { retrying = false }
                do { try await retry(); failure = nil } catch { failure = error.localizedDescription }
            } }.disabled(retrying) }
        }.font(NativeTypography.inter(size: 12)).foregroundStyle(NativePalette.thread.danger.swiftUI)
    }
}
