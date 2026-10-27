import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Settings acquisition belongs to the connected workspace, so opening a page
/// or selecting a Harness only attaches to resources that are already loading.
@MainActor
final class NativeWorkspaceSettingsPrefetch {
    private let host: NativeHarnessHost
    private var configurations: [NativeHarnessSettingsConfiguration] = []
    private var refreshSequences: [String: Int] = [:]
    private var authority: UUID?
    private var task: Task<Void, Never>?

    init(host: NativeHarnessHost) { self.host = host }

    func update(workspace: NativeWorkspaceModel) {
        guard workspace.runtimeAvailable else { stop(); return }
        host.setSettingsAvailable(true)
        let model = workspace.settingsModel
        let settings = model.savedSettings
        let cwd = JSONText(model.defaultCwd)
        let enabled = Set(model.plugins.filter { $0.enabled && $0.unavailableReason == nil }.map(\.key))
        let harnesses = workspace.plugins.harnesses.modules.filter { enabled.contains("harness:" + $0.descriptor.id.string) }
        let backgroundSettings = workspace.plugins.applications.modules
            .filter { enabled.contains("extension:" + $0.manifest.id.string) }
            .flatMap(\.settings)
            .filter { $0.requires.contains(ApplicationCapabilities.backgroundConfigurationUI.requirement) }
        var next: [NativeHarnessSettingsConfiguration] = []
        for harness in harnesses {
            let id = harness.descriptor.id
            next.append(.init(harnessID: id, cwd: cwd, source: settings["harnesses"]?[id.string] ?? .null))
            guard harness.descriptor.threadCapabilities.canHostMoku else { continue }
            let execution = settings["moku"]?["executionHarnesses"]?[id.string] ?? .null
            next.append(.init(harnessID: id, cwd: cwd, source: execution, scope: .global(executionOwner: .moku)))
            for definition in backgroundSettings {
                guard let entry = settings["pluginSettings"]?.arrayValue?.first(where: { $0["id"] == .string(definition.id) }),
                      let value = entry["value"], let saved = try? ApplicationBackgroundExecutionSettings(json: value) else { continue }
                let source: JSONValue
                let inherited: Bool
                switch saved.mode {
                case .inherit: source = execution; inherited = true
                case .override(let overrides): source = overrides.harnesses[id] ?? .null; inherited = false
                }
                next.append(.background(harnessID: id, cwd: cwd, settingID: definition.id,
                                        inherited: inherited, source: source))
            }
        }
        let sequences = model.detailRefreshSequences
        guard next != configurations || sequences != refreshSequences || authority != workspace.snapshotAuthority else { return }
        task?.cancel()
        for (id, sequence) in sequences where sequence != refreshSequences[id, default: 0] {
            host.releaseGlobalSettings(harnessID: JSONText(id))
        }
        configurations = next; refreshSequences = sequences; authority = workspace.snapshotAuthority
        host.retainGlobalSettings(configurations: next)
        task = Task { [host] in
            await host.prefetchSettings(configurations: next)
            // Model capabilities change independently of installation paths.
            // Revalidate at the native catalog TTL without clearing visible
            // editors or forcing unrelated Harness caches to expire.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                await host.prefetchSettings(configurations: next, reload: true)
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil; configurations = []; refreshSequences = [:]; authority = nil
        host.setSettingsAvailable(false)
    }
}
