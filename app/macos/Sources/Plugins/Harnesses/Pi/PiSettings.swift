import AppKit
import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

func piThinkingLabel(_ value: JSONValue?) -> String? {
    guard let mode = value?["mode"]?.stringValue else { return nil }
    return mode == "effort" ? value?["effort"]?.stringValue : mode
}
func piThinkingChoices(_ capability: JSONValue?) -> [JSONValue] {
    switch piText(capability?["kind"]) {
    case "effort":
        var seen: Set<JSONText> = []
        return (capability?["canDisable"] == .bool(true) ? [.object(["mode": .text("off")])] : []) +
            (capability?["efforts"]?.arrayValue ?? []).compactMap { value in
                guard let text = piText(value), seen.insert(text).inserted else { return nil }
                return .object(["mode": .text("effort"), "effort": .string(text)])
            }
    case "toggle": return [.object(["mode": .text("off")]), .object(["mode": .text("on")])]
    case "fixed": return [.object(["mode": .text("fixed")])]
    default: return []
    }
}
func piThinkingKey(_ value: JSONValue?) -> JSONText {
    guard let value else { return "" }
    return JSONText(String(decoding: (try? value.encodedData()) ?? Data(), as: UTF8.self))
}
func piValidateThinking(_ value: JSONValue) throws {
    let r = try PiReader(value)
    let mode = try r.text("mode")
    if mode == "effort" {
        try r.only(["mode", "effort"])
        let effort = try r.text("effort", maximum: 64, nonempty: true, noNUL: true)
        guard piTrim(effort) == effort, effort.string.lowercased() != "default" else { throw PluginContractError("Pi thinking requires a concrete canonical effort level") }
    } else {
        try r.only(["mode"])
        guard [JSONText("on"), "off", "fixed"].contains(mode) else { throw PluginContractError("Pi thinking must select an effort, on, off, or fixed control") }
    }
}
func piValidateSettings(_ value: JSONValue, update: Bool) throws -> JSONValue {
    let r = try PiReader(value)
    if update {
        try r.only(["provider", "model", "thinking"])
        for key in ["provider", "model"] where r.value[key] != nil {
            let text = try r.text(key, maximum: 256, nonempty: true, noNUL: true)
            guard piTrim(text) == text, text.string.lowercased() != "default" else { throw PluginContractError("Pi ordinary Thread \(key) cannot be cleared") }
        }
        if let thinking = value["thinking"] { try piValidateThinking(thinking) }
    } else {
        try r.only(["threadSettings", "useDefaultThreadSettings"])
        _ = try r.optionalBool("useDefaultThreadSettings")
        let fields = try PiReader(r.value["threadSettings"] ?? .object([:])); try fields.only(["provider", "model", "thinkingLevel"])
        for key in ["provider", "model", "thinkingLevel"] where fields.value[key] != nil {
            let text = try fields.text(key, maximum: key == "thinkingLevel" ? 64 : 256, nonempty: true, noNUL: true)
            guard piTrim(text) == text else { throw PluginContractError("Pi \(key) must be a canonical string") }
        }
    }
    return value
}
func piValidatePresentation(_ value: JSONValue) throws -> JSONValue {
    let r = try PiReader(value)
    let cli = try PiReader(r.required("cli"))
    guard [JSONText("ready"), "unavailable"].contains(try cli.text("status")) else { throw PluginContractError("Invalid Pi CLI presentation") }
    for key in ["executablePath", "version", "message"] { _ = try cli.optionalText(key) }
    for model in try r.array("models") {
        let m = try PiReader(model)
        for key in ["provider", "id", "name"] { _ = try m.text(key) }
        if m.value["thinkingLevels"] != nil { for level in try m.array("thinkingLevels") { guard case .string = level else { throw PiReader.failure } } }
    }
    return value
}

struct PiResourceStatus: View {
    let resource: HarnessSettingsResource<JSONValue>
    var formPage = false
    var cliOnly = false
    @Environment(\.locale) private var locale
    @State private var reloading = false
    @State private var failure: String?
    private var ready: Bool { if case .ready(let value) = resource.state { return value["cli"]?["status"] == .text("ready") }; return false }
    private var loading: Bool { if case .loading = resource.state { return true }; return false }
    var body: some View {
        if cliOnly {
            NativeSettingsCliStatus(label: "Pi", status: status.message, kind: status.kind)
        } else if !formPage || reloading || (!ready && !loading) {
            NativeSettingsNotice(message: status.message, kind: status.kind,
                action: (!ready && !loading || reloading) ? AnyView(Button(piLocalized(reloading ? "重试中…" : "重试", locale)) {
                    guard !reloading else { return }; reloading = true; failure = nil
                    Task { defer { reloading = false }; do { try await resource.reload() } catch { failure = error.localizedDescription } }
                }.disabled(reloading)) : nil)
        }
    }
    private var status: (message: String, kind: NativeSettingsNotice.Kind) {
        if let failure { return (failure, .error) }
        switch resource.state {
        case .loading: return (piLocalized("正在读取 Pi 环境…", locale), .info)
        case .error(let message): return (message, .error)
        case .ready(let value):
            let cli = value["cli"]
            if cli?["status"] == .text("ready") {
                return (([piLocalized("可用", locale)] + [cli?["version"]?.stringValue, cli?["message"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · "), .success)
            }
            if let message = cli?["message"]?.stringValue, !message.isEmpty { return (message, .warning) }
            return (piLocalized("不可用", locale), .warning)
        }
    }
}

struct PiThreadSettingsView: View {
    let input: HarnessThreadInput
    let resource: HarnessSettingsResource<JSONValue>
    let update: (JSONValue) async throws -> Void
    @State private var draft: JSONValue
    @State private var busy = false
    @State private var failure: String?
    @State private var generation = 0
    @Environment(\.locale) private var locale
    init(input: HarnessThreadInput, resource: HarnessSettingsResource<JSONValue>, update: @escaping (JSONValue) async throws -> Void) {
        self.input = input; self.resource = resource; self.update = update; _draft = State(initialValue: input.thread.settings)
    }
    private var models: [JSONValue] { if case .ready(let value) = resource.state { return value["models"]?.arrayValue ?? [] }; return [] }
    private var provider: JSONText { piText(draft["provider"]) ?? "" }
    private var model: JSONText { piText(draft["model"]) ?? "" }
    private var providers: [JSONText] { var seen: Set<JSONText> = []; return models.compactMap { piText($0["provider"]) }.filter { seen.insert($0).inserted } }
    private var available: [JSONValue] { models.filter { piText($0["provider"]) == provider } }
    private var selected: JSONValue? { available.first { piText($0["id"]) == model } }
    private var choices: [JSONValue] { piThinkingChoices(selected?["thinking"]) }
    private var thinking: JSONText { piThinkingKey(draft["thinking"]) }
    private var disabled: Bool { busy || [.running, .waitingForUser].contains(input.thread.observation.latestExecution?.status ?? .completed) }
    private var changed: Bool { ["provider", "model", "thinking"].contains { draft[$0] != input.thread.settings[$0] } }
    private var complete: Bool { !provider.codeUnits.isEmpty && !model.codeUnits.isEmpty && choices.contains { piThinkingKey($0) == thinking } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PiResourceStatus(resource: resource)
            NativeSettingsGroup(title: piLocalized("Pi Thread 配置", locale)) {
                NativeSettingsRow(label: "Provider") {
                    NativeSettingsSelect(value: Binding(get: { provider }, set: { draft = .object(["provider": .string($0)]) }),
                        options: options(providers.map { ($0, $0.string) }, current: provider)).nativeSettingsControl("provider").disabled(disabled)
                }
                NativeSettingsRow(label: piLocalized("模型", locale)) {
                    NativeModelSelector(value: Binding(get: { model }, set: { draft = .object(["provider": .string(provider), "model": .string($0)]) }),
                        options: options(available.compactMap { m in piText(m["id"]).map { ($0, m["name"]?.stringValue ?? $0.string) } }, current: model))
                        .disabled(disabled || provider.codeUnits.isEmpty)
                }
                NativeSettingsRow(label: piLocalized("推理选择", locale)) {
                    NativeModelSelector(value: Binding(get: { thinking }, set: { key in
                        var fields = draft.objectValue ?? [:]; fields["thinking"] = choices.first { piThinkingKey($0) == key }; draft = .object(fields)
                    }), options: options(choices.map { (piThinkingKey($0), $0["mode"] == .text("fixed") ? piLocalized("不可配置", locale) : piThinkingLabel($0) ?? "") },
                        current: thinking, label: piThinkingLabel(draft["thinking"])), presentation: .reasoning).disabled(disabled || choices.isEmpty)
                }
                if selected?["thinking"]?["kind"] == .text("unknown") {
                    NativeSettingsNotice(message: selected?["thinking"]?["reason"]?.stringValue ?? "", kind: .warning)
                }
            }
            if let failure { PiFailure(message: failure) }
            Button(piLocalized("应用 Thread 配置", locale), action: save).disabled(disabled || !changed || !complete)
        }
        .onChange(of: input.thread.id) { _, _ in reset() }
        .onChange(of: input.thread.settings) { _, _ in reset() }
        .onDisappear { generation += 1 }
    }
    private func options(_ values: [(JSONText, String)], current: JSONText, label: String? = nil) -> [NativeSettingsOption] {
        [NativeSettingsOption(id: "", label: piLocalized("请选择", locale), disabled: true)] +
            (!current.codeUnits.isEmpty && !values.contains { $0.0 == current } ? [NativeSettingsOption(id: current, label: (label ?? current.string) + " · " + piLocalized("目录中不可用", locale))] : []) +
            values.map { NativeSettingsOption(id: $0.0, label: $0.1) }
    }
    private func reset() { generation += 1; draft = input.thread.settings; failure = nil; busy = false }
    private func save() {
        guard !disabled, changed, complete, let thinking = draft["thinking"] else { return }
        let value = JSONValue.object(["provider": .string(provider), "model": .string(model), "thinking": thinking])
        busy = true; failure = nil; generation += 1; let request = generation
        Task {
            do { try await update(value) } catch { if request == generation { failure = error.localizedDescription } }
            if request == generation { busy = false }
        }
    }
}

struct PiHarnessSettingsView: View {
    let props: HarnessSettingsProps<JSONValue, JSONValue>
    @State private var pendingProfile: JSONValue?
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if props.section == .cli { PiResourceStatus(resource: props.resource, formPage: props.settingsFormPage, cliOnly: true) }
            else {
                PiResourceStatus(resource: props.resource, formPage: props.settingsFormPage)
                NativeSettingsGroup {
                    if props.executionSnapshot {
                        fields
                        if pendingProfile != nil { NativeSettingsNotice(message: piLocalized("请补全模型相关配置；完成前不会保存此组修改。", locale), kind: .warning) }
                    }
                    else {
                        NativeSettingsUseDefaults(value: Binding(get: { props.value["useDefaultThreadSettings"] != .bool(false) }, set: { useDefault in
                            var next = props.value.objectValue ?? [:]
                            next["useDefaultThreadSettings"] = useDefault ? nil : .bool(false)
                            next["threadSettings"] = useDefault ? .object([:]) : props.value["threadSettings"] ?? .object([:])
                            props.change(.object(next))
                        })) { fields }
                    }
                }
            }
        }.environment(\.nativeSettingsFormPage, props.settingsFormPage)
            .nativeSettingsEditorReady(pendingProfile == nil)
            .onChange(of: props.host?.cwd) { _, _ in pendingProfile = nil }
    }
    private var fields: some View {
        PiDefaultFields(value: pendingProfile ?? props.value["threadSettings"] ?? .object([:]), resource: props.resource,
            formPage: props.settingsFormPage, snapshot: props.executionSnapshot) { fields in
                let profile = JSONValue.object((fields.objectValue ?? [:]).filter { $0.value != .text("") })
                if props.executionSnapshot && ["provider", "model", "thinkingLevel"].contains(where: { profile[$0] == nil }) {
                    pendingProfile = profile; return
                }
                pendingProfile = nil
                var next = props.value.objectValue ?? [:]
                if props.executionSnapshot { next["useDefaultThreadSettings"] = .bool(false) }
                next["threadSettings"] = profile
                props.change(.object(next))
            }
    }
}

private struct PiDefaultFields: View {
    let value: JSONValue
    let resource: HarnessSettingsResource<JSONValue>
    let formPage: Bool
    let snapshot: Bool
    let change: (JSONValue) -> Void
    @Environment(\.locale) private var locale
    private var models: [JSONValue] { if case .ready(let value) = resource.state { return value["models"]?.arrayValue ?? [] }; return [] }
    private var provider: JSONText { piText(value["provider"]) ?? "" }
    private var model: JSONText { piText(value["model"]) ?? "" }
    private var level: JSONText { piText(value["thinkingLevel"]) ?? "" }
    private var providers: [JSONText] { var seen: Set<JSONText> = []; return models.compactMap { piText($0["provider"]) }.filter { seen.insert($0).inserted } }
    private var available: [JSONValue] { models.filter { provider.codeUnits.isEmpty || piText($0["provider"]) == provider } }
    private var selected: JSONValue? { available.first { piText($0["id"]) == model } }
    private var levels: [JSONText] { selected?["thinkingLevels"]?.arrayValue?.compactMap { piText($0) } ?? [] }
    private var modelValue: JSONText { selected.map(modelKey) ?? model }
    var body: some View {
        if formPage {
            NativeSettingsRow(label: "Provider") {
                NativeSettingsSelect(value: Binding(get: { provider }, set: { changeProvider($0) }), options: options(providers.map { ($0, $0.string) }, current: provider)).nativeSettingsControl("provider")
            }
            NativeSettingsRow(label: piLocalized("模型", locale)) {
                NativeModelSelector(value: Binding(get: { modelValue }, set: { changeModel($0) }), options: options(available.map { (modelKey($0), ($0["provider"]?.stringValue ?? "") + " · " + ($0["name"]?.stringValue ?? "")) },
                    current: modelValue, label: (provider.codeUnits.isEmpty ? "" : provider.string + " · ") + model.string)).nativeSettingsControl("model")
            }
            NativeSettingsRow(label: piLocalized("推理强度", locale)) {
                NativeModelSelector(value: Binding(get: { level }, set: { set("thinkingLevel", $0) }), options: options(levels.map { ($0, $0.string) }, current: level), presentation: .reasoning).nativeSettingsControl("thinkingLevel")
            }
        } else {
            ForEach(["provider", "model", "thinkingLevel"], id: \.self) { key in
                NativeSettingsRow(label: key == "provider" ? "Provider" : key == "model" ? "Model" : "Thinking level") {
                    PiSettingsComboInput(value: piText(value[key]) ?? "", options: suggestions(key),
                        placeholder: piLocalized("Pi 原生默认", locale), label: key == "provider" ? "Provider" : key == "model" ? "Model" : "Thinking level",
                        change: { set(key, $0) })
                }
            }
        }
    }
    private func suggestions(_ key: String) -> [JSONText] {
        if key == "provider" { return providers }
        if key == "model" { return available.compactMap { piText($0["id"]) } }
        return levels
    }
    private func modelKey(_ value: JSONValue) -> JSONText {
        let provider = piText(value["provider"])?.codeUnits ?? []
        // Length-prefix the provider: both native identifiers can contain slashes.
        return JSONText(codeUnits: Array(String(provider.count).utf16) + [58] + provider + (piText(value["id"])?.codeUnits ?? []))
    }
    private func options(_ values: [(JSONText, String)], current: JSONText, label: String? = nil) -> [NativeSettingsOption] {
        [NativeSettingsOption(id: "", label: piLocalized(snapshot ? "请选择" : "Pi 原生默认", locale), disabled: snapshot)] +
            (!current.codeUnits.isEmpty && !values.contains { $0.0 == current } ? [NativeSettingsOption(id: current, label: (label ?? current.string) + " · " + piLocalized("目录中不可用", locale))] : []) +
            values.map { NativeSettingsOption(id: $0.0, label: $0.1) }
    }
    private func set(_ key: String, _ text: JSONText) {
        if key == "provider" { changeProvider(text); return }
        if key == "model" {
            let selected = available.first { piText($0["id"]) == text }
            changeModel(selected.map(modelKey) ?? text); return
        }
        var fields = value.objectValue ?? [:]; fields[JSONText(key)] = .string(text); change(.object(fields))
    }
    private func changeProvider(_ next: JSONText) {
        guard next != provider else { return }
        var fields = value.objectValue ?? [:]; fields["provider"] = .string(next)
        let selected = models.first { piText($0["id"]) == model && piText($0["provider"]) == next }
        fields["model"] = selected?["id"]
        let levels = selected?["thinkingLevels"]?.arrayValue?.compactMap { piText($0) } ?? []
        fields["thinkingLevel"] = .string(levels.contains(level) ? level : "")
        change(.object(fields))
    }
    private func changeModel(_ key: JSONText) {
        guard key != modelValue else { return }
        var fields = value.objectValue ?? [:]
        if let chosen = models.first(where: { modelKey($0) == key }) {
            fields["provider"] = chosen["provider"]; fields["model"] = chosen["id"]
            let levels = chosen["thinkingLevels"]?.arrayValue?.compactMap { piText($0) } ?? []
            fields["thinkingLevel"] = .string(levels.contains(level) ? level : "")
        } else { fields["model"] = .string(key); fields["thinkingLevel"] = .text("") }
        change(.object(fields))
    }
}

/// The renderer's non-page inputs allow free text and native catalog suggestions.
/// Selection carries exact UTF-16 values; displaying an unavailable setting never
/// writes its repaired display string back until the user actually edits it.
private struct PiSettingsComboInput: NSViewRepresentable {
    let value: JSONText
    let options: [JSONText]
    let placeholder: String
    let label: String
    let change: (JSONText) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSComboBox {
        let view = NSComboBox(frame: .zero)
        view.isEditable = true; view.completes = false; view.usesDataSource = false
        view.font = NSFont.systemFont(ofSize: 13); view.controlSize = .regular
        view.delegate = context.coordinator
        view.setAccessibilityLabel(label)
        return view
    }
    func updateNSView(_ view: NSComboBox, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if context.coordinator.options != options {
            view.removeAllItems(); view.addItems(withObjectValues: options.map(\.string)); context.coordinator.options = options
        }
        if JSONText(view.stringValue) != value { view.stringValue = value.string }
        view.placeholderString = placeholder; view.setAccessibilityLabel(label)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSComboBox, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 220, height: 34)
    }
    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: PiSettingsComboInput
        var options: [JSONText] = []
        var updating = false
        init(_ parent: PiSettingsComboInput) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard !updating, let control = obj.object as? NSComboBox else { return }
            parent.change(JSONText(control.stringValue))
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !updating, let control = notification.object as? NSComboBox,
                  options.indices.contains(control.indexOfSelectedItem) else { return }
            NativeSettingsChangeContext.withDiscreteChange {
                parent.change(options[control.indexOfSelectedItem])
            }
        }
    }
}
