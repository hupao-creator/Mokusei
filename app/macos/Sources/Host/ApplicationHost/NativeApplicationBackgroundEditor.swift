import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// The application owns its draft; this shared editor only resolves the saved
/// Moku defaults and delegates each opaque Harness slice to its native plugin.
@MainActor
public struct NativeApplicationBackgroundEditor: View {
    private let workspace: NativeWorkspaceModel
    private let settingsModel: NativeSettingsModel
    private let settingID: JSONText
    private let value: ApplicationBackgroundExecutionSettings
    private let change: (ApplicationBackgroundExecutionSettings) -> Void
    @Environment(\.nativeSettingsCompactPresentation) private var onboarding
    @Environment(\.nativeSettingsEditorDrafts) private var editorDrafts
    @Environment(\.nativeSettingsRowVerticalPadding) private var rowPadding

    public init(workspace: NativeWorkspaceModel, settingsModel: NativeSettingsModel, settingID: JSONText,
                value: ApplicationBackgroundExecutionSettings,
                change: @escaping (ApplicationBackgroundExecutionSettings) -> Void) {
        self.workspace = workspace; self.settingsModel = settingsModel; self.settingID = settingID
        self.value = value; self.change = change
    }

    private var locale: DesktopLocale { workspace.preferences.locale }
    private var inherited: Bool {
        if case .inherit = value.mode { return true }; return false
    }
    private var harnesses: [AnyHarnessPlugin] {
        workspace.plugins.harnesses.modules.filter { harness in
            guard harness.descriptor.threadCapabilities.canHostMoku else { return false }
            guard onboarding else { return true }
            let plugin = settingsModel.plugins.first { $0.key == "harness:\(harness.descriptor.id.string)" }
            return settingsModel.installations[harness.descriptor.id.string]?.status == .installed
                && plugin?.enabled != false && plugin?.unavailableReason == nil
        }
    }

    private enum AgentChoice: String {
        case off, inherit, independent
    }

    private var selectedChoice: AgentChoice {
        value.enabled ? (inherited ? .inherit : .independent) : .off
    }

    private var choiceDescription: String {
        switch selectedChoice {
        case .off:
            locale.text("停止当前 Agent 并暂停自动处理。保留已有数据、待处理任务和运行配置，重新开启后继续处理。",
                        "Stops this Agent and pauses automatic processing. Existing data, pending work and execution settings are kept; enabling resumes pending work.")
        case .inherit:
            editorDrafts != nil ? locale.text("使用此设置页中的 Moku 配置，关闭设置时一并保存；保留已有的单独配置。",
                        "Uses Moku’s configuration in this Settings draft. Both are saved when Settings closes; your separate settings are kept.") : locale.text("使用下方 Moku 当前保存的配置。修改 Moku 后，从下个任务开始采用新配置；保留已有的单独配置。",
                        "Uses Moku’s saved settings shown below. Changes to Moku apply to the next task. Your separate settings are kept.")
        case .independent:
            locale.text("独立保存运行配置，修改从下个任务开始生效。切换到跟随 Moku 或关闭 Agent 后，仍保留此配置。",
                        "Saves execution settings independently. Changes apply to the next task. These settings are kept when using Moku or turning the Agent off.")
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassEffectContainer {
                HStack(spacing: 12) {
                    modeChoice(locale.text("不启用", "Agent off"), choice: .off)
                    modeChoice(locale.text("跟随 Moku", "Use Moku"), choice: .inherit)
                    modeChoice(locale.text("单独配置", "Configure separately"), choice: .independent)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(locale.text("Agent 运行方式", "Agent mode"))
            Text(choiceDescription)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.bottom, 18)
            if value.enabled { configuration }
            else {
                Color.clear.frame(height: 0).nativeSettingsEditorReady(true)
            }
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch Result(catching: { try effectiveSettings(value) }) {
            case .success(let effective):
                if onboarding {
                    onboardingFields(effective).id(inherited)
                } else {
                    executionFields(effective).id(inherited)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(locale.text("运行配置", "Execution settings"))
                }
            case .failure(let error):
                NativeSettingsNotice(message: error.localizedDescription, kind: .error)
                    .nativeSettingsEditorReady(false)
            }
        }
    }

    private func modeChoice(_ title: String, choice: AgentChoice) -> some View {
        let selected = selectedChoice == choice
        return NativeSettingsChoiceButton(title, selected: selected) { selectChoice(choice) }
        .nativeSettingsAction(choice.rawValue, label: title, selected: selected) { selectChoice(choice) }
    }

    @ViewBuilder private func onboardingFields(_ effective: ApplicationBackgroundExecutionSettings.Overrides) -> some View {
        if inherited {
            if let host = workspace.plugins.harnesses.modules.first(where: { $0.descriptor.id == effective.harnessPreference }) {
                HStack(alignment: .top, spacing: 20) {
                    HStack(spacing: 12) {
                        host.logo(size: 24)
                        Text(host.descriptor.displayName.string).font(.system(size: 13, weight: .medium))
                    // Match the first form row's 32pt content area and its
                    // inherited vertical padding, rather than aligning tops.
                    }.frame(height: 32).padding(.top, rowPadding)
                    VStack(alignment: .leading, spacing: 8) {
                        if !harnesses.contains(where: { $0.descriptor.id == host.descriptor.id }) {
                            NativeSettingsNotice(message: locale.text("Moku 当前选择的 Agent 不可用，请先检查 Moku 配置。",
                                "Moku’s selected Agent is unavailable. Check Moku configuration first."), kind: .warning)
                        }
                        harnessFields(host, effective: effective)
                    }.frame(maxWidth: .infinity)
                }.padding(.vertical, 8)
                    .nativeSettingsEditorReady(harnesses.contains { $0.descriptor.id == host.descriptor.id })
            } else {
                NativeSettingsNotice(message: locale.text("请先完成 Moku 配置。", "Complete Moku configuration first."))
                    .nativeSettingsEditorReady(false)
            }
        } else {
            HStack(spacing: 10) {
                ForEach(harnesses, id: \.descriptor.id) { harness in
                    Button { selectHarness(harness.descriptor.id) } label: {
                        HStack(spacing: 7) {
                            harness.logo(size: 17)
                            Text(harness.descriptor.displayName.string).font(.system(size: 11))
                            if effective.harnessPreference == harness.descriptor.id { Image(systemName: "checkmark").font(.system(size: 9)) }
                        }.frame(maxWidth: .infinity).frame(height: 40)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                        .nativeSettingsAction("harness." + harness.descriptor.id.string, label: harness.descriptor.displayName.string,
                                              selected: effective.harnessPreference == harness.descriptor.id) { selectHarness(harness.descriptor.id) }
                }
            }.padding(.bottom, 14)
            if let host = harnesses.first(where: { $0.descriptor.id == effective.harnessPreference }) {
                harnessFields(host, effective: effective)
            } else {
                NativeSettingsNotice(message: locale.text("请选择可用的 Agent。", "Choose an available Agent."))
                    .nativeSettingsEditorReady(false)
            }
        }
    }

    private func executionFields(_ effective: ApplicationBackgroundExecutionSettings.Overrides) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeSettingsRow(label: "Harness") {
                NativeSettingsSelect(value: Binding(get: {
                    effective.harnessPreference == "auto" ? JSONText("") : effective.harnessPreference
                }, set: { selectHarness($0) }), options:
                    (effective.harnessPreference == "auto" ? [.init(id: "", label: locale.text("请选择", "Please choose"), disabled: true)] : [])
                    + harnesses.map { .init(id: $0.descriptor.id, label: $0.descriptor.displayName.string) }).nativeSettingsControl("harness")
                    .disabled(inherited)
            }
            if let host = workspace.plugins.harnesses.modules.first(where: { $0.descriptor.id == effective.harnessPreference }) {
                harnessFields(host, effective: effective)
            } else {
                NativeSettingsNotice(message: locale.text("请先选择 Moku 的协调 Agent 并固定运行配置。",
                    "Choose Moku’s coordinating Agent and save its execution settings first."))
            }
        }
    }

    @ViewBuilder private func harnessFields(_ host: AnyHarnessPlugin,
                                            effective: ApplicationBackgroundExecutionSettings.Overrides) -> some View {
        switch Result(catching: { try settingsConfiguration(host.descriptor.id, effective: effective) }) {
        case .success(let configuration):
            let id = host.descriptor.id
            NativeHarnessSettingsView(host: workspace.harnessHost, configuration: configuration,
                section: .thread, executionSnapshot: true, settingsFormPage: true, readOnly: inherited,
                value: Binding(get: { effective.harnesses[id] ?? .object([:]) },
                               set: { updateHarness(id, settings: $0) }))
                .id(id).environment(\.nativeSettingsInteractionScope, settingID.string + "." + id.string)
        case .failure(let error):
            NativeSettingsNotice(message: error.localizedDescription, kind: .error)
                .nativeSettingsEditorReady(false)
        }
    }

    private func settingsConfiguration(_ id: JSONText, effective: ApplicationBackgroundExecutionSettings.Overrides) throws
        -> NativeHarnessSettingsConfiguration {
        let cwd = JSONText(settingsModel.defaultCwd)
        if inherited {
            // Follow the saved Moku resource even while an application's mode
            // change is still saving; its old independent catalog is unrelated.
            return .init(harnessID: id, cwd: cwd, source: settingsModel.savedSettings["moku"]?["executionHarnesses"]?[id.string] ?? .null,
                         scope: .global(executionOwner: .moku))
        }
        let saved = try savedApplicationSettings()
        return .background(harnessID: id, cwd: cwd, settingID: settingID,
                           inherited: saved.inherited, source: saved.settings.harnesses[id] ?? .null)
    }

    private func effectiveSettings(_ settings: ApplicationBackgroundExecutionSettings) throws
        -> ApplicationBackgroundExecutionSettings.Overrides {
        switch settings.mode {
        case .inherit: return try mokuSettings(editorDrafts == nil ? settingsModel.savedSettings : settingsModel.draft.value)
        case .override(let overrides): return overrides
        }
    }

    private func savedMokuSettings() throws -> ApplicationBackgroundExecutionSettings.Overrides {
        try mokuSettings(settingsModel.savedSettings)
    }

    private func mokuSettings(_ source: JSONValue) throws -> ApplicationBackgroundExecutionSettings.Overrides {
        guard case .string(let preference) = source["moku"]?["hostHarnessPreference"],
              case .object(let harnesses) = source["moku"]?["executionHarnesses"] else {
            throw PluginContractError("Invalid saved Moku execution settings")
        }
        return try .init(harnessPreference: preference, harnesses: harnesses)
    }

    private func savedApplicationSettings() throws -> (settings: ApplicationBackgroundExecutionSettings.Overrides, inherited: Bool) {
        guard let entry = settingsModel.savedSettings["pluginSettings"]?.arrayValue?.first(where: { $0["id"] == .string(settingID) }),
              let settings = entry["value"] else {
            throw PluginContractError("Unknown application settings: \(settingID.string)")
        }
        let saved = try ApplicationBackgroundExecutionSettings(json: settings)
        let inherited: Bool
        if case .inherit = saved.mode { inherited = true } else { inherited = false }
        if case .override(let overrides) = saved.mode { return (overrides, false) }
        return (try savedMokuSettings(), inherited)
    }

    private func selectChoice(_ choice: AgentChoice) {
        guard choice != selectedChoice else { return }
        do {
            // Off preserves the underlying mode. Enabling and choosing a source
            // share one draft update, so no intermediate configuration is saved.
            let mode: ApplicationBackgroundExecutionSettings.Mode
            switch (choice, value.mode) {
            case (.inherit, .override(let overrides)): mode = .inherit(independent: overrides)
            case (.independent, .inherit(let independent)): mode = .override(try independent ?? mokuSettings(editorDrafts == nil ? settingsModel.savedSettings : settingsModel.draft.value))
            default: mode = value.mode
            }
            NativeSettingsChangeContext.withDiscreteChange {
                change(.init(mode: mode, enabled: choice != .off))
            }
        } catch { workspace.report(error) }
    }

    private func selectHarness(_ id: JSONText) {
        guard case .override(let overrides) = value.mode,
              harnesses.contains(where: { $0.descriptor.id == id }) else { return }
        do {
            let next = try ApplicationBackgroundExecutionSettings.Overrides(harnessPreference: id, harnesses: overrides.harnesses)
            change(.init(mode: .override(next), enabled: value.enabled))
        } catch { workspace.report(error) }
    }

    private func updateHarness(_ id: JSONText, settings: JSONValue) {
        guard case .override(let overrides) = value.mode, overrides.harnessPreference == id else { return }
        do {
            var harnesses = overrides.harnesses; harnesses[id] = settings
            let next = try ApplicationBackgroundExecutionSettings.Overrides(harnessPreference: id, harnesses: harnesses)
            change(.init(mode: .override(next), enabled: value.enabled))
        } catch { workspace.report(error) }
    }
}
