import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI

enum NativeOnboardingStep: Int, CaseIterable {
    case discovery, moku, tag, report, landing
    var settingID: String? {
        switch self { case .tag: "tag.settings"; case .report: "report.settings"; default: nil }
    }
}

/// The profile owns completion, the Runtime owns execution settings, and this
/// window owns the pending step and the visual handoff into its existing Dock.
@MainActor @Observable final class NativeOnboardingState {
    let workspace: NativeWorkspaceModel
    let interactions = NativeSettingsInteractions()
    let visit = UUID()
    private(set) var admitted = false
    private(set) var finished: Bool
    private(set) var step = NativeOnboardingStep.discovery
    private(set) var busy = false
    var error: String?
    private(set) var editors = Dictionary(uniqueKeysWithValues: NativeOnboardingStep.allCases.map { ($0, NativeSettingsReadiness()) })
    var editorReady: Bool { editors[step]?.ready == true }
    var mounted = false
    var mountDock = false
    var dockVisible = false
    var panelFrame = CGRect.zero
    var blocksWorkspace: Bool { !finished }
    var settings: NativeSettingsModel { workspace.settingsModel }
    var locale: DesktopLocale { workspace.preferences.locale }
    var context: NativeSettingsInteractionContext {
        .init(visit: visit, section: "onboarding.\(step.rawValue)")
    }
    var harnesses: [AnyHarnessPlugin] {
        workspace.plugins.harnesses.modules.filter { harness in
            let plugin = settings.plugins.first { $0.key == "harness:\(harness.descriptor.id.string)" }
            return plugin?.enabled != false && plugin?.unavailableReason == nil
        }
    }
    var installed: [AnyHarnessPlugin] {
        harnesses.filter { settings.installations[$0.descriptor.id.string]?.status == .installed }
    }
    var detecting: Bool {
        settings.installationLoadState == .notLoaded || settings.installationLoadState == .loading
            || harnesses.contains { settings.installations[$0.descriptor.id.string]?.status == .checking }
    }
    var selectedHost: AnyHarnessPlugin? {
        let id = settings.draft.value["moku"]?["hostHarnessPreference"]?.stringValue
        return installed.first { $0.descriptor.id.string == id && $0.descriptor.threadCapabilities.canHostMoku }
    }
    var targets: Set<String> {
        Set(settings.draft.value["moku"]?["targetHarnessIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }
    var canAdvance: Bool {
        guard admitted, !busy, workspace.runtimeAvailable,
              !settings.draft.composing, settings.draft.firstInvalidField == nil else { return false }
        if step != .discovery, settings.draft.error != nil { return false }
        switch step {
        case .discovery: return installed.contains { $0.descriptor.threadCapabilities.canHostMoku }
        case .moku: return selectedHost != nil && !validTargets.isEmpty && editorReady
        case .tag, .report: return roleIsAvailable && editorReady
        case .landing: return false
        }
    }
    private var validTargets: Set<String> { targets.intersection(installed.map { $0.descriptor.id.string }) }
    private var roleIsAvailable: Bool {
        guard let id = step.settingID,
              let raw = settings.draft.value["pluginSettings"]?.arrayValue?.first(where: { $0["id"] == .text(id) })?["value"],
              let value = try? ApplicationBackgroundExecutionSettings(json: raw) else { return false }
        switch value.mode {
        case .inherit: return selectedHost != nil
        case .override(let profile):
            return installed.contains { $0.descriptor.id == profile.harnessPreference && $0.descriptor.threadCapabilities.canHostMoku }
        }
    }

    init(workspace: NativeWorkspaceModel) {
        self.workspace = workspace
        finished = workspace.preferences.onboardingCompleted
        mountDock = finished; dockVisible = finished
    }

    func admitIfNeeded() {
        guard !finished, !admitted, workspace.hasInitialContent else { return }
        do {
            let catalog = workspace.catalog
            let previousActivity = catalog.threads.contains { $0.id != catalog.moku?.id }
                || !catalog.applicationThreads.isEmpty
                || catalog.moku?.observation.latestExecution != nil || catalog.moku?.pendingInput == true
            if !workspace.preferences.onboardingPending, previousActivity {
                try workspace.preferences.setOnboardingCompleted(true)
                finishHandoff()
                return
            }
            // Store pending before any normal preference save can make a fresh
            // profile look like an established desktop on its next launch.
            try workspace.preferences.setOnboardingCompleted(false)
            admitted = true; error = nil
        } catch { self.error = error.localizedDescription }
    }

    func advance() async {
        guard canAdvance else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if step == .discovery {
                seedAvailableSelections()
            } else {
                // Discovery can change while the editor is mounted. Keep only
                // real targets at the configuration boundary before persisting.
                if step == .moku, targets != validTargets {
                    settings.draft.change(settingsReplacing(settings.draft.value, path: ["moku", "targetHarnessIds"],
                        value: .array(validTargets.sorted().map(JSONValue.text))))
                }
                try await settings.draft.flush()
            }
            try Task.checkCancellation()
            guard workspace.runtimeAvailable else { throw RuntimeError("UNAVAILABLE", locale.text("连接恢复后再继续。", "Reconnect before continuing.")) }
            if step == .report { try workspace.preferences.setOnboardingCompleted(true) }
            step = NativeOnboardingStep(rawValue: step.rawValue + 1)!
            editors[step] = NativeSettingsReadiness()
        } catch { self.error = error.localizedDescription }
    }

    func back() {
        guard admitted, !busy, step != .discovery, step != .landing else { return }
        step = NativeOnboardingStep(rawValue: step.rawValue - 1)!
        editors[step] = NativeSettingsReadiness(); error = nil
    }

    func retry() {
        error = nil
        if !admitted { admitIfNeeded() }
        else if settings.draft.error != nil { settings.draft.retry() }
        else if step == .discovery { Task { await settings.refreshInstallations() } }
        else { Task { await advance() } }
    }

    func finishHandoff() {
        finished = true; mountDock = true; dockVisible = true
    }

    private func seedAvailableSelections() {
        guard let host = selectedHost ?? installed.first(where: { $0.descriptor.threadCapabilities.canHostMoku }) else { return }
        var value = settingsReplacing(settings.draft.value, path: ["moku", "hostHarnessPreference"], value: .string(host.descriptor.id))
        let selection = validTargets.isEmpty ? Set(installed.map { $0.descriptor.id.string }) : validTargets
        value = settingsReplacing(value, path: ["moku", "targetHarnessIds"], value: .array(selection.sorted().map(JSONValue.text)))
        settings.draft.change(value)
    }
}
