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

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if onboarding {
                GlassEffectContainer {
                    HStack(spacing: 12) {
                        modeChoice(locale.text("跟随 Moku", "Use Moku"), inherited: true)
                        modeChoice(locale.text("单独配置", "Configure separately"), inherited: false)
                    }
                }.padding(.bottom, 18)
            } else {
                NativeSettingsRow(label: locale.text("跟随 Moku 配置", "Use Moku settings"), description: inherited
                ? locale.text("以下为 Moku 当前保存的配置。修改 Moku 后，从下个任务开始采用新配置。",
                              "Moku’s saved settings are shown below. Changes to Moku apply to the next task.")
                : locale.text("独立保存运行配置，修改从下个任务开始生效。",
                              "Execution settings are saved independently. Changes apply to the next task."), inlineControl: true) {
                NativeSettingsToggle(value: Binding(get: { inherited }, set: { setInherited($0) })).nativeSettingsControl("inherit")
                }
            }
            switch Result(catching: { try effectiveSettings(value) }) {
            case .success(let effective):
                if onboarding {
                    onboardingFields(effective).id(inherited)
                } else {
                    executionFields(effective).id(inherited).disabled(inherited)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(locale.text("运行配置", "Execution settings"))
                }
            case .failure(let error):
                NativeSettingsNotice(message: error.localizedDescription, kind: .error)
                    .nativeSettingsEditorReady(false)
            }
        }
    }

    private func modeChoice(_ title: String, inherited next: Bool) -> some View {
        Button { setInherited(next) } label: {
            HStack(spacing: 7) {
                Text(title)
                if inherited == next { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
            }
            .font(.system(size: 12, weight: inherited == next ? .medium : .regular))
            .frame(maxWidth: .infinity).frame(height: 42)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .nativeSettingsAction(next ? "inherit" : "independent", label: title, selected: inherited == next) { setInherited(next) }
    }

    @ViewBuilder private func onboardingFields(_ effective: ApplicationBackgroundExecutionSettings.Overrides) -> some View {
        if inherited {
            if let host = harnesses.first(where: { $0.descriptor.id == effective.harnessPreference }) {
                HStack(spacing: 12) {
                    host.logo(size: 24)
                    Text(host.descriptor.displayName.string).font(.system(size: 13, weight: .medium))
                    Spacer()
                }.padding(.vertical, 8)
                    .nativeSettingsEditorReady(effective.harnesses[host.descriptor.id] != nil)
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
        switch Result(catching: { try savedApplicationSettings() }) {
        case .success(let saved):
            let id = host.descriptor.id
            // The resource source is the saved application projection, even
            // when the draft selects another Harness or switches inherit mode.
            NativeHarnessSettingsView(host: workspace.harnessHost, configuration: .background(
                harnessID: id, cwd: JSONText(settingsModel.defaultCwd), settingID: settingID,
                inherited: saved.inherited, source: saved.settings.harnesses[id] ?? .null),
                section: .thread, executionSnapshot: true, settingsFormPage: true,
                value: Binding(get: { effective.harnesses[id] ?? .object([:]) },
                               set: { updateHarness(id, settings: $0) }))
                .id(id).environment(\.nativeSettingsInteractionScope, settingID.string + "." + id.string)
        case .failure(let error):
            NativeSettingsNotice(message: error.localizedDescription, kind: .error)
        }
    }

    private func effectiveSettings(_ settings: ApplicationBackgroundExecutionSettings) throws
        -> ApplicationBackgroundExecutionSettings.Overrides {
        switch settings.mode {
        case .inherit: return try savedMokuSettings()
        case .override(let overrides): return overrides
        }
    }

    private func savedMokuSettings() throws -> ApplicationBackgroundExecutionSettings.Overrides {
        guard case .string(let preference) = settingsModel.savedSettings["moku"]?["hostHarnessPreference"],
              case .object(let harnesses) = settingsModel.savedSettings["moku"]?["executionHarnesses"] else {
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
        return (try effectiveSettings(saved), inherited)
    }

    private func setInherited(_ next: Bool) {
        do {
            let mode: ApplicationBackgroundExecutionSettings.Mode
            switch (next, value.mode) {
            case (true, .override(let overrides)): mode = .inherit(independent: overrides)
            case (false, .inherit(let independent)): mode = .override(try independent ?? savedMokuSettings())
            default: return
            }
            change(.init(mode: mode))
        } catch { workspace.report(error) }
    }

    private func selectHarness(_ id: JSONText) {
        guard case .override(let overrides) = value.mode,
              harnesses.contains(where: { $0.descriptor.id == id }) else { return }
        do {
            let next = try ApplicationBackgroundExecutionSettings.Overrides(harnessPreference: id, harnesses: overrides.harnesses)
            change(.init(mode: .override(next)))
        } catch { workspace.report(error) }
    }

    private func updateHarness(_ id: JSONText, settings: JSONValue) {
        guard case .override(let overrides) = value.mode, overrides.harnessPreference == id else { return }
        do {
            var harnesses = overrides.harnesses; harnesses[id] = settings
            let next = try ApplicationBackgroundExecutionSettings.Overrides(harnessPreference: id, harnesses: harnesses)
            change(.init(mode: .override(next)))
        } catch { workspace.report(error) }
    }
}
