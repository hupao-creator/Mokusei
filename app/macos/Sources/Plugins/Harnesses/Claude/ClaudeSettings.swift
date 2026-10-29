import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

private let claudeEfforts = ["low","medium","high","xhigh","max"]
private let claudePermissions = ["acceptEdits","auto","bypassPermissions","manual","dontAsk","plan"]
private let claudePermissionLabels = ["acceptEdits":"自动接受编辑","auto":"自动判断权限","manual":"按需询问","plan":"Plan（只读规划）","bypassPermissions":"绕过所有权限","dontAsk":"不询问，未授权即拒绝"]
public struct ClaudeThreadSettingsUpdate: Hashable, Sendable {
    public let json: JSONValue
    public init(json: JSONValue) throws {
        try claudeKeys(json, ["model","thinking","permissionMode","allowedTools","disallowedTools"])
        if let model = json["model"] { try claudeIdentifier(model); guard model.stringValue?.lowercased() != "default" else { throw claudeInvalid("model") } }
        if let thinking = json["thinking"] { try claudeValidateThinking(thinking) }
        if let mode = json["permissionMode"], mode != .null, !claudePermissions.contains(mode.stringValue ?? "") { throw claudeInvalid("permissionMode") }
        for key in ["allowedTools","disallowedTools"] { if let tools = json[key], tools != .null { try claudeToolNames(tools) } }
        self.json = json
    }
    @MainActor public static var codec: PluginValueCodec<Self> { .init(decode: { try Self(json:$0) }, encode: { $0.json }) }
}
public struct ClaudeHarnessSettings: Hashable, Sendable {
    public let json: JSONValue
    public init(json: JSONValue) throws {
        let json = json == .null || json == .object([:]) ? claudeObject(["threadSettings":claudeObject([:])]) : json
        try claudeKeys(json, ["useDefaultThreadSettings","threadSettings"])
        if let flag = json["useDefaultThreadSettings"], flag.boolValue == nil { throw claudeInvalid("useDefaultThreadSettings") }
        guard let profile = json["threadSettings"] else { throw claudeInvalid("threadSettings") }
        try claudeKeys(profile, ["model","effort","goalMode","permissionMode","allowedTools","disallowedTools"])
        if let model = profile["model"] { try claudeIdentifier(model) }
        if let effort = profile["effort"], !claudeEfforts.contains(effort.stringValue ?? "") { throw claudeInvalid("effort") }
        if let mode = profile["permissionMode"], !claudePermissions.contains(mode.stringValue ?? "") { throw claudeInvalid("permissionMode") }
        if let goal = profile["goalMode"], goal.boolValue == nil { throw claudeInvalid("goalMode") }
        for key in ["allowedTools","disallowedTools"] { if let tools = profile[key] { try claudeToolNames(tools) } }
        self.json = json["useDefaultThreadSettings"] == .bool(false) ? json : claudeObject(["threadSettings":claudeObject([:])])
    }
    @MainActor public static var codec: PluginValueCodec<Self> { .init(decode: { try Self(json:$0) }, encode: { $0.json }) }
}
public struct ClaudeSettingsPresentationData: Hashable, Sendable {
    public let json: JSONValue
    public init(json: JSONValue) throws {
        try claudeKeys(json, ["cli","models"])
        guard let cli = json["cli"] else { throw claudeInvalid("CLI") }
        let available = cli["status"]?.stringValue == "available"
        guard available || cli["status"]?.stringValue == "unavailable" else { throw claudeInvalid("CLI") }
        try claudeKeys(cli, available ? ["status","executablePath","version"] : ["status","executablePath","message"])
        try claudeText(cli["executablePath"], max: 4_096)
        if !available { try claudeText(cli["message"], max: 100_000) }
        for model in try claudeArray(json["models"], max: 10_000) {
            try claudeKeys(model, ["value","displayName","description","supportedEfforts","thinking"])
            try claudeIdentifier(model["value"]); try claudeText(model["displayName"], max: 2_000)
            let efforts = try claudeArray(model["supportedEfforts"], max: 5)
            guard efforts.allSatisfy({ claudeEfforts.contains($0.stringValue ?? "") }) else { throw claudeInvalid("supportedEfforts") }
            guard let thinking = model["thinking"], ["effort","toggle","fixed","unknown"].contains(thinking.claudeKind) else { throw claudeInvalid("thinking") }
        }
        self.json = json
    }
    var models: [JSONValue] { json["models"]?.arrayValue ?? [] }
    @MainActor public static var codec: PluginValueCodec<Self> { .init(decode: { try Self(json:$0) }, encode: { $0.json }) }
}
private func claudeIdentifier(_ value: JSONValue?) throws {
    try claudeText(value, max:512, nonempty:true)
    guard case .string(let text)? = value, text == claudeTrimText(text), !text.codeUnits.contains(0) else { throw claudeInvalid("identifier") }
}
private func claudeToolNames(_ value: JSONValue) throws {
    let tools = try claudeArray(value,max:128); guard Set(tools).count == tools.count else { throw claudeInvalid("tools") }; for tool in tools { try claudeIdentifier(tool) }
}
private func claudeValidateThinking(_ value: JSONValue) throws {
    let mode = value["mode"]?.stringValue
    if mode == "effort" {
        try claudeKeys(value,["mode","effort"]); try claudeText(value["effort"],max:64,nonempty:true); try claudeIdentifier(value["effort"])
        guard value["effort"]?.stringValue?.lowercased() != "default" else { throw claudeInvalid("thinking") }
    } else { try claudeKeys(value,["mode"]); guard ["on","off","fixed"].contains(mode ?? "") else { throw claudeInvalid("thinking") } }
}
func claudeThinkingLabel(_ value: JSONValue) -> String { value["mode"]?.stringValue == "effort" ? value["effort"]?.stringValue ?? "" : value["mode"]?.stringValue ?? "" }
private func claudeThinkingKey(_ value:JSONValue?) -> String {
    guard let value,let mode=value["mode"] else { return "" }
    return claudeJSONString(.array([mode] + (mode == .text("effort") ? [value["effort"] ?? .null] : [])))
}
private func claudeThinkingChoices(_ capability: JSONValue?) -> [JSONValue] {
    switch capability?.claudeKind {
    case "effort":
        var seen=Set<JSONValue>()
        return (capability?["canDisable"] == .bool(true) ? [claudeObject(["mode":.text("off")])] : []) + (capability?["efforts"]?.arrayValue ?? []).filter { seen.insert($0).inserted }.map { claudeObject(["mode":.text("effort"),"effort":$0]) }
    case "toggle": return [claudeObject(["mode":.text("off")]),claudeObject(["mode":.text("on")])]
    case "fixed": return [claudeObject(["mode":.text("fixed")])]
    default: return []
    }
}
struct ClaudeThreadSettingsView: View {
    let input: HarnessThreadInput
    let resource: HarnessSettingsResource<ClaudeSettingsPresentationData>
    let update: (ClaudeThreadSettingsUpdate) async throws -> Void
    @State private var model = ""
    @State private var exactModel: JSONText = ""
    @State private var thinking: JSONValue?
    @State private var permission = ""
    @State private var saving = false
    @State private var error: String?
    @State private var generation = 0
    @Environment(\.locale) private var locale
    @Environment(\.nativeSettingsFormPage) private var formPage
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            ClaudeSettingsResourceStatus(resource:resource)
            if !formPage {
                Text(t("Thread 配置")).font(NativeTypography.inter(size:14,weight:600))
                Text(t("保存后的配置会在下一次 Claude 操作时生效；Primary Native Session 不会被替换。")).foregroundStyle(NativePalette.thread.muted.swiftUI)
            }
            ClaudeModelField(value:Binding(get:{ exactModel },set:{ chooseModel($0) }), models:models, required:true, disabled:disabled)
            ClaudeSelectionField(label:t("Thinking（必选）"),value:Binding(get:{ claudeThinkingKey(thinking) },set:{ key in thinking = choices.first { claudeThinkingKey($0) == key } }),
                options:[NativeSettingsOption(id:"",label:t("请选择 Thinking"),disabled:true)] + choices.map { NativeSettingsOption(id:JSONText(claudeThinkingKey($0)),label:claudeThinkingLabel($0)) }, reasoning: true).nativeSettingsControl("thinking")
                .disabled(disabled || choices.isEmpty)
            if let reason = selected?["thinking"]?["reason"]?.stringValue { Text(reason).foregroundStyle(NativePalette.thread.muted.swiftUI) }
            ClaudePermissionField(value:$permission, disabled:disabled)
            if input.thread.observation.isExecutionActive { Text(t("该 Thread 正在运行，请等待完成或停止后再修改。")).foregroundStyle(NativePalette.thread.muted.swiftUI) }
            if !valid { Text(t("模型标识不能以空白开头或结尾。")).foregroundStyle(NativePalette.thread.danger.swiftUI) }
            if let error { ClaudeFailure(message:error) }
            Button(t(saving ? "正在保存…" : "应用 Thread 配置"),action:save).disabled(disabled || !valid || thinking == nil || patch.objectValue?.isEmpty != false)
        }.font(NativeTypography.inter(size:12)).padding(.vertical,12)
            .onChange(of:input.thread.settings,initial:true) { _, settings in
                generation += 1; exactModel = settings.claudeID("model"); model = exactModel.string; thinking = settings["thinking"]; permission = settings["permissionMode"]?.stringValue ?? ""; error = nil
            }.onDisappear { generation += 1 }
    }
    private var models: [JSONValue] { if case .ready(let data) = resource.state { data.models } else { [] } }
    private var selected: JSONValue? { models.first { $0["value"] == .string(exactModel) } }
    private var choices: [JSONValue] { claudeThinkingChoices(selected?["thinking"]) }
    private var disabled: Bool { saving || input.thread.observation.isExecutionActive }
    private var valid: Bool { claudeValidModel(model,required:true) }
    private var patch: JSONValue {
        var values: [String:JSONValue] = [:]
        let changed = exactModel != input.thread.settings.claudeID("model")
        if changed { values["model"] = .string(exactModel) }
        if let thinking, changed || thinking != input.thread.settings["thinking"] { values["thinking"] = thinking }
        if permission != (input.thread.settings["permissionMode"]?.stringValue ?? "") { values["permissionMode"] = permission.isEmpty ? .null : .text(permission) }
        return claudeObject(values)
    }
    private func chooseModel(_ value: JSONText) {
        if exactModel != value { exactModel = value; model = value.string; thinking = nil }
    }
    private func save() {
        guard !disabled,valid,thinking != nil,patch.objectValue?.isEmpty == false else { return }
        saving = true; error = nil; let current = generation
        Task { @MainActor in
            defer { saving = false }
            do { try await update(ClaudeThreadSettingsUpdate(json:patch)) }
            catch { if current == generation { self.error = error.localizedDescription } }
        }
    }
    private func t(_ source:String) -> String { claudeLocalized(source,locale:locale) }
}
struct ClaudeHarnessSettingsView: View {
    let props: HarnessSettingsProps<ClaudeHarnessSettings,ClaudeSettingsPresentationData>
    @State private var stableModels: [JSONValue] = []
    @State private var stableCwd: JSONText?
    @State private var modelText = ""
    @State private var exactModel: JSONText = ""
    @State private var pendingProfile: JSONValue?
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: props.settingsFormPage ? 0 : 16) {
            if props.section == .cli {
                ClaudeSettingsResourceStatus(resource: props.resource, isCLI: true)
            } else if awaitingSnapshot {
                ClaudeSettingsResourceStatus(resource: props.resource)
            } else {
                if case .ready(let data) = props.resource.state, data.json["cli"]?["status"] == .text("available") {} else {
                    ClaudeSettingsResourceStatus(resource: props.resource)
                }
                NativeSettingsGroup(title: props.settingsFormPage ? nil : t(props.executionSnapshot ? "Claude 运行配置" : "Claude Thread 默认配置")) {
                    if props.executionSnapshot { fields }
                    else {
                        NativeSettingsUseDefaults(value: Binding(get: { useDefaults }, set: { setDefaults($0) })) { fields }
                            .nativeSettingsControl("useDefaults")
                    }
                }
            }
        }.environment(\.nativeSettingsFormPage, props.settingsFormPage)
            .nativeSettingsEditorReady(pendingProfile == nil
                && (!props.executionSnapshot || claudeValidModel(modelText, required: true)))
            .onChange(of:props.value.json["threadSettings"]?["model"],initial:true) { _, value in
                guard pendingProfile == nil else { return }
                exactModel = value.map { if case .string(let text) = $0 { text } else { JSONText("") } } ?? ""; modelText = exactModel.string
            }
            .onChange(of:props.host?.cwd) { _, _ in
                pendingProfile = nil; exactModel = profile.claudeID("model"); modelText = exactModel.string
            }
            .onChange(of:catalogIdentity,initial:true) { _, _ in
                if case .ready(let data) = props.resource.state { stableModels = data.models; stableCwd = props.host?.cwd }
                else if case .error = props.resource.state { stableModels = []; stableCwd = nil }
                else if stableCwd != props.host?.cwd { stableModels = []; stableCwd = nil }
            }
    }
    private var awaitingSnapshot: Bool {
        guard props.executionSnapshot, profile["model"] == nil else { return false }
        if case .ready = props.resource.state { return false }
        return true
    }
    private var fields: some View {
        Group {
            ClaudeModelField(value: Binding(get: { exactModel }, set: { changeModelValue($0) }), models: models,
                             required: props.executionSnapshot, disabled: false)
            ClaudeSelectionField(label: t("推理强度"), value: Binding(get: { profile["effort"]?.stringValue ?? "" },
                set: { change("effort", $0.isEmpty ? nil : .text($0)) }), options: effortOptions, reasoning: true).nativeSettingsControl("effort")
                .disabled(modelText.isEmpty || (props.executionSnapshot && !claudeValidModel(modelText, required: true)) || (efforts.isEmpty && !(props.executionSnapshot && selected?["thinking"]?.claudeKind == "fixed" && profile["effort"] != nil)))
            if props.executionSnapshot, selected?["thinking"]?.claudeKind == "unknown" || selected == nil {
                NativeSettingsNotice(message: selected?["thinking"]?["reason"]?.stringValue ?? t("无法确认此模型的推理强度能力。"), kind: .warning)
            }
            ClaudePermissionField(value: Binding(get: { profile["permissionMode"]?.stringValue ?? "" },
                set: { change("permissionMode", $0.isEmpty ? nil : .text($0)) }),
                disabled: props.executionSnapshot && !claudeValidModel(modelText, required: true), required: props.executionSnapshot)
            if pendingProfile != nil { NativeSettingsNotice(message: t("请补全模型相关配置；完成前不会保存此组修改。"), kind: .warning) }
        }
    }
    private var catalogIdentity: JSONValue { if case .ready(let data) = props.resource.state { data.json } else if case .error(let message) = props.resource.state { .text(message) } else { .null } }
    private var models: [JSONValue] { if case .ready(let data) = props.resource.state { data.models } else { stableCwd == props.host?.cwd ? stableModels : [] } }
    private var profile: JSONValue { pendingProfile ?? props.value.json["threadSettings"] ?? claudeObject([:]) }
    private var useDefaults: Bool { props.value.json["useDefaultThreadSettings"] != .bool(false) }
    private var selected: JSONValue? { models.first { $0["value"] == .string(exactModel) } }
    private var efforts: [String] { (props.executionSnapshot ? selected?["thinking"]?["efforts"]?.arrayValue : selected?["supportedEfforts"]?.arrayValue)?.compactMap(\.stringValue) ?? [] }
    private var effortOptions: [NativeSettingsOption] {
        let fixed = selected?["thinking"]?.claudeKind == "fixed"
        let prompt = props.executionSnapshot ? fixed ? "模型不提供推理强度配置" : "请选择推理强度" : "跟随 Claude 配置"
        var options = [NativeSettingsOption(id:"",label:t(prompt),disabled:props.executionSnapshot && !fixed)]
        if let effort = profile["effort"]?.stringValue, !efforts.contains(effort) { options.append(NativeSettingsOption(id:JSONText(effort),label:effort + " · " + t("目录中不可用"))) }
        options += efforts.map { NativeSettingsOption(id:JSONText($0),label:["low":"Low","medium":"Medium","high":"High","xhigh":"Extra high","max":"Maximum"][$0] ?? $0) }
        return options
    }
    private func updatedProfile(_ profile: JSONValue) -> JSONValue {
        var raw = props.value.json.claudeReplacing("threadSettings",profile)
        if props.executionSnapshot { raw = raw.claudeReplacing("useDefaultThreadSettings",.bool(false)) }
        return raw
    }
    private func setDefaults(_ use: Bool) {
        let raw = claudeObject(use ? ["threadSettings":claudeObject([:])] : ["useDefaultThreadSettings":.bool(false),"threadSettings":profile])
        if let value = try? ClaudeHarnessSettings(json:raw) { props.change(value) }
    }
    private func change(_ key:String,_ value:JSONValue?) {
        emit(profile.claudeReplacing(key,value))
    }
    private func emit(_ next:JSONValue) {
        if props.executionSnapshot {
            let model = models.first { $0["value"] == next["model"] }
            if next["model"] == nil || next["permissionMode"] == nil || (model?["thinking"]?.claudeKind != "fixed" && next["effort"] == nil) {
                pendingProfile = next; return
            }
        }
        if let settings = try? ClaudeHarnessSettings(json:updatedProfile(next)) { pendingProfile = nil; props.change(settings) }
    }
    private func changeModelValue(_ raw:JSONText) {
        exactModel = raw; modelText = raw.string
        guard claudeValidModel(modelText,required:props.executionSnapshot) else { return }
        var next = profile.claudeReplacing("model",raw.codeUnits.isEmpty ? nil : .string(raw))
        let model = models.first { $0["value"] == .string(raw) }
        let efforts = (props.executionSnapshot ? model?["thinking"]?["efforts"]?.arrayValue : model?["supportedEfforts"]?.arrayValue) ?? []
        if !efforts.contains(profile["effort"] ?? .null) { next = next.claudeReplacing("effort",nil) }
        emit(next)
    }
    private func t(_ source:String) -> String { claudeLocalized(source,locale:locale) }
}
private struct ClaudeModelField: View {
    @Binding var value: JSONText
    let models: [JSONValue]
    let required: Bool
    let disabled: Bool
    @State private var custom = false
    @Environment(\.locale) private var locale
    @Environment(\.nativeSettingsFormPage) private var formPage
    private var selected: JSONValue? { models.first { $0["value"] == .string(value) } }
    private var showingCustom: Bool { custom || (!value.codeUnits.isEmpty && selected == nil) }
    // Tag UI actions separately from native identifiers, which may have any spelling.
    private var customKey: JSONText { JSONText(claudeJSONString(.array([.text("custom")]))) }
    private func modelKey(_ model: JSONValue) -> JSONText { JSONText(claudeJSONString(.array([.text("model"), model["value"] ?? .null]))) }
    private var selection: JSONText { showingCustom ? customKey : selected.map(modelKey) ?? "" }
    private var options: [NativeSettingsOption] {
        [.init(id: "", label: t(required ? "请选择模型" : "跟随 Claude 默认模型"), disabled: required)]
            + models.map { .init(id: modelKey($0), label: $0["displayName"]?.stringValue ?? $0.claudeID("value").string) }
            + [.init(id: customKey, label: t("自定义模型…"))]
    }
    var body: some View {
        NativeSettingsRow(label: t("模型"), description: selected?["description"]?.stringValue,
                          layout: formPage ? .inline : .stacked) {
            NativeModelSelector(value: Binding(get: { selection }, set: { key in
                if key == customKey { custom = true; return }
                custom = false
                value = models.first { modelKey($0) == key }?.claudeID("value") ?? ""
            }), options: options).nativeSettingsControl("model")
        }.disabled(disabled)
        if showingCustom {
            NativeSettingsRow(label: t("自定义模型标识"),
                error: claudeValidModel(value.string, required: required) ? nil : t(required ? "请输入明确的模型标识，不能使用 default 或首尾空白。" : "模型标识不能以空白开头或结尾。"),
                layout: formPage ? .inline : .stacked) {
                NativeSettingsInput(value: Binding(get: { value.string }, set: { value = JSONText($0) }))
                    .nativeSettingsControl("customModel")
            }.disabled(disabled)
        }
    }
    private func t(_ source: String) -> String { claudeLocalized(source, locale: locale) }
}
private struct ClaudePermissionField: View {
    @Binding var value:String
    var disabled:Bool
    var required = false
    @Environment(\.locale) private var locale
    var body: some View {
        ClaudeSelectionField(label:claudeLocalized("权限模式",locale:locale),value:$value,
            options:[NativeSettingsOption(id:"",label:claudeLocalized(required ? "请选择权限模式" : "Mokusei 默认（auto）",locale:locale),disabled:required)] + claudePermissions.map { NativeSettingsOption(id:JSONText($0),label:$0 + " · " + claudeLocalized(claudePermissionLabels[$0] ?? $0,locale:locale)) }).nativeSettingsControl("permissionMode").disabled(disabled)
    }

}
private struct ClaudeSelectionField: View {
    let label:String
    @Binding var value:String
    let options:[NativeSettingsOption]
    var reasoning = false
    @Environment(\.nativeSettingsFormPage) private var formPage
    var body: some View {
        NativeSettingsRow(label:label,layout:formPage ? .inline : .stacked) {
            if reasoning {
                NativeModelSelector(value: Binding(get: { JSONText(value) }, set: { value = $0.string }),
                                    options: options, presentation: .reasoning)
            } else {
                NativeSettingsSelect(value:Binding(get:{JSONText(value)},set:{ value = $0.string }),options:options)
            }
        }
    }
}
struct ClaudeSettingsResourceStatus: View {
    let resource:HarnessSettingsResource<ClaudeSettingsPresentationData>
    var isCLI = false
    @State private var reloading = false
    @State private var error:String?
    @Environment(\.nativeSettingsFormPage) private var formPage
    @Environment(\.locale) private var locale
    var body: some View {
        if isCLI {
            NativeSettingsCliStatus(label: "Claude Code", status: message, kind: tone, action: AnyView(refresh))
        } else {
            NativeSettingsNotice(message: message, kind: tone, action: loading ? nil : AnyView(refresh))
        }
    }
    private var loading: Bool { if case .loading = resource.state { return true }; return false }
    @ViewBuilder private var refresh: some View {
        if formPage { refreshButton.buttonStyle(.bordered) }
        else { refreshButton.buttonStyle(.plain) }
    }
    private var refreshButton: some View {
        Button {
            reloading = true
            Task { @MainActor in
                defer { reloading = false }
                do { try await resource.reload(refresh: !isCLI); error = nil }
                catch { self.error = error.localizedDescription }
            }
        } label: { NativeIcon(name: "RefreshCw", size: 13) }
            .disabled(reloading || loading)
            .accessibilityLabel(claudeLocalized("刷新 {name} 环境", locale: locale).replacingOccurrences(of: "{name}", with: "Claude Code"))
    }
    private var tone:NativeSettingsNotice.Kind {
        if error != nil { return .error }
        switch resource.state { case .loading: return .info; case .error: return .error; case .ready(let data): return data.json["cli"]?["status"]?.stringValue == "available" ? .success : isCLI ? .warning : .error }
    }
    private var message:String {
        if let error { return error }
        switch resource.state {
        case .loading: return claudeLocalized("正在读取 Claude 环境…",locale:locale)
        case .error(let message): return message
        case .ready(let data):
            let available = data.json["cli"]?["status"]?.stringValue == "available"
            let fallback = claudeLocalized(available ? "已读取 Claude 环境" : "不可用",locale:locale)
            let supplied = data.json["cli"]?[available ? "version" : "message"]?.stringValue
            if isCLI { return supplied.flatMap { $0.isEmpty ? nil : $0 } ?? fallback }
            return available ? fallback : supplied ?? fallback
        }
    }
}
private func claudeValidModel(_ value:String,required:Bool) -> Bool {
    (!required || !value.isEmpty && value.lowercased() != "default") && value.utf16.count <= 512 && JSONText(value) == claudeTrimText(JSONText(value)) && !value.contains("\0")
}
