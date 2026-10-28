import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Plugin-owned settings retain their lossless JSON representation, including
/// native fields which the four visible controls do not edit.
public struct CodexThreadSettings: Hashable, Sendable {
    public let raw: JSONValue

    public init(_ value: JSONValue = .object([:])) {
        var fields: [JSONText: JSONValue] = [:]
        for key in Self.profileKeys {
            guard let value = value[key] else { continue }
            switch value {
            case .null: continue
            case .string(let text) where text.codeUnits.isEmpty: continue
            default: fields[JSONText(key)] = value
            }
        }
        raw = .object(fields)
    }

    private static let profileKeys = [
        "executablePath", "model", "thinking", "effort", "serviceTier", "personality",
        "approvalPolicy", "approvalsReviewer", "sandbox", "sandboxPolicy", "summary", "permissionMode"
    ]

    public subscript(_ key: String) -> JSONValue? { raw[key] }
    fileprivate func text(_ key: String) -> JSONText? { raw[key]?.codexSettingsText }
    fileprivate func replacing(_ key: String, with value: JSONValue?) -> Self {
        var fields = raw.objectValue ?? [:]
        fields[JSONText(key)] = value
        return Self(.object(fields))
    }
    fileprivate var nativePermissionsConfigured: Bool {
        ["approvalPolicy", "approvalsReviewer", "sandbox", "sandboxPolicy"].contains { raw[$0] != nil }
    }
}

public struct CodexThreadSettingsUpdate: Hashable, Sendable {
    public let raw: JSONValue
    public init(raw: JSONValue) throws {
        guard raw.objectValue != nil else { throw PluginContractError("Codex Thread settings update must be an object") }
        self.raw = raw
    }

    public init(current: CodexThreadSettings, draft: CodexThreadSettings) {
        var changes: [JSONText: JSONValue] = [:]
        for key in ["model", "thinking", "serviceTier", "permissionMode"] where current[key] != draft[key] {
            changes[JSONText(key)] = draft[key] ?? .null
        }
        if current["model"] != draft["model"], let thinking = draft["thinking"] {
            changes["thinking"] = thinking
        }
        raw = .object(changes)
    }
    public var isEmpty: Bool { raw.objectValue?.isEmpty != false }
    public var changesModelSettings: Bool { ["model", "thinking", "serviceTier"].contains { raw[$0] != nil } }
    @MainActor public static var codec: PluginValueCodec<Self> {
        .init(decode: { try Self(raw: $0) }, encode: { $0.raw })
    }
}

public struct CodexHarnessSettings: Hashable, Sendable {
    public let useDefaultThreadSettings: Bool
    public let threadSettings: CodexThreadSettings
    public let isUnconfigured: Bool

    public init(useDefaultThreadSettings: Bool = true, threadSettings: CodexThreadSettings = .init(), isUnconfigured: Bool = false) {
        self.useDefaultThreadSettings = useDefaultThreadSettings
        self.threadSettings = threadSettings
        self.isUnconfigured = isUnconfigured
    }
    public init(raw: JSONValue) throws {
        if raw == .null || raw.objectValue?.isEmpty == true {
            self.init(isUnconfigured: true)
            return
        }
        guard raw.objectValue != nil, let profile = raw["threadSettings"], profile.objectValue != nil else {
            throw PluginContractError("Codex settings require a threadSettings object")
        }
        self.init(useDefaultThreadSettings: raw["useDefaultThreadSettings"]?.boolValue != false,
                  threadSettings: .init(profile))
    }
    public var raw: JSONValue {
        if isUnconfigured { return .null }
        var fields: [JSONText: JSONValue] = ["threadSettings": threadSettings.raw]
        if !useDefaultThreadSettings { fields["useDefaultThreadSettings"] = .bool(false) }
        return .object(fields)
    }
    public func usingDefaults(_ enabled: Bool) -> Self {
        Self(useDefaultThreadSettings: enabled, threadSettings: enabled ? .init() : threadSettings)
    }
    public func changingProfile(_ profile: CodexThreadSettings, executionSnapshot: Bool) -> Self {
        Self(useDefaultThreadSettings: executionSnapshot ? false : useDefaultThreadSettings, threadSettings: profile)
    }
    @MainActor public static var codec: PluginValueCodec<Self> {
        .init(decode: { try Self(raw: $0) }, encode: { $0.raw })
    }
}

public struct CodexSettingsPresentationData: Hashable, Sendable {
    public let raw: JSONValue
    public let cliAvailable: Bool
    public let cliVersion: String?
    public let cliError: String?
    public let modelsError: String?
    fileprivate let models: [CodexSettingsModel]

    public init(raw: JSONValue) throws {
        guard let available = raw["cli"]?["available"]?.boolValue,
              let models = raw["models"]?.arrayValue else {
            throw PluginContractError("Invalid Codex settings presentation")
        }
        self.raw = raw
        cliAvailable = available
        cliVersion = raw["cli"]?["version"]?.stringValue
        cliError = raw["cli"]?["error"]?.stringValue
        modelsError = raw["modelsError"]?.stringValue
        self.models = try models.map(CodexSettingsModel.init)
    }
    @MainActor public static var codec: PluginValueCodec<Self> {
        .init(decode: { try Self(raw: $0) }, encode: { $0.raw })
    }
}

/// The global presentation key has the same ordered fields as renderer
/// composition. Harness identity belongs to the surrounding resource map.
public enum CodexSettingsResourceKeys {
    public static func global(backgroundAgent: JSONValue = .bool(false), executionOwner: JSONValue = .null,
                              cwd: JSONText, settings: JSONValue?) -> JSONValue {
        .array([backgroundAgent, executionOwner, .string(cwd), settings ?? .null])
    }
    public static func thread(id: JSONText, settings: JSONValue) -> JSONValue {
        .array([.string(id), CodexThreadSettings(settings).raw])
    }
    @MainActor public static func recovery(_ resource: HarnessSettingsResource<CodexSettingsPresentationData>) -> JSONValue {
        switch resource.state {
        case .loading: .text("loading")
        case .error(let message): .array([.text("error"), .text(message)])
        case .ready(let value): .array([.text("ready"), value.raw])
        }
    }
}

private struct CodexSettingsOption: Hashable, Sendable, Identifiable {
    let value: JSONText
    var displayName: String?
    var description: String?
    var id: JSONText { value }
    init(value: JSONText, displayName: String? = nil, description: String? = nil) {
        self.value = value; self.displayName = displayName; self.description = description
    }
    init(_ raw: JSONValue) throws {
        guard let value = raw["value"]?.codexSettingsText else { throw PluginContractError("Codex catalog option is missing value") }
        self.init(value: value, displayName: raw["displayName"]?.stringValue, description: raw["description"]?.stringValue)
    }
}

private struct CodexSettingsModel: Hashable, Sendable, Identifiable {
    let value: JSONText
    let displayName: String
    let description: String?
    let thinking: JSONValue
    let efforts: [CodexSettingsOption]
    let tiers: [CodexSettingsOption]
    let defaultEffort: JSONText?
    let defaultTier: JSONText?
    var id: JSONText { value }

    init(_ raw: JSONValue) throws {
        guard let value = raw["value"]?.codexSettingsText,
              let displayName = raw["displayName"]?.stringValue,
              let thinking = raw["thinking"], thinking.objectValue != nil,
              let efforts = raw["supportedReasoningEfforts"]?.arrayValue,
              let tiers = raw["serviceTiers"]?.arrayValue else {
            throw PluginContractError("Invalid Codex model option")
        }
        self.value = value; self.displayName = displayName
        description = raw["description"]?.stringValue; self.thinking = thinking
        self.efforts = try efforts.map(CodexSettingsOption.init)
        self.tiers = try tiers.map(CodexSettingsOption.init)
        defaultEffort = raw["defaultReasoningEffort"]?.codexSettingsText
        defaultTier = raw["defaultServiceTier"] == .null ? "default" : raw["defaultServiceTier"]?.codexSettingsText
    }
    var thinkingKind: String { thinking["kind"]?.stringValue ?? "unknown" }
    var thinkingChoices: [JSONValue] {
        switch thinkingKind {
        case "effort":
            var choices: [JSONValue] = thinking["canDisable"]?.boolValue == true ? [.object(["mode": .text("off")])] : []
            var seen = Set<JSONText>()
            for effort in thinking["efforts"]?.arrayValue ?? [] {
                guard let value = effort.codexSettingsText, seen.insert(value).inserted else { continue }
                choices.append(.object(["mode": .text("effort"), "effort": effort]))
            }
            return choices
        case "toggle": return [.object(["mode": .text("off")]), .object(["mode": .text("on")])]
        case "fixed": return [.object(["mode": .text("fixed")])]
        default: return []
        }
    }
    var effectiveEfforts: [JSONText] {
        guard thinkingKind == "effort" else { return [] }
        let efforts = (thinking["efforts"]?.arrayValue ?? []).compactMap(\.codexSettingsText).filter { $0 != "none" }
        return efforts + (thinking["canDisable"]?.boolValue == true ? ["none"] : [])
    }
}

/// This plugin surface is exported for composition, without introducing a
/// visible Thread-settings entry in the host.
@MainActor
public struct CodexThreadSettingsView: View {
    public let input: HarnessThreadInput
    public let resource: HarnessSettingsResource<CodexSettingsPresentationData>
    public let update: (CodexThreadSettingsUpdate) async throws -> Void
    @State private var draft: CodexThreadSettings
    @State private var saving = false
    @State private var error: String?
    @Environment(\.locale) private var locale

    public init(input: HarnessThreadInput, resource: HarnessSettingsResource<CodexSettingsPresentationData>,
                update: @escaping (CodexThreadSettingsUpdate) async throws -> Void) {
        self.input = input; self.resource = resource; self.update = update
        _draft = State(initialValue: .init(input.thread.settings))
    }

    private var current: CodexThreadSettings { .init(input.thread.settings) }
    private var change: CodexThreadSettingsUpdate { .init(current: current, draft: draft) }
    private var models: [CodexSettingsModel] {
        if case .ready(let data) = resource.state { return data.models }
        return []
    }
    private var complete: Bool {
        guard let model = models.first(where: { $0.value == draft.text("model") }), let choice = draft["thinking"] else { return false }
        return model.thinkingChoices.contains { codexThinkingKey($0) == codexThinkingKey(choice) }
    }
    private var executionActive: Bool { input.thread.observation.isExecutionActive }
    private var canSave: Bool { !saving && !executionActive && !change.isEmpty && (!change.changesModelSettings || complete) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CodexResourceStatus(resource: resource, page: false)
            CodexSettingsSection(title: t("Thread 配置"), description: t("保存后的设置在下一次 Codex 操作时生效；Primary Native Session 不会被替换。"), page: false) {
                CodexProfileFields(value: draft, models: models, disabled: saving || executionActive,
                                   explicitThinking: true, executionSnapshot: false, page: false,
                                   label: t("Codex Thread"), change: { draft = $0 })
            }
            if executionActive {
                CodexSettingsNotice(message: t("该 Thread 正在运行，请等待完成或停止后再修改。"), tone: .warning)
            }
            if let error { CodexSettingsNotice(message: error, tone: .error) }
            HStack {
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if saving { ProgressView().controlSize(.mini) }
                        Text(t(saving ? "保存中…" : "应用 Thread 配置"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .onChange(of: CodexSettingsResourceKeys.thread(id: input.thread.id, settings: current.raw)) {
            draft = current; error = nil
        }
    }
    private func save() async {
        guard canSave else { return }
        let request = change
        saving = true; error = nil
        defer { saving = false }
        do { try await update(request) }
        catch { self.error = error.localizedDescription }
    }
    private func t(_ source: String) -> String { codexSettingsTranslate(source, locale: locale) }
}

@MainActor
public struct CodexHarnessSettingsView: View {
    public let props: HarnessSettingsProps<CodexHarnessSettings, CodexSettingsPresentationData>
    @State private var lastReady: CodexStableModels?
    @State private var pendingProfile: CodexThreadSettings?
    @Environment(\.locale) private var locale

    public init(props: HarnessSettingsProps<CodexHarnessSettings, CodexSettingsPresentationData>) { self.props = props }
    private var cwd: JSONText { props.host?.cwd ?? "" }
    private var models: [CodexSettingsModel] {
        switch props.resource.state {
        case .ready(let data): data.models
        case .loading: lastReady?.cwd == cwd ? lastReady?.models ?? [] : []
        case .error: []
        }
    }
    private var resourceIdentity: JSONValue { .array([.string(cwd), CodexSettingsResourceKeys.recovery(props.resource)]) }
    private var showResourceStatus: Bool {
        if case .ready(let value) = props.resource.state { return !value.cliAvailable || value.modelsError?.isEmpty == false }
        return true
    }
    private var awaitingSnapshot: Bool {
        guard props.executionSnapshot && props.value.isUnconfigured else { return false }
        if case .ready = props.resource.state { return false }
        return true
    }
    public var body: some View {
        Group {
            if awaitingSnapshot {
                switch props.resource.state {
                case .error(let message):
                    CodexSettingsNotice(message: message, tone: .error, actionTitle: t("重试")) {
                        Task { try? await props.resource.reload(refresh: true) }
                    }
                default:
                    CodexSettingsNotice(message: t("正在读取并固定运行配置…"))
                }
            } else if props.section == .cli {
                CodexCLISettings(resource: props.resource, page: props.settingsFormPage)
            } else {
                VStack(alignment: .leading, spacing: props.settingsFormPage ? 0 : 16) {
                    if showResourceStatus { CodexResourceStatus(resource: props.resource, page: props.settingsFormPage) }
                    CodexSettingsSection(
                        title: t(props.executionSnapshot ? "Codex 运行配置" : "Codex Thread 默认配置"),
                        description: t(props.executionSnapshot ? "运行配置会明确保存，修改后从下一次运行生效。" : "用于新建 Thread 的原生配置默认值。"),
                        page: props.settingsFormPage
                    ) {
                        if props.settingsFormPage && !props.executionSnapshot {
                            CodexSettingsField(label: t("使用默认配置"), description: t("关闭后可自定义新建 Thread 使用的配置。"), page: true, inlineControl: true) {
                                NativeSettingsToggle(value: Binding(get: { props.value.useDefaultThreadSettings }, set: { props.change(props.value.usingDefaults($0)) }))
                            }
                        }
                        if !props.settingsFormPage || props.executionSnapshot || !props.value.useDefaultThreadSettings {
                            CodexProfileFields(value: pendingProfile ?? props.value.threadSettings, models: models, disabled: false,
                                               explicitThinking: false, executionSnapshot: props.executionSnapshot,
                                               page: props.settingsFormPage,
                                               label: t(props.executionSnapshot ? "Codex 运行配置" : "Codex Thread 默认配置")) { profile in
                                changeProfile(profile)
                            }
                            if pendingProfile != nil { NativeSettingsNotice(message: t("请补全模型相关配置；完成前不会保存此组修改。"), kind: .warning) }
                        }
                    }
                }
            }
        }
        .onChange(of: resourceIdentity, initial: true) {
            switch props.resource.state {
            case .ready(let data): lastReady = .init(cwd: cwd, models: data.models)
            case .loading: if lastReady?.cwd != cwd { lastReady = nil }
            case .error: lastReady = nil
            }
        }
        .onChange(of: cwd) { _, _ in pendingProfile = nil }
    }
    private func changeProfile(_ profile: CodexThreadSettings) {
        if props.executionSnapshot {
            let selected = models.first { $0.value == profile.text("model") }
            let complete = profile.text("model") != nil && profile.text("serviceTier") != nil && profile.text("permissionMode") != nil &&
                (selected?.thinkingKind == "fixed" || profile.text("effort") != nil)
            if !complete { pendingProfile = profile; return }
        }
        pendingProfile = nil
        props.change(props.value.changingProfile(profile, executionSnapshot: props.executionSnapshot))
    }
    private func t(_ source: String) -> String { codexSettingsTranslate(source, locale: locale) }
}

private struct CodexStableModels {
    let cwd: JSONText
    let models: [CodexSettingsModel]
}

private struct CodexProfileFields: View {
    let value: CodexThreadSettings
    let models: [CodexSettingsModel]
    let disabled: Bool
    let explicitThinking: Bool
    let executionSnapshot: Bool
    let page: Bool
    let label: String
    let change: (CodexThreadSettings) -> Void
    @Environment(\.locale) private var locale

    private var selected: CodexSettingsModel? { models.first { $0.value == value.text("model") } }
    private var choices: [JSONValue] { explicitThinking ? selected?.thinkingChoices ?? [] : [] }
    private var fixedEffort: Bool { selected?.thinkingKind == "fixed" }
    private var capabilityUnavailable: Bool { executionSnapshot && !fixedEffort && selected?.thinkingKind != "effort" }
    private var effortUnavailableReason: String? {
        guard capabilityUnavailable else { return nil }
        return selected?.thinkingKind == "unknown" ? selected?.thinking["reason"]?.stringValue : t("无法确认此模型的推理强度能力。")
    }
    private var efforts: [CodexSettingsOption] {
        let native = uniqueOptions(selected?.efforts ?? models.flatMap(\.efforts), configured: value.text("effort"))
        guard executionSnapshot else { return native }
        var seen = Set<JSONText>()
        return ((selected?.effectiveEfforts ?? []) + [value.text("effort")].compactMap { $0 }).compactMap { key in
            guard seen.insert(key).inserted else { return nil }
            return native.first { $0.value == key } ?? .init(value: key)
        }
    }
    private var tiers: [CodexSettingsOption] {
        let tiers = uniqueOptions(selected?.tiers ?? models.flatMap(\.tiers), configured: value.text("serviceTier"))
        return executionSnapshot && !tiers.contains(where: { $0.value == "default" }) ? [.init(value: "default")] + tiers : tiers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: page ? 0 : 14) {
            CodexSettingsField(label: t("模型"), description: page ? nil : selected?.description, page: page) {
                NativeModelSelector(value: binding("model", setter: selectModel), options: modelOptions,
                                    accessibilityLabel: label + " " + t("模型")).nativeSettingsControl("model")
                    .disabled(disabled)
            }
            if explicitThinking { thinkingField } else { effortField }
            if page, let effortUnavailableReason, !effortUnavailableReason.isEmpty {
                NativeSettingsNotice(message: effortUnavailableReason, kind: .warning)
            }
            CodexSettingsField(label: t("服务层级"), page: page) {
                CodexSettingsSelect(page: page, label: label + " " + t("服务层级"),
                                    selection: binding("serviceTier"), options: tierOptions).nativeSettingsControl("serviceTier")
                    .disabled(disabled)
            }
            CodexSettingsField(label: t("权限模式"), page: page) {
                CodexSettingsSelect(page: page, label: label + " " + t("权限模式"),
                                    selection: binding("permissionMode"), options: permissionOptions)
                    .disabled(disabled)
            }
        }
    }

    private var modelOptions: [NativeSettingsOption] {
        var options: [NativeSettingsOption] = []
        if !executionSnapshot || value.text("model") == nil {
            options.append(.init(id: "", label: t(explicitThinking || executionSnapshot ? "请选择模型" : "跟随 Codex 默认模型"),
                                 disabled: explicitThinking || executionSnapshot))
        }
        if let model = value.text("model"), selected == nil {
            options.append(.init(id: model, label: model.string + " · " + t("目录中不可用")))
        }
        return options + models.map { .init(id: $0.value, label: $0.displayName) }
    }

    private var thinkingOptions: [NativeSettingsOption] {
        var options: [NativeSettingsOption] = [
            .init(id: "", label: t(selected?.thinkingKind == "unknown" ? "Thinking 能力未知，无法执行" : "请选择 Thinking"), disabled: true)
        ]
        if let configured = value["thinking"], !choices.contains(where: { codexThinkingKey($0) == codexThinkingKey(configured) }) {
            options.append(.init(id: codexThinkingKey(configured), label: codexThinkingLabel(configured) + " · " + t("目录中不可用"), disabled: true))
        }
        return options + choices.map { .init(id: codexThinkingKey($0), label: codexThinkingLabel($0)) }
    }

    private var effortOptions: [NativeSettingsOption] {
        var options: [NativeSettingsOption] = []
        if !executionSnapshot {
            options.append(.init(id: "", label: t("模型默认")))
        } else if fixedEffort || value.text("effort") == nil {
            options.append(.init(id: "", label: t(fixedEffort ? "模型不提供推理强度配置" : capabilityUnavailable ? "推理强度能力不可确认" : "请选择推理强度"),
                                 disabled: !fixedEffort))
        }
        return options + efforts.map { option in
            .init(id: option.value, label: option.value.string
                  + (executionSnapshot && selected != nil && !(selected?.effectiveEfforts.contains(option.value) ?? false) ? " · " + t("目录中不可用") : ""))
        }
    }

    private var tierOptions: [NativeSettingsOption] {
        var options: [NativeSettingsOption] = []
        if !executionSnapshot || value.text("serviceTier") == nil {
            options.append(.init(id: "", label: t(executionSnapshot ? "请选择服务层级" : "模型默认"), disabled: executionSnapshot))
        }
        return options + tiers.map { .init(id: $0.value, label: tierLabel($0)) }
    }

    private var permissionOptions: [NativeSettingsOption] {
        var options: [NativeSettingsOption] = []
        if !executionSnapshot || value.text("permissionMode") == nil {
            options.append(.init(id: "", label: t(executionSnapshot ? "请选择权限模式" : value.nativePermissionsConfigured ? "Mokusei 默认" : "Mokusei 默认（approve-for-me）"),
                                 disabled: executionSnapshot))
        }
        return options + [
            .init(id: "ask-for-approval", label: t("ask-for-approval · 按需询问用户")),
            .init(id: "approve-for-me", label: t("approve-for-me · 原生自动审批")),
            .init(id: "full-access", label: t("full-access · 完全访问"))
        ]
    }

    private var modelLink: NativeModelSelector.ModelLink {
        .init(value: binding("model", setter: selectModel), options: modelOptions, label: t("模型"))
    }

    private var thinkingField: some View {
        CodexSettingsField(label: "Thinking", description: page ? nil : selected?.thinking["reason"]?.stringValue, page: page) {
            NativeModelSelector(value: Binding(
                get: { value["thinking"].map(codexThinkingKey) ?? "" },
                set: { key in
                    if let choice = choices.first(where: { codexThinkingKey($0) == key }) { update("thinking", choice) }
                }), options: thinkingOptions, presentation: .reasoning, model: modelLink,
                accessibilityLabel: label + " Thinking").nativeSettingsControl("thinking")
                .disabled(disabled || choices.isEmpty)
        }
    }
    private var effortField: some View {
        CodexSettingsField(label: t("推理强度"), description: page ? nil : effortUnavailableReason ?? efforts.first(where: { $0.value == value.text("effort") })?.description, page: page) {
            NativeModelSelector(value: binding("effort"), options: effortOptions,
                                presentation: .reasoning, model: modelLink, accessibilityLabel: label + " " + t("推理强度")).nativeSettingsControl("effort")
                .disabled(disabled || capabilityUnavailable || (executionSnapshot && fixedEffort && value.text("effort") == nil))
        }
    }
    private func tierLabel(_ tier: CodexSettingsOption) -> String {
        let title = executionSnapshot && tier.value == "default" ? t("标准")
            : tier.displayName.flatMap { $0.isEmpty ? nil : $0 + " · " + tier.value.string } ?? tier.value.string
        return title + (executionSnapshot && tier.value != "default" && selected != nil && !(selected?.tiers.contains { $0.value == tier.value } ?? false) ? " · " + t("目录中不可用") : "")
    }
    private func binding(_ key: String, setter: ((JSONText) -> Void)? = nil) -> Binding<JSONText> {
        Binding(get: { value.text(key) ?? "" }, set: { text in
            if let setter { setter(text) } else { update(key, text.codeUnits.isEmpty ? nil : .string(text)) }
        })
    }
    private func selectModel(_ text: JSONText) {
        let model: JSONValue? = text.codeUnits.isEmpty ? nil : .string(text)
        var next = value.replacing("model", with: model)
        if explicitThinking && model != value["model"] { next = next.replacing("thinking", with: nil) }
        if let option = models.first(where: { $0.value == text }) {
            let efforts = executionSnapshot ? option.effectiveEfforts : option.efforts.map(\.value)
            if !efforts.contains(next.text("effort") ?? "") {
                let fallback = executionSnapshot ? option.defaultEffort.flatMap { efforts.contains($0) ? $0 : nil } : nil
                next = next.replacing("effort", with: fallback.map(JSONValue.string))
            }
            if !(executionSnapshot && next.text("serviceTier") == "default"), !option.tiers.contains(where: { $0.value == next.text("serviceTier") }) {
                let fallback = executionSnapshot ? option.defaultTier.flatMap { tier in tier == "default" || option.tiers.contains { $0.value == tier } ? tier : nil } : nil
                next = next.replacing("serviceTier", with: fallback.map(JSONValue.string))
            }
        }
        change(next)
    }
    private func update(_ key: String, _ next: JSONValue?) { change(value.replacing(key, with: next)) }
    private func t(_ source: String) -> String { codexSettingsTranslate(source, locale: locale) }
}

/// Full-window settings use the shared sf-select presentation. The exported
/// legacy Thread surface retains its original separate select appearance.
private struct CodexSettingsSelect: View {
    let page: Bool
    let label: String
    let selection: Binding<JSONText>
    let options: [NativeSettingsOption]
    var body: some View {
        Group {
            if page {
                NativeSettingsSelect(value: selection, options: options, accessibilityLabel: label)
            } else {
                Picker(label, selection: selection) {
                    ForEach(options) { option in
                        Text(option.label).tag(option.id).disabled(option.disabled)
                    }
                }.labelsHidden().pickerStyle(.menu).controlSize(.small)
            }
        }.accessibilityLabel(label)
    }
}

private struct CodexSettingsField<Content: View>: View {
    let label: String
    var description: String?
    let page: Bool
    var inlineControl = false
    @ViewBuilder let content: Content
    var body: some View {
        Group {
            if page {
                NativeSettingsRow(label: label, description: description, inlineControl: inlineControl) { content }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(label).font(.system(size: 11, weight: .medium))
                    content.frame(maxWidth: .infinity, alignment: .leading)
                    if let description { Text(description).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
    }
}

private struct CodexSettingsSection<Content: View>: View {
    let title: String
    let description: String
    let page: Bool
    @ViewBuilder let content: Content
    var body: some View {
        Group {
            if page {
                NativeSettingsGroup { content }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Text(description).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    content
                }
            }
        }
    }
}

private enum CodexNoticeTone { case info, success, warning, error }
private struct CodexSettingsNotice: View {
    let message: String
    var tone: CodexNoticeTone = .info
    var loading = false
    var actionTitle: String?
    var action: (() -> Void)?
    private var color: Color {
        switch tone { case .info: .secondary; case .success: .green; case .warning: .orange; case .error: .red }
    }
    var body: some View {
        HStack(spacing: 7) {
            if loading { ProgressView().controlSize(.mini) }
            else { Image(systemName: tone == .success ? "checkmark" : tone == .info ? "info.circle" : "exclamationmark.circle").font(.system(size: 13)) }
            Text(message).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action { Button(actionTitle, systemImage: "arrow.clockwise", action: action).buttonStyle(.borderless) }
        }
        .font(.system(size: 10)).foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.22)))
        .accessibilityElement(children: .contain)
    }
}

private struct CodexResourceStatus: View {
    let resource: HarnessSettingsResource<CodexSettingsPresentationData>
    let page: Bool
    @Environment(\.locale) private var locale
    var body: some View {
        if page { pageStatus } else { legacyStatus }
    }
    @ViewBuilder private var pageStatus: some View {
        switch resource.state {
        case .loading:
            EmptyView()
        case .error(let error):
            NativeSettingsNotice(message: error, kind: .error, action: pageReload(t("重试")),
                                 leading: AnyView(NativeIcon(name: "CircleAlert", size: 13)))
        case .ready(let data):
            NativeSettingsNotice(
                message: data.cliAvailable ? t("已读取 Codex 环境")
                    : data.cliError.flatMap { $0.isEmpty ? nil : $0 } ?? t("Codex CLI 不可用"),
                kind: data.cliAvailable ? .success : .warning, action: pageReload(t("刷新")),
                leading: AnyView(NativeIcon(name: data.cliAvailable ? "Check" : "CircleAlert", size: 13)))
            if let error = data.modelsError, !error.isEmpty {
                NativeSettingsNotice(message: error, kind: .error,
                                     leading: AnyView(NativeIcon(name: "CircleAlert", size: 13)))
            }
        }
    }
    private func pageReload(_ label: String) -> AnyView {
        AnyView(CodexSettingsPageAction(label: label, action: reload))
    }
    @ViewBuilder private var legacyStatus: some View {
        switch resource.state {
        case .loading:
            CodexSettingsNotice(message: t("正在读取 Codex 环境…"), loading: true)
        case .error(let error):
            CodexSettingsNotice(message: error, tone: .error, actionTitle: t("重试"), action: reload)
        case .ready(let data):
            CodexSettingsNotice(message: data.cliAvailable ? t("已读取 Codex 环境") : data.cliError ?? t("Codex CLI 不可用"),
                                tone: data.cliAvailable ? .success : .error, actionTitle: t("刷新"), action: reload)
            if let error = data.modelsError { CodexSettingsNotice(message: error, tone: .error) }
        }
    }
    private func reload() { Task { try? await resource.reload(refresh: true) } }
    private func t(_ source: String) -> String { codexSettingsTranslate(source, locale: locale) }
}

private struct CodexSettingsPageAction: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(label, systemImage: "arrow.clockwise", action: action).buttonStyle(.bordered)
    }
}

private struct CodexCLISettings: View {
    let resource: HarnessSettingsResource<CodexSettingsPresentationData>
    let page: Bool
    @Environment(\.locale) private var locale
    private var presentation: CodexSettingsPresentationData? {
        if case .ready(let data) = resource.state { return data }
        return nil
    }
    private var status: String {
        switch resource.state {
        case .loading: t("正在读取 Codex 环境…")
        case .error(let message): message
        case .ready(let data): data.cliAvailable
            ? data.cliVersion.flatMap { $0.isEmpty ? nil : $0 } ?? t("已读取 Codex 环境")
            : data.cliError.flatMap { $0.isEmpty ? nil : $0 } ?? t("Codex CLI 不可用")
        }
    }
    private var tone: NativeSettingsNotice.Kind {
        if case .error = resource.state { return .error }
        return presentation?.cliAvailable == true ? .success : .warning
    }
    private var loading: Bool { if case .loading = resource.state { return true }; return false }
    var body: some View {
        Group {
            if page {
                NativeSettingsCliStatus(label: "Codex CLI", status: status, kind: tone, error: presentation?.modelsError)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        CodexLogo(size: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Codex CLI").font(.system(size: 12, weight: .semibold))
                            HStack(spacing: 5) {
                                if loading { ProgressView().controlSize(.mini) }
                                else if presentation?.cliAvailable == true { Image(systemName: "checkmark") }
                                Text(status)
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(presentation?.cliAvailable == true ? Color.green : .secondary)
                        }
                        Spacer()
                        Button(t("刷新"), systemImage: "arrow.clockwise") { Task { try? await resource.reload() } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(loading)
                            .accessibilityLabel(t("刷新 Codex CLI 环境"))
                    }
                    if let error = presentation?.modelsError { CodexSettingsNotice(message: error, tone: .error) }
                }
            }
        }
    }
    private func t(_ source: String) -> String { codexSettingsTranslate(source, locale: locale) }
}

private extension JSONValue {
    var codexSettingsText: JSONText? { if case .string(let value) = self { return value }; return nil }
}

private func codexThinkingKey(_ choice: JSONValue) -> JSONText {
    if choice["mode"]?.stringValue == "effort" {
        return JSONText(codeUnits: Array("effort:".utf16) + (choice["effort"]?.codexSettingsText?.codeUnits ?? []))
    }
    return choice["mode"]?.codexSettingsText ?? ""
}
private func codexThinkingLabel(_ choice: JSONValue) -> String {
    choice["mode"]?.stringValue == "effort" ? choice["effort"]?.stringValue ?? "" : choice["mode"]?.stringValue ?? ""
}
private func uniqueOptions(_ options: [CodexSettingsOption], configured: JSONText?) -> [CodexSettingsOption] {
    var keys: [JSONText] = []
    var values: [JSONText: CodexSettingsOption] = [:]
    for option in options {
        if values[option.value] == nil { keys.append(option.value) }
        values[option.value] = option
    }
    if let configured, values[configured] == nil { keys.append(configured); values[configured] = .init(value: configured) }
    return keys.compactMap { values[$0] }
}

private func codexSettingsTranslate(_ source: String, locale: Locale) -> String {
    guard locale.language.languageCode?.identifier == "en" else { return source }
    return codexSettingsEnglish[source] ?? source
}
private let codexSettingsEnglish: [String: String] = [
    "请补全模型相关配置；完成前不会保存此组修改。": "Complete the model settings to save these changes.",
    "Thread 配置": "Thread configuration", "模型": "Model", "推理强度": "Reasoning effort", "权限模式": "Permission mode",
    "保存后的设置在下一次 Codex 操作时生效；Primary Native Session 不会被替换。": "Saved settings take effect on the next Codex operation; the primary native session is preserved.",
    "该 Thread 正在运行，请等待完成或停止后再修改。": "This thread is running. Wait for it to finish or stop it before editing.",
    "保存中…": "Saving…", "应用 Thread 配置": "Apply thread configuration", "使用默认配置": "Use defaults",
    "关闭后可自定义新建 Thread 使用的配置。": "Turn off to customize the configuration for new threads.",
    "用于新建 Thread 的原生配置默认值。": "Native defaults for new threads.",
    "跟随 Codex 默认模型": "Use the Codex default model", "请选择模型": "Select a model", "请选择 Thinking": "Select thinking",
    "Thinking 能力未知，无法执行": "Thinking capability is unknown; execution is unavailable", "服务层级": "Service tier",
    "Mokusei 默认": "Mokusei default", "Mokusei 默认（approve-for-me）": "Mokusei default (approve-for-me)",
    "ask-for-approval · 按需询问用户": "ask-for-approval · ask the user as needed", "approve-for-me · 原生自动审批": "approve-for-me · native auto review",
    "full-access · 完全访问": "full-access · full access", "正在读取 Codex 环境…": "Loading the Codex environment…",
    "已读取 Codex 环境": "Codex environment loaded", "Codex CLI 不可用": "Codex CLI unavailable",
    "Codex Thread 默认配置": "Codex Thread defaults", "Codex 运行配置": "Codex execution configuration",
    "无法确认此模型的推理强度能力。": "The reasoning effort capabilities of this model could not be confirmed.",
    "推理强度能力不可确认": "Reasoning effort capabilities could not be confirmed",
    "运行配置会明确保存，修改后从下一次运行生效。": "Execution settings are saved explicitly. Changes take effect on the next run.",
    "正在读取并固定运行配置…": "Loading and fixing the execution configuration…",
    "模型不提供推理强度配置": "Reasoning effort is not configurable for this model", "请选择推理强度": "Select reasoning effort",
    "请选择服务层级": "Select a service tier", "请选择权限模式": "Select a permission mode", "标准": "Standard", "Codex Thread": "Codex thread",
    "模型默认": "Model default", "目录中不可用": "Unavailable in catalog", "刷新": "Refresh", "重试": "Retry",
    "刷新 Codex CLI 环境": "Refresh Codex CLI environment"
]
