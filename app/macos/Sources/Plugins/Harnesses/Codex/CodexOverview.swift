import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

public enum CodexOverviewStatus: String, Hashable, Sendable {
    case running, attention, completed, failed, cancelled, idle
}

public struct CodexOverviewView: Hashable, Sendable {
    public let identity: ThreadCardIdentityView
    public let presentation: ThreadCardPresentation
    public let status: CodexOverviewStatus
    public let statusLabel: String
    public let pendingInteractionID: JSONText?
}

public func projectCodexOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewProjection<CodexOverviewView> {
    let content = try CodexOverviewProjector.content(thread: input.thread.json)
    let presentation = try composeThreadCard(CodexCardAdapter.projection(content.card),
                                            git: input.git, layoutContext: ThreadCardLayoutContext(availableCols: availableColumns))
    let initial = content.initialResponseScope && !content.hasAgentContent && input.thread.moku != true
        ? threadCardInitialResponse(pendingInput: input.thread.pendingInput, observation: input.thread.observation,
                                    hasVisibleInteraction: content.pendingInteractionID != nil) : nil
    let view = CodexOverviewView(identity: CodexCardAdapter.identity(content.identity, initialResponse: initial,
        initialResponseContent: content.initialResponseScope && content.hasAgentContent && input.thread.moku != true), presentation: presentation,
                                status: content.status, statusLabel: content.statusLabel,
                                pendingInteractionID: content.pendingInteractionID)
    return HarnessOverviewProjection(footprint: HarnessOverviewFootprint(columns: presentation.size.cols, rows: presentation.size.rows),
                                     structureKey: JSONText(presentation.key), excerpt: content.identity.codexIdentity("excerpt"), view: view)
}

public func codexExecutionTokenUsage(thread: HarnessThread, executionID: JSONText) throws -> HarnessExecutionTokenUsage? {
    let state = try CodexState(thread.sessionState, createdAt: thread.createdAt)
    return CodexOverviewProjector.executionUsage(state: state.raw, executionID: executionID)
}

public struct CodexOverviewCard: View {
    public let input: HarnessThreadInput
    public let projection: CodexOverviewView
    public let actions: HarnessThreadActions
    public let openThread: () -> Void
    @Environment(\.locale) private var locale

    public init(input: HarnessThreadInput, projection: CodexOverviewView,
                actions: HarnessThreadActions, openThread: @escaping () -> Void) {
        self.input = input; self.projection = projection; self.actions = actions; self.openThread = openThread
    }

    public var body: some View {
        HarnessThreadCard(identity: brandedIdentity, presentation: localizedPresentation,
            onRespond: responseHandler, onOpen: openThread,
            status: threadCardStatus(input.thread.observation), emoji: generatedEmoji,
            harnessLogo: AnyView(CodexLogo(size: 12)))
            .environment(\.threadCardProviderColor, NativePalette.pair(0x3941ff, 0x8f94ff).swiftUI)
            .environment(\.threadCardCloudPalette, CodexLogo.threadCardCloudPalette)
    }

    private var responseHandler: ThreadCardInterventionHandler? {
        guard let interactionID = projection.pendingInteractionID else { return nil }
        return { request in
            // The public binding is authoritative; the private native request ID
            // never enters the host's response API.
            let latest = try CodexOverviewProjector.content(thread: input.thread.json)
            guard latest.pendingInteractionID == interactionID else { throw CodexPresentationError.expiredInteraction }
            let answers = request.answers?.mapValues { value -> HarnessResponseAnswer in
                switch value {
                case .string(let text): .text(text)
                case .strings(let texts): .multiple(texts)
                }
            }
            try await actions.respond(HarnessRespondRequest(interactionID: interactionID,
                actionID: request.actionId, answers: answers))
        }
    }

    private var brandedIdentity: ThreadCardIdentityView {
        let value = projection.identity
        return ThreadCardIdentityView(title: value.title, providerStatus: value.providerStatus, state: value.state,
            harness: ThreadCardHarnessBrand(brandKey: "codex", label: "Codex", logoSource: ""),
            model: value.model.map { $0 == "未知模型" ? codexLocalized($0, locale: locale) : $0 },
            effort: value.effort, fastMode: value.fastMode, runtime: value.runtime, cwd: value.cwd,
            cwdName: value.cwdName, usesWorktree: value.usesWorktree, steer: value.steer,
            excerpt: value.excerpt, message: value.message, initialResponse: value.initialResponse, initialResponseContent: value.initialResponseContent)
    }

    private var localizedPresentation: ThreadCardPresentation {
        let current = projection.presentation
        guard case .standard(let identity, let extensions) = current.projection else { return current }
        let localized = extensions.map { value -> ThreadCardExtensionProjection in
            guard case .intervention(let intervention) = value else { return value }
            return .intervention(ThreadCardIntervention(id: intervention.id, title: intervention.title, detail: intervention.detail,
                actions: intervention.actions.map { action in
                    ThreadCardDecisionAction(id: action.id, label: codexLocalized(action.label, locale: locale))
                }, questions: intervention.questions, submitActionId: intervention.submitActionId, skipAction: intervention.skipAction))
        }
        return ThreadCardPresentation(projection: .standard(identity: identity, extensions: localized),
            composition: current.composition, size: current.size, key: current.key)
    }

    private var generatedEmoji: String? {
        nativeGeneratedThreadEmoji(metadata: input.thread.metadataState)
    }
}

private enum CodexCardAdapter {
    static func identity(_ raw: JSONValue, initialResponse: ThreadCardInitialResponse?, initialResponseContent: Bool) -> ThreadCardIdentityView {
        ThreadCardIdentityView(title: raw["title"]?.stringValue ?? "",
            model: raw["model"]?.stringValue, effort: raw["effort"]?.stringValue,
            fastMode: raw["fastMode"]?.boolValue == true,
            // A missing start timestamp would render a bogus 1970-based
            // duration on the first frames; without a start, show no runtime.
            runtime: raw["runtime"].flatMap { runtime in
                guard let startedAt = runtime["startedAt"]?.numberValue, startedAt.isFinite else { return nil }
                return ThreadCardRuntimeValue(startedAt: startedAt, endedAt: runtime["endedAt"]?.numberValue)
            },
            cwd: raw["cwd"]?.stringValue, cwdName: raw["cwdName"]?.stringValue,
            usesWorktree: raw["usesWorktree"]?.boolValue == true, steer: raw["steer"]?.stringValue,
            excerpt: initialResponse == nil ? raw["excerpt"]?.stringValue ?? "" : "",
            message: initialResponse == nil ? raw["message"].map { ThreadCardMessage(id: $0.codexIdentity("id"), text: $0["text"]?.stringValue ?? "") } : nil,
            initialResponse: initialResponse, initialResponseContent: initialResponseContent)
    }

    static func projection(_ raw: JSONValue) -> ThreadCardProjection {
        let identity = raw["identity"] ?? .null
        let projected = ThreadCardIdentityProjection(
            recentTools: identity["recentTools"]?.arrayValue?.map(tool), latestTool: identity["latestTool"].map(tool),
            usage: identity["usage"].map { usage in
                ThreadCardIdentityUsage(parts: (usage["parts"]?.arrayValue ?? []).map { part in
                    ThreadCardIdentityUsagePart(suffix: part["suffix"]?.stringValue, description: part["description"]?.stringValue,
                        id: part["id"]?.stringValue ?? "", label: part["label"]?.stringValue,
                        value: part["value"]?.stringValue ?? "", numericValue: part["numericValue"]?.numberValue)
                })
            })
        let extensions: [ThreadCardExtensionProjection] = (raw["extensions"]?.arrayValue ?? []).compactMap { value in
            switch value["kind"]?.stringValue {
            case "todo": return .todo(steps: (value["steps"]?.arrayValue ?? []).map {
                ThreadCardPlanStep(step: $0["step"]?.stringValue ?? "", status: ThreadCardPlanStatus(rawValue: $0["status"]?.stringValue ?? "") ?? .pending)
            })
            case "derived": return .derived(rows: (value["rows"]?.arrayValue ?? []).map {
                ThreadCardDerivedRow(id: $0.codexIdentity("id"), label: $0["label"]?.stringValue ?? "",
                    status: ThreadCardActivityStatus(rawValue: $0["status"]?.stringValue ?? "") ?? .running,
                    kind: ThreadCardDerivedKind(rawValue: $0["kind"]?.stringValue ?? "") ?? .task,
                    commandLine: $0["commandLine"]?.boolValue == true)
            })
            case "intervention": return value["intervention"].map { .intervention(intervention($0)) }
            default: return nil
            }
        }
        return .standard(identity: projected, extensions: extensions)
    }

    private static func tool(_ value: JSONValue) -> ThreadCardIdentityTool {
        ThreadCardIdentityTool(kind: ThreadCardIdentityToolKind(rawValue: value["kind"]?.stringValue ?? "") ?? .tool,
            name: value["name"]?.stringValue ?? "", summary: value["summary"]?.stringValue,
            status: ThreadCardActivityStatus(rawValue: value["status"]?.stringValue ?? "") ?? .completed)
    }

    private static func intervention(_ raw: JSONValue) -> ThreadCardIntervention {
        ThreadCardIntervention(id: raw.codexIdentity("id"), title: raw["title"]?.stringValue ?? "",
            detail: raw["detail"]?.stringValue,
            actions: (raw["actions"]?.arrayValue ?? []).map {
                ThreadCardDecisionAction(id: $0.codexIdentity("id"), label: codexOverviewActionLabel($0))
            }, questions: (raw["questions"]?.arrayValue ?? []).map { question in
                ThreadCardQuestion(id: question.codexIdentity("id"), prompt: question["prompt"]?.stringValue ?? "",
                    header: question["header"]?.stringValue, multiple: false,
                    allowOther: question["allowOther"]?.boolValue == true, secret: false,
                    options: (question["options"]?.arrayValue ?? []).map {
                        ThreadCardQuestionOption(id: $0.codexIdentity("id"), label: $0["label"]?.stringValue ?? "",
                            description: $0["description"]?.stringValue, value: $0.codexIdentity("value"))
                    })
            }, submitActionId: raw["submitActionId"].map { value in if case .string(let id) = value { id } else { JSONText("") } })
    }
}

private func codexOverviewActionLabel(_ action: JSONValue) -> String {
    switch action["id"]?.stringValue {
    case "allow-once": "允许一次"
    case "allow-session": "本会话始终允许"
    case "deny": "拒绝"
    case "cancel": "取消"
    case "submit": action["intent"]?.stringValue == "allow" ? "允许" : "提交"
    default: action["label"]?.stringValue ?? ""
    }
}

/// Provider-owned display facts. Raw values here are ephemeral projections,
/// never a second persisted representation of the conversation.
struct CodexOverviewContent {
    let initialResponseScope: Bool
    let hasAgentContent: Bool
    let identity: JSONValue
    let card: JSONValue
    let status: CodexOverviewStatus
    let statusLabel: String
    let pendingInteractionID: JSONText?
}

enum CodexOverviewProjector {
    static func content(thread: JSONValue) throws -> CodexOverviewContent {
        let state = try CodexState(thread["sessionState"] ?? .null, createdAt: thread["createdAt"]?.numberValue ?? 0)
        let turn = state.turns.last
        let publicInteractions = codexPublicInteractionsByNativeId(state: state.raw, observation: thread["observation"] ?? .null)
        let pending = turn?.interactions.first(where: { $0.status == "pending" && $0.blocksTurn })
        let publicPending = pending.flatMap { publicInteractions[$0.id] }
        let preview = turn ?? state.forkHistory.last
        let prompt = preview?.messages.last(where: {
            $0.role == "user" && !$0.isInternal && !codexTrim($0.raw["content"]).codeUnits.isEmpty
        })
        let agent = overviewMessage(state.turns) ?? overviewMessage(state.forkHistory)
        let message: JSONValue
        if let found = agent {
            message = found
        } else {
            let error = preview?.raw["error"]
            let hasError = error?.stringValue?.isEmpty == false
            let promptID = prompt?.id ?? JSONText("")
            let key = hasError ? JSONText("error") : JSONText(codeUnits: Array("prompt:".utf16) + promptID.codeUnits)
            message = codexObject([
                "id": .text(codexJSONString(.array([preview?.raw["executionId"] ?? .null, .string(key)]))),
                "text": .string(codexTrim(hasError ? error : prompt?.raw["content"]))
            ])
        }
        let full = codexTrim(message["text"])
        let head = codexHeadPoints(full, limit: 600)
        let excerpt = head.codeUnits.count < full.codeUnits.count
            ? JSONText(codeUnits: head.codeUnits + Array("…".utf16)) : head
        let settings = thread["settings"] ?? .null
        let runtimeModel = codexTrim(turn?.raw["runtimeModel"])
        let settingModel = codexTrim(settings["model"])
        let model = !runtimeModel.codeUnits.isEmpty ? runtimeModel
            : !settingModel.codeUnits.isEmpty ? settingModel : JSONText("未知模型")
        let effort = settings["thinking"].map { value in
            value["mode"]?.stringValue == "effort" ? value["effort"] ?? .text("") : value["mode"] ?? .text("")
        } ?? .text("未选择")
        var identity: [String: JSONValue] = [
            "title": thread["title"] ?? .text(""), "model": .string(model),
            "effort": effort, "excerpt": .string(excerpt), "message": message
        ]
        // A reported null means standard service; only omission falls back.
        let serviceTier = turn?.raw["runtimeServiceTier"] ?? settings["serviceTier"]
        if serviceTier?.stringValue == "priority" { identity["fastMode"] = .bool(true) }
        if let execution = thread["observation"]?["latestExecution"], execution != .null {
            var runtime: [String: JSONValue] = ["startedAt": execution["startedAt"] ?? .number(0)]
            if let endedAt = execution["finishedAt"] { runtime["endedAt"] = endedAt }
            identity["runtime"] = codexObject(runtime)
        }
        if let cwd = thread["cwd"]?.stringValue, !cwd.isEmpty, !isTemporaryWorkspace(cwd) {
            identity["cwd"] = thread["cwd"]
            identity["cwdName"] = .text(cwdName(cwd))
        }
        if let worktree = thread["worktree"], worktree != .null { identity["usesWorktree"] = .bool(true) }
        if let followUp = turn?.messages.last(where: { $0.kind == "follow-up" && !$0.isInternal }) {
            let steer = codexTrim(followUp.raw["content"])
            if !steer.codeUnits.isEmpty { identity["steer"] = .string(steer) }
        }
        let status = overviewStatus(turn)
        return CodexOverviewContent(initialResponseScope: state.initialResponseScope, hasAgentContent: agent != nil, identity: codexObject(identity),
            card: cardProjection(state: state, turn: turn, publicInteractions: publicInteractions),
            status: status, statusLabel: statusLabel(status, turn: turn),
            pendingInteractionID: publicPending.map { $0.codexIdentity("id") })
    }

    static func executionUsage(state: JSONValue, executionID: JSONText) -> HarnessExecutionTokenUsage? {
        let turn = (state["turns"]?.arrayValue ?? []).last(where: { $0["executionId"] == .string(executionID) })
        guard let part = cardUsage(turn?["usage"])?["parts"]?.arrayValue?.first,
              let count = part["numericValue"]?.numberValue else { return nil }
        return HarnessExecutionTokenUsage(value: part.codexIdentity("value"), count: count, suffix: part.codexIdentity("suffix"))
    }

    private static func overviewMessage(_ turns: [CodexTurn]) -> JSONValue? {
        for turn in turns.reversed() {
            if let item = turn.timeline.last(where: {
                (($0.kind == "assistant" && $0.status == "complete") ||
                    ($0.kind == "reasoning" && (turn.active || turn.status == "completed"))) &&
                    !codexTrim($0.raw["content"]).codeUnits.isEmpty
            }) {
                return codexObject([
                    "id": .text(codexJSONString(.array([.string(turn.executionId), .text(item.kind),
                        item.kind == "assistant" ? item.raw["itemId"] ?? .null : .string(item.id)]))),
                    "text": .string(codexTrim(item.raw["content"]))
                ])
            }
            if turn.status == "completed" && !turn.timeline.contains(where: { $0.kind == "assistant" || $0.kind == "reasoning" }) {
                let text = codexTrim(!turn.answer.isEmpty ? turn.raw["answer"] : turn.raw["reasoning"])
                if !text.codeUnits.isEmpty {
                    return codexObject([
                        "id": .text(codexJSONString(.array([.string(turn.executionId), .text("answer")]))),
                        "text": .string(text)
                    ])
                }
            }
        }
        return nil
    }

    private static func cardProjection(state: CodexState, turn: CodexTurn?, publicInteractions: [JSONText: JSONValue]) -> JSONValue {
        guard let turn else { return codexObject(["kind": .text("standard"), "identity": codexObject([:]), "extensions": .array([])]) }
        var extensions: [JSONValue] = []
        let plan = turn.active ? turn.plan : []
        if plan.contains(where: { $0["status"]?.stringValue != "completed" }) {
            extensions.append(codexObject(["kind": .text("todo"), "steps": .array(plan)]))
        }
        if let intervention = pendingIntervention(turn, publicInteractions: publicInteractions) {
            extensions.append(codexObject(["kind": .text("intervention"), "intervention": intervention]))
        }
        var derived: [JSONValue] = []
        if turn.active {
            derived += turn.activities.filter {
                $0.status == "running" && ($0.kind == "agent" || $0.kind == "subagent")
            }.map {
                codexObject(["id": .string($0.id), "label": $0.raw["label"]!, "status": .text($0.status),
                             "kind": .text("agent"), "commandLine": .bool(false)])
            }
        }
        derived += state.backgroundTerminals.map {
            codexObject(["id": $0["id"] ?? .null, "label": $0["command"] ?? .text(""),
                         "status": .text("running"), "kind": .text("shell"), "commandLine": .bool(true)])
        }
        if !derived.isEmpty { extensions.append(codexObject(["kind": .text("derived"), "rows": .array(derived)])) }
        let pending = turn.interactions.filter { $0.status == "pending" && $0.blocksTurn }
        var excludedNames = ["update_plan"] + (pending.isEmpty ? [] : ["request_user_input"])
        for interaction in pending {
            if let detail = interaction.detail, !detail.isEmpty { excludedNames.append(detail) }
            if !interaction.title.isEmpty { excludedNames.append(interaction.title) }
        }
        let excluded = Set(excludedNames.map { JSONText(normalizedToolName($0)) })
        var recent: [JSONValue] = []
        for activity in turn.activities.reversed() where ["command", "file", "search", "tool"].contains(activity.kind) {
            let label = singleLine(activity.label)
            guard !label.isEmpty && !excluded.contains(JSONText(normalizedToolName(label))) else { continue }
            recent.insert(safeTool(kind: activity.kind, label: label, status: activity.status), at: 0)
            if recent.count == 3 { break }
        }
        var identity: [String: JSONValue] = [:]
        if let latest = recent.last { identity["recentTools"] = .array(recent); identity["latestTool"] = latest }
        if let usage = cardUsage(turn.usage) { identity["usage"] = usage }
        return codexObject(["kind": .text("standard"), "identity": codexObject(identity), "extensions": .array(extensions)])
    }

    private static func pendingIntervention(_ turn: CodexTurn, publicInteractions: [JSONText: JSONValue]) -> JSONValue? {
        guard let pending = turn.interactions.first(where: { $0.status == "pending" && $0.blocksTurn }),
              let interaction = publicInteractions[pending.id] else { return nil }
        let actions = interaction["actions"]?.arrayValue ?? []
        var result: [String: JSONValue] = ["id": interaction["id"] ?? .null, "title": interaction["title"] ?? .text("")]
        if let detail = interaction["description"], detail.stringValue?.isEmpty == false { result["detail"] = detail }
        let questions = interaction["questions"]?.arrayValue ?? []
        if pending.kind == "user-input", !questions.isEmpty,
           !questions.contains(where: { $0["secret"]?.boolValue == true }),
           let submit = actions.first(where: { $0["intent"]?.stringValue == "submit" }) {
            result["questions"] = .array(questions.map { question in
                var projected: [String: JSONValue] = [
                    "id": question["id"] ?? .null, "prompt": question["prompt"] ?? .text(""),
                    "multiple": .bool(false), "allowOther": question["allowOther"] ?? .bool(false),
                    "secret": .bool(false), "options": .array((question["options"]?.arrayValue ?? []).map { option in
                        var value: [String: JSONValue] = ["id": option["value"] ?? .null,
                            "value": option["value"] ?? .null, "label": option["label"] ?? .text("")]
                        if let description = option["description"], description.stringValue?.isEmpty == false { value["description"] = description }
                        return codexObject(value)
                    })
                ]
                if let header = question["header"], header.stringValue?.isEmpty == false { projected["header"] = header }
                return codexObject(projected)
            })
            result["submitActionId"] = submit["id"]
            result["actions"] = .array(actions.filter { ["submit", "cancel"].contains($0["intent"]?.stringValue ?? "") }.map(decisionAction))
        } else {
            result["actions"] = .array(interaction["kind"]?.stringValue == "question" ? [] :
                actions.filter { ["allow", "deny", "cancel"].contains($0["intent"]?.stringValue ?? "") }.map(decisionAction))
        }
        return codexObject(result)
    }

    private static func decisionAction(_ action: JSONValue) -> JSONValue {
        codexObject(["id": action["id"] ?? .null, "label": action["label"] ?? .text(""), "intent": action["intent"] ?? .text("")])
    }

    private static func cardUsage(_ usage: JSONValue?) -> JSONValue? {
        guard let usage, usage["inputTokens"] != nil || usage["outputTokens"] != nil else { return nil }
        let total = (usage["inputTokens"]?.numberValue ?? 0) + (usage["outputTokens"]?.numberValue ?? 0)
        return codexObject(["parts": .array([codexObject([
            "id": .text("total"), "suffix": .text("tokens"),
            "description": .text("输入与输出 token 合计，按 Harness 当前上报的统计范围显示"),
            "value": .text(formatTokens(total)), "numericValue": .number(total)
        ])])])
    }

    private static func formatTokens(_ value: Double) -> String {
        if value < 1_000 { return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), floor(value + 0.5)) }
        let (scale, suffix): (Double, String) = value >= 1_000_000_000 ? (1_000_000_000, "B")
            : value >= 1_000_000 ? (1_000_000, "M") : (1_000, "K")
        return fixedOne(value / scale) + suffix
    }

    /// JavaScript toFixed rounds an exact binary halfway value upward; printf
    /// uses ties-to-even (1250 tokens would incorrectly become 1.2K).
    private static func fixedOne(_ value: Double) -> String {
        let bits = value.bitPattern
        let exponent = Int((bits >> 52) & 0x7ff) - 1023 - 52
        let significand = (bits & 0x000f_ffff_ffff_ffff) | (1 << 52)
        let numerator = significand * 10
        if exponent < 0 && exponent > -64 {
            let shift = -exponent
            let whole = numerator >> shift
            let remainder = numerator & ((UInt64(1) << shift) - 1)
            let rounded = whole + (remainder >= (UInt64(1) << (shift - 1)) ? 1 : 0)
            return "\(rounded / 10).\(rounded % 10)"
        }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func safeTool(kind: String, label: String, status: String) -> JSONValue {
        var tool: [String: JSONValue] = ["kind": .text(kind), "status": .text(status)]
        if kind == "command" && (label.hasPrefix("/") || label.contains(" -") || label.contains(" ") || label.contains("|")) {
            tool["name"] = .text("Shell"); tool["summary"] = .text(bounded(label))
        } else if kind == "file" && (label.contains("/") || label.contains("\\")) {
            tool["name"] = .text("File"); tool["summary"] = .text(bounded(label))
        } else { tool["name"] = .text(bounded(label, limit: 48)) }
        return codexObject(tool)
    }

    private static func overviewStatus(_ turn: CodexTurn?) -> CodexOverviewStatus {
        if turn?.interactions.contains(where: { $0.status == "pending" && $0.blocksTurn }) == true { return .attention }
        switch turn?.status {
        case "running", "waiting-input": return .running
        case "failed": return .failed
        case "interrupted": return .cancelled
        case "completed": return .completed
        default: return .idle
        }
    }

    private static func statusLabel(_ status: CodexOverviewStatus, turn: CodexTurn?) -> String {
        switch status {
        case .attention: "需处理"
        case .running: turn?.statusLabel.flatMap { $0.isEmpty ? nil : $0 } ?? "运行中"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        case .idle: "空闲"
        }
    }

    private static func singleLine(_ value: String) -> String {
        let replaced = value.replacingOccurrences(of: "[\\u0009-\\u000D\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+", with: " ", options: .regularExpression)
        return codexTrim(.text(replaced)).string
    }
    private static func normalizedToolName(_ value: String) -> String {
        singleLine(codexTrim(.text(value)).string.lowercased().replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression))
    }
    private static func bounded(_ value: String, limit: Int = 120) -> String {
        let units = Array(value.utf16)
        guard units.count > limit else { return value }
        return codexTrim(.string(JSONText(codeUnits: Array(units.prefix(limit - 1))))).string + "…"
    }
    private static func cwdName(_ path: String) -> String {
        let trimmed = codexTrim(.text(path)).string
        let withoutSeparators = trimmed.replacingOccurrences(of: "[\\\\/]+$", with: "", options: .regularExpression)
        if withoutSeparators.isEmpty { return trimmed }
        if withoutSeparators.range(of: "^[A-Za-z]:$", options: .regularExpression) != nil,
           trimmed.range(of: "^[A-Za-z]:[\\\\/]+$", options: .regularExpression) != nil { return trimmed }
        return withoutSeparators.components(separatedBy: CharacterSet(charactersIn: "/\\")).last(where: { !$0.isEmpty }) ?? trimmed
    }
    private static func isTemporaryWorkspace(_ value: String) -> Bool {
        MokuseiWorkspacePath.isTemporary(codexTrim(.text(value)).string)
    }
}
