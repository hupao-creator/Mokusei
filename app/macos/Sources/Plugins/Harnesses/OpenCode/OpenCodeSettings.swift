import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

public struct OpenCodeThreadSettingsUpdate: Hashable, Sendable {
    public let raw: JSONValue
    public init(raw: JSONValue) throws {
        try ocOnly(raw, ["provider", "model", "agent", "thinking", "permissionMode"])
        for key in ["provider", "model", "agent", "permissionMode"] { if let field = raw[key], field != .null, field.ocString == nil { throw OpenCodeError.invalidSettings } }
        if let thinking = raw["thinking"] { try ocValidateThinking(thinking) }
        if let permission = raw["permissionMode"], permission != .null, !["auto", "default"].contains(permission.stringValue ?? "") { throw OpenCodeError.invalidSettings }
        self.raw = raw
    }
    @MainActor public static var codec: PluginValueCodec<Self> { .init(decode: { try Self(raw: $0) }, encode: { $0.raw }) }
}
public struct OpenCodeHarnessSettings: Hashable, Sendable {
    public let raw: JSONValue
    public init(raw: JSONValue = .object(["threadSettings": .object([:])])) throws {
        let raw = raw == .null || raw.objectValue?.isEmpty == true ? JSONValue.object(["threadSettings": .object([:])]) : raw
        try ocOnly(raw, ["threadSettings", "useDefaultThreadSettings"])
        guard let profile = raw["threadSettings"], profile.objectValue != nil else { throw OpenCodeError.invalidSettings }
        try ocOnly(profile, ["provider", "model", "agent", "variant", "permissionMode"])
        try ocOptionalText(profile, ["provider", "model", "agent", "variant", "permissionMode"])
        if let permission = profile["permissionMode"], !["auto", "default"].contains(permission.stringValue ?? "") { throw OpenCodeError.invalidSettings }
        if let defaults = raw["useDefaultThreadSettings"], defaults.boolValue == nil { throw OpenCodeError.invalidSettings }
        self.raw = raw
    }
    public var threadSettings: JSONValue { raw["threadSettings"] ?? .object([:]) }
    public var useDefaultThreadSettings: Bool { raw["useDefaultThreadSettings"] != .bool(false) }
    @MainActor public static var codec: PluginValueCodec<Self> { .init(decode: { try Self(raw: $0) }, encode: { $0.raw }) }
}
public struct OpenCodeSettingsPresentationData: Hashable, Sendable {
    public let raw: JSONValue
    public init(raw: JSONValue) throws {
        try ocOnly(raw, ["cli", "models", "agents", "effectiveModel", "accountCheckPending"])
        guard let cli = raw["cli"], ["ready", "unavailable"].contains(cli["status"]?.stringValue ?? ""),
              let models = raw["models"]?.arrayValue, let agents = raw["agents"]?.arrayValue else { throw OpenCodeError.invalidSettings }
        if let pending = raw["accountCheckPending"], pending.boolValue == nil { throw OpenCodeError.invalidSettings }
        try ocOnly(cli, ["status", "executablePath", "version", "message"]); try ocOptionalText(cli, ["executablePath", "version", "message"])
        for model in models {
            for key in ["provider", "id", "name"] { _ = try ocRequiredText(model, key) }
            guard model["variants"]?.arrayValue != nil, model["input"]?.arrayValue?.allSatisfy({ $0.ocString != nil }) == true,
                  model["output"]?.arrayValue?.allSatisfy({ $0.ocString != nil }) == true else { throw OpenCodeError.invalidSettings }
        }
        for agent in agents { _ = try ocRequiredText(agent, "id"); _ = try ocRequiredText(agent, "name")
            guard ["primary", "subagent", "all"].contains(agent["mode"]?.stringValue ?? "") else { throw OpenCodeError.invalidSettings }
        }
        self.raw = raw
    }
    var models: [JSONValue] { raw["models"]?.arrayValue ?? [] }
    var agents: [JSONValue] { raw["agents"]?.arrayValue ?? [] }
    @MainActor public static var codec: PluginValueCodec<Self> { .init(decode: { try Self(raw: $0) }, encode: { $0.raw }) }
}
private func ocValidateThinking(_ value: JSONValue) throws {
    guard let mode = value["mode"]?.stringValue, ["fixed", "on", "off", "effort"].contains(mode) else { throw OpenCodeError.invalidSettings }
    try ocOnly(value, mode == "effort" ? ["mode", "effort"] : ["mode"])
    if mode == "effort" {
        let effort = try ocRequiredText(value, "effort", nonempty: true)
        guard effort.codeUnits.count <= 64, effort.string == ocTrim(effort.string), effort.string.lowercased() != "default" else { throw OpenCodeError.invalidSettings }
    }
}
func ocCleanSettings(_ raw: JSONValue) -> JSONValue {
    var result: [JSONText: JSONValue] = [:]
    for key in ["provider", "model", "agent", "variant", "permissionMode", "thinking"] {
        if let value = raw[key], value != .null, value != .text("") { result[JSONText(key)] = value }
    }
    return .object(result)
}
private func ocReplacing(_ raw: JSONValue, key: String, value: JSONValue?) -> JSONValue {
    var result = raw.objectValue ?? [:]; result[JSONText(key)] = value; return ocCleanSettings(.object(result))
}
func ocThinkingCapability(model: JSONValue, agent: JSONValue?) -> JSONValue {
    func unknown(_ reason: String) -> JSONValue { .object(["kind": .text("unknown"), "reason": .text(reason)]) }
    if let unavailable = model["unavailableReason"]?.stringValue, !unavailable.isEmpty { return unknown(unavailable) }
    let overridden = ["model", "messages", "input", "tools", "tool_choice", "thinking", "reasoning", "reasoning_effort", "output_config", "generationConfig", "enable_thinking", "thinking_budget", "chat_template_kwargs"]
    if agent?["hasRequestOverrides"] == .bool(true) || overridden.contains(where: { agent?["body"]?[$0] != nil }) { return unknown("The selected OpenCode agent overrides model, account, or thinking request fields") }
    if let native = model["thinking"], native != .null { return native }
    if model["hasRequestOverrides"] == .bool(true) { return unknown("OpenCode custom request fields can replace the selected model or thinking choice") }
    let variants = (model["variants"]?.arrayValue ?? []).filter { $0["id"] != .text("default") }
    if variants.isEmpty { return .object(["kind": .text("fixed")]) }
    let controls = variants.map { ocVariantControl(model, variant: $0) }
    if controls.contains(where: { $0 == nil }) { return unknown("OpenCode returned a variant without a verified thinking encoding") }
    let off = controls.contains { $0?["mode"] == .text("off") }
    let on = controls.contains { $0?["mode"] == .text("on") }
    var efforts: [JSONText] = []
    for control in controls { if control?["mode"] == .text("effort"), let effort = control?.ocText("effort"), !efforts.contains(effort) { efforts.append(effort) } }
    if !efforts.isEmpty { return .object(["kind": .text("effort"), "efforts": .array(efforts.map(JSONValue.string)), "canDisable": .bool(off)]) }
    if off && on { return .object(["kind": .text("toggle")]) }
    return unknown("OpenCode does not expose a complete adjustable thinking control")
}
private func ocVariantControl(_ model: JSONValue, variant: JSONValue) -> JSONValue? {
    func merge(_ left: JSONValue?, _ right: JSONValue?) -> JSONValue {
        var value = left?.objectValue ?? [:]
        for (key, next) in right?.objectValue ?? [:] { value[key] = next.objectValue == nil ? next : merge(value[key], next) }
        return .object(value)
    }
    let settings = merge(model["settings"], variant["settings"]), body = merge(model["body"], variant["body"])
    let thinking = ocNullish(body["thinking"], settings["thinking"])
    let config = ocNullish(body["generationConfig"]?["thinkingConfig"], settings["thinkingConfig"])
    let reason = ocNullish(body["reasoning"], settings["reasoning"])
    if thinking?["type"] == .text("disabled") || reason?["enabled"] == .bool(false) || body["enable_thinking"] == .bool(false) || settings["enableThinking"] == .bool(false) || config?["thinkingBudget"] == .number(0) { return .object(["mode": .text("off")]) }
    let effort = ocNullish(body["reasoning_effort"], body["output_config"]?["effort"], reason?["effort"], settings["reasoningEffort"], settings["effort"], config?["thinkingLevel"])
    if effort == .text("none") || effort == .text("off") { return .object(["mode": .text("off")]) }
    if let effort, let text = effort.ocString, !text.codeUnits.isEmpty { return .object(["mode": .text("effort"), "effort": effort]) }
    let budget = ocNullish(thinking?["budget_tokens"], thinking?["budgetTokens"], config?["thinkingBudget"])
    if let budget = budget?.numberValue, budget > 0 { return .object(["mode": .text("effort"), "effort": variant["id"] ?? .text("")]) }
    if thinking?["type"] == .text("enabled") || thinking?["type"] == .text("adaptive") || reason?["enabled"] == .bool(true) || body["enable_thinking"] == .bool(true) || settings["enableThinking"] == .bool(true) || budget == .number(-1) { return .object(["mode": .text("on")]) }
    return nil
}
func ocThinkingChoices(_ capability: JSONValue) -> [JSONValue] {
    switch capability["kind"]?.stringValue {
    case "fixed": return [.object(["mode": .text("fixed")])]
    case "toggle": return [.object(["mode": .text("off")]), .object(["mode": .text("on")])]
    case "effort":
        var seen = Set<JSONText>()
        let efforts = (capability["efforts"]?.arrayValue ?? []).filter { value in value.ocString.map { seen.insert($0).inserted } ?? false }
        return (capability["canDisable"] == .bool(true) ? [.object(["mode": .text("off")])] : []) + efforts.map { .object(["mode": .text("effort"), "effort": $0]) }
    default: return []
    }
}
private struct OpenCodeProfileFields: View {
    let value: JSONValue
    let resource: HarnessSettingsResource<OpenCodeSettingsPresentationData>
    var explicitThinking = false
    var executionSnapshot = false
    var disabled = false
    let change: (JSONValue) -> Void
    @Environment(\.locale) private var locale
    private var presentation: OpenCodeSettingsPresentationData? { if case .ready(let data) = resource.state { data } else { nil } }
    private var models: [JSONValue] { presentation?.models ?? [] }
    private var agents: [JSONValue] { (presentation?.agents ?? []).filter { $0["mode"] != .text("subagent") } }
    private var selected: JSONValue? { models.first { $0["id"] == value["model"] && $0["provider"] == value["provider"] } }
    private var agent: JSONValue? { agents.first { $0["id"] == value["agent"] } }
    private var available: [JSONValue] { models.filter { value["provider"] == nil || $0["provider"] == value["provider"] } }
    private var capability: JSONValue? { selected.map { ocThinkingCapability(model: $0, agent: agent) } }
    private var choices: [JSONValue] { capability.map(ocThinkingChoices) ?? [] }
    private var exclusiveReason: String? { selected.flatMap { ocExclusiveModelReason($0, variant: value["variant"], agent: agent) } }
    var body: some View {
        NativeSettingsRow(label: "Provider") {
            NativeSettingsSelect(value: binding("provider") { next in
                if next == value["provider"] { return }
                change(ocReplacing(base, key: "provider", value: next))
            }, options: providerOptions).nativeSettingsControl("provider").disabled(disabled)
        }
        NativeSettingsRow(label: t("模型")) {
            NativeSettingsSelect(value: Binding(get: { selected.map { ocJSONStringID([$0["provider"]!, $0["id"]!]) } ?? value.ocText("model") ?? "" }, set: { key in
                let model = models.first { ocJSONStringID([$0["provider"]!, $0["id"]!]) == key }
                var next = base.objectValue ?? [:]
                next["provider"] = model?["provider"] ?? value["provider"]; next["model"] = model?["id"]
                if executionSnapshot {
                    let variants = model?["variants"]?.arrayValue ?? []
                    if value["variant"] == .text("default") || variants.contains(where: { $0["id"] == value["variant"] }) { next["variant"] = value["variant"] }
                }
                change(ocCleanSettings(.object(next)))
            }), options: modelOptions).nativeSettingsControl("model").disabled(disabled || (explicitThinking && value["provider"] == nil))
        }
        if explicitThinking {
            NativeSettingsRow(label: t("推理选择")) {
                NativeSettingsSelect(value: Binding(get: { value["thinking"].map { ocJSONStringID([$0]) } ?? "" }, set: { key in
                    change(ocReplacing(value, key: "thinking", value: choices.first { ocJSONStringID([$0]) == key }))
                }), options: thinkingOptions).nativeSettingsControl("thinking").disabled(disabled || choices.isEmpty)
            }
        } else {
            NativeSettingsRow(label: t("OpenCode 模型变体")) {
                NativeSettingsSelect(value: binding("variant") { change(ocReplacing(value, key: "variant", value: $0)) }, options: variantOptions).nativeSettingsControl("variant")
                    .disabled(disabled || selected == nil || selected?["unavailableReason"] != nil)
            }
        }
        if capability?["kind"] == .text("unknown"), let reason = capability?["reason"]?.stringValue { NativeSettingsNotice(message: reason, kind: .warning) }
        if let exclusiveReason { NativeSettingsNotice(message: t(exclusiveReason), kind: .warning) }
        NativeSettingsRow(label: t("OpenCode Agent")) {
            NativeSettingsSelect(value: binding("agent") { change(ocReplacing(value, key: "agent", value: $0)) }, options: agentOptions).nativeSettingsControl("agent").disabled(disabled)
        }
        if let description = agent?["description"]?.stringValue { NativeSettingsNotice(message: description) }
        NativeSettingsRow(label: t("权限模式")) {
            NativeSettingsSelect(value: Binding(get: { value.ocText("permissionMode") ?? (executionSnapshot ? "" : "auto") }, set: { change(ocReplacing(value, key: "permissionMode", value: .string($0))) }),
                options: (executionSnapshot ? [.init(id: "", label: t("请选择"), disabled: true)] : []) + [
                    .init(id: "auto", label: "auto · " + t("自动批准权限请求（保留拒绝规则）")), .init(id: "default", label: "default · " + t("按原生规则询问"))]).disabled(disabled)
        }
    }
    private var base: JSONValue { .object(["agent": value["agent"], "permissionMode": value["permissionMode"]].compactMapValues { $0 }) }
    private func t(_ text: String) -> String { ocLocalized(text, locale: locale) }
    private var emptyOption: NativeSettingsOption { .init(id: "", label: t(explicitThinking || executionSnapshot ? "请选择" : "OpenCode 原生默认"), disabled: explicitThinking || executionSnapshot) }
    private func binding(_ key: String, set: @escaping (JSONValue?) -> Void) -> Binding<JSONText> { Binding(get: { value.ocText(key) ?? "" }, set: { set($0.codeUnits.isEmpty ? nil : .string($0)) }) }
    private var providerOptions: [NativeSettingsOption] {
        var providers: [JSONText] = []; for model in models { let provider = model.ocID("provider"); if !providers.contains(provider) { providers.append(provider) } }
        var result = [emptyOption]
        if let provider = value.ocText("provider"), !providers.contains(provider) { result.append(.init(id: provider, label: provider.string + " · " + t("目录中不可用"), disabled: true)) }
        return result + providers.map { .init(id: $0, label: $0.string) }
    }
    private var modelOptions: [NativeSettingsOption] {
        var result = [emptyOption]
        if let model = value.ocText("model"), selected == nil { result.append(.init(id: model, label: model.string + " · " + t("目录中不可用"), disabled: true)) }
        return result + available.map { model in .init(id: ocJSONStringID([model["provider"]!, model["id"]!]),
            label: model.ocID("provider").string + " · " + (model["name"]?.stringValue ?? "") + (model["unavailableReason"] != nil ? " · " + t("目录中不可用") : ""), disabled: model["unavailableReason"] != nil) }
    }
    private var thinkingOptions: [NativeSettingsOption] {
        var result: [NativeSettingsOption] = [.init(id: "", label: t("请选择"), disabled: true)]
        if let thinking = value["thinking"], !choices.contains(thinking) { result.append(.init(id: ocJSONStringID([thinking]), label: t(ocThinkingLabel(thinking)) + " · " + t("目录中不可用"))) }
        return result + choices.map { .init(id: ocJSONStringID([$0]), label: t(ocThinkingLabel($0))) }
    }
    private var variantOptions: [NativeSettingsOption] {
        var result: [NativeSettingsOption] = [.init(id: "", label: t(executionSnapshot ? "请选择" : "OpenCode 原生默认"), disabled: executionSnapshot)]
        if executionSnapshot { result.append(.init(id: "default", label: t("基础模型变体"))) }
        let variants = selected?["variants"]?.arrayValue ?? []
        if let variant = value.ocText("variant"), !(executionSnapshot && variant == "default"), !variants.contains(where: { $0.ocText("id") == variant }) { result.append(.init(id: variant, label: variant.string + " · " + t("目录中不可用"))) }
        return result + variants.filter { !executionSnapshot || $0["id"] != .text("default") }.map { .init(id: $0.ocID("id"), label: $0.ocID("id").string) }
    }
    private var agentOptions: [NativeSettingsOption] {
        var result: [NativeSettingsOption] = [.init(id: "", label: t(executionSnapshot ? "请选择" : "OpenCode 原生默认"), disabled: executionSnapshot)]
        if let agent = value.ocText("agent"), !agents.contains(where: { $0.ocText("id") == agent }) { result.append(.init(id: agent, label: agent.string + " · " + t("目录中不可用"))) }
        return result + agents.map { .init(id: $0.ocID("id"), label: $0["name"]?.stringValue ?? "") }
    }
}
public struct OpenCodeThreadSettingsView: View {
    public let input: HarnessThreadInput
    public let resource: HarnessSettingsResource<OpenCodeSettingsPresentationData>
    public let update: (OpenCodeThreadSettingsUpdate) async throws -> Void
    @State private var value: JSONValue
    @State private var busy = false
    @State private var failure: String?
    @Environment(\.locale) private var locale
    public init(input: HarnessThreadInput, resource: HarnessSettingsResource<OpenCodeSettingsPresentationData>, update: @escaping (OpenCodeThreadSettingsUpdate) async throws -> Void) {
        self.input = input; self.resource = resource; self.update = update; _value = State(initialValue: ocCleanSettings(input.thread.settings))
    }
    private var complete: Bool {
        guard value.ocText("provider")?.codeUnits.isEmpty == false, value.ocText("model")?.codeUnits.isEmpty == false,
              let thinking = value["thinking"], case .ready(let data) = resource.state,
              let model = data.models.first(where: { $0["provider"] == value["provider"] && $0["id"] == value["model"] }), model["unavailableReason"] == nil else { return false }
        return ocThinkingChoices(ocThinkingCapability(model: model, agent: data.agents.first { $0["id"] == value["agent"] })).contains(thinking)
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OpenCodeResourceStatus(resource: resource)
            NativeSettingsGroup(title: ocLocalized("OpenCode Thread 配置", locale: locale)) {
                OpenCodeProfileFields(value: value, resource: resource, explicitThinking: true,
                    disabled: input.thread.observation.isExecutionActive || busy, change: { value = $0 })
            }
            if input.thread.observation.isExecutionActive { NativeSettingsNotice(message: ocLocalized("该 Thread 正在运行，请等待完成或停止后再修改。", locale: locale)) }
            if let failure { Text(failure).foregroundStyle(NativePalette.settings.danger.swiftUI) }
            Button(ocLocalized("应用 Thread 配置", locale: locale)) { save() }.buttonStyle(OpenCodeButtonStyle())
                .disabled(input.thread.observation.isExecutionActive || busy || value == ocCleanSettings(input.thread.settings) || !complete)
        }
        .onChange(of: input.thread.settings) { _, raw in value = ocCleanSettings(raw); failure = nil }
        .onChange(of: input.thread.id) { _, _ in value = ocCleanSettings(input.thread.settings); failure = nil }
    }
    private func save() {
        guard !busy, !input.thread.observation.isExecutionActive, complete else { return }
        busy = true; failure = nil
        let payload: JSONValue = .object(["provider": value["provider"]!, "model": value["model"]!, "thinking": value["thinking"]!, "agent": value["agent"] ?? .null, "permissionMode": value["permissionMode"] ?? .text("auto")])
        Task { @MainActor in defer { busy = false }; do { try await update(OpenCodeThreadSettingsUpdate(raw: payload)) } catch { failure = error.localizedDescription } }
    }
}
public struct OpenCodeHarnessSettingsView: View {
    public let props: HarnessSettingsProps<OpenCodeHarnessSettings, OpenCodeSettingsPresentationData>
    @State private var pendingProfile: JSONValue?
    @Environment(\.locale) private var locale
    public init(props: HarnessSettingsProps<OpenCodeHarnessSettings, OpenCodeSettingsPresentationData>) { self.props = props }
    public var body: some View {
        if props.section == .cli {
            let status = ocCLIStatus(props.resource, locale: locale)
            NativeSettingsCliStatus(label: "OpenCode 2.x", status: status.text, kind: status.kind)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                OpenCodeResourceStatus(resource: props.resource)
                NativeSettingsGroup(title: props.executionSnapshot ? nil : ocLocalized("OpenCode Thread 默认配置", locale: locale)) {
                    if props.executionSnapshot {
                        fields
                        if pendingProfile != nil { NativeSettingsNotice(message: ocLocalized("请补全模型相关配置；完成前不会保存此组修改。", locale: locale), kind: .warning) }
                    }
                    else { NativeSettingsUseDefaults(value: Binding(get: { props.value.useDefaultThreadSettings }, set: { enabled in
                        emit(profile: enabled ? .object([:]) : props.value.threadSettings, defaults: enabled)
                    })) { fields } }
                    if !props.executionSnapshot, props.value.useDefaultThreadSettings, case .ready(let data) = props.resource.state, let effective = data.raw["effectiveModel"] {
                        NativeSettingsNotice(message: ocLocalized("当前原生模型", locale: locale) + "：" + effective.ocID("provider").string + "/" + effective.ocID("model").string
                            + (effective["variant"]?.stringValue.map { " · " + $0 } ?? "")
                            + (effective["exclusiveUnavailableReason"]?.stringValue.map { " · " + ocLocalized($0, locale: locale) } ?? ""),
                            kind: effective["exclusiveUnavailableReason"] == nil ? .info : .warning)
                    }
                }
            }.environment(\.nativeSettingsFormPage, props.settingsFormPage)
                .onChange(of: props.host?.cwd) { _, _ in pendingProfile = nil }
        }
    }
    private var fields: some View { OpenCodeProfileFields(value: pendingProfile ?? props.value.threadSettings, resource: props.resource,
        executionSnapshot: props.executionSnapshot, change: { emit(profile: $0, defaults: !props.executionSnapshot && props.value.useDefaultThreadSettings) }) }
    private func emit(profile: JSONValue, defaults: Bool) {
        if props.executionSnapshot && ["provider", "model", "variant", "agent", "permissionMode"].contains(where: { profile[$0] == nil }) {
            pendingProfile = profile; return
        }
        var fields: [JSONText: JSONValue] = ["threadSettings": profile]
        if !defaults { fields["useDefaultThreadSettings"] = .bool(false) }
        if let value = try? OpenCodeHarnessSettings(raw: .object(fields)) { pendingProfile = nil; props.change(value) }
    }
}
private struct OpenCodeResourceStatus: View {
    let resource: HarnessSettingsResource<OpenCodeSettingsPresentationData>
    @Environment(\.nativeSettingsFormPage) private var formPage
    @Environment(\.locale) private var locale
    @State private var reloading = false
    @State private var failure: String?
    @ViewBuilder private var refresh: some View {
        if formPage { refreshButton.buttonStyle(.bordered) }
        else { refreshButton.buttonStyle(OpenCodeButtonStyle()) }
    }
    private var refreshButton: some View {
        Button(ocLocalized(reloading ? "正在刷新 OpenCode…" : "重试", locale: locale)) {
            reloading = true; failure = nil
            Task { @MainActor in defer { reloading = false }; do { try await resource.reload(refresh: true) } catch { failure = error.localizedDescription } }
        }.disabled(reloading)
    }
    private var accountPending: Bool {
        if case .ready(let data) = resource.state { return data.raw["accountCheckPending"] == .bool(true) }
        return false
    }
    private var hidden: Bool {
        if accountPending { return false }
        if reloading || failure != nil { return false }
        switch resource.state { case .loading: return true; case .ready(let data): return data.raw["cli"]?["status"] == .text("ready") && !ocTruthy(data.raw["cli"]?["message"]); case .error: return false }
    }
    var body: some View {
        Group {
            if !hidden {
                let status = ocCLIStatus(resource, locale: locale)
                NativeSettingsNotice(message: failure ?? status.text, kind: failure == nil ? status.kind : .error,
                    action: AnyView(refresh))
            }
        }
        .task(id: accountPending) {
            guard accountPending else { return }
            for delay in [1, 2, 4, 8, 15, 30] {
                do {
                    try await Task.sleep(for: .seconds(delay))
                    try await resource.reload(refresh: false)
                    if !accountPending { return }
                } catch { return }
            }
        }
    }
}
@MainActor private func ocCLIStatus(_ resource: HarnessSettingsResource<OpenCodeSettingsPresentationData>, locale: Locale) -> (text: String, kind: NativeSettingsNotice.Kind) {
    switch resource.state {
    case .loading: return (ocLocalized("正在读取 OpenCode 环境…", locale: locale), .info)
    case .error(let error): return (error, .error)
    case .ready(let data):
        if data.raw["accountCheckPending"] == .bool(true) {
            return (locale.identifier.hasPrefix("zh") ? "模型列表已就绪，账户可用性尚未确认。" : "Models are ready; account availability is not yet confirmed.", .info)
        }
        let cli = data.raw["cli"] ?? .null, ready = data.raw["cli"]?["status"] == .text("ready")
        return ([ocLocalized(ready ? "可用" : "不可用", locale: locale), cli["version"]?.stringValue, cli["message"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), ready && !ocTruthy(cli["message"]) ? .success : .warning)
    }
}

private func ocNullish(_ values: JSONValue?...) -> JSONValue? { values.compactMap { $0 }.first { $0 != .null } }
private func ocTruthy(_ value: JSONValue?) -> Bool {
    guard let value else { return false }
    switch value { case .integer: return true; case .null: return false; case .bool(let flag): return flag; case .number(let value): return value != 0; case .string(let value): return !value.codeUnits.isEmpty; case .array, .object: return true }
}

func ocExclusiveModelReason(_ model: JSONValue, variant: JSONValue?, agent: JSONValue?) -> String? {
    guard agent?["hasRequestOverrides"] != .bool(true), !ocTruthy(agent?["body"]?["model"]) else { return nil }
    if let variant, ocTruthy(variant), variant != .text("default") {
        return model["variants"]?.arrayValue?.first { $0["id"] == variant }?["exclusiveUnavailableReason"]?.stringValue
    }
    return model["exclusiveUnavailableReason"]?.stringValue
}
