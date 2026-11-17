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
        // Installation reads use the same bounded queue. Resolve availability
        // first instead of putting speculative CLI probes ahead of detection.
        let harnesses = workspace.plugins.harnesses.modules.filter {
            enabled.contains("harness:" + $0.descriptor.id.string)
                && model.installations[$0.descriptor.id.string]?.status == .installed
        }
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
                      let value = entry["value"], let saved = try? ApplicationBackgroundExecutionSettings(json: value), saved.enabled else { continue }
                // Inherited editors already consume the Moku surface above.
                // Only independent modes introduce another native workspace.
                guard case .override(let overrides) = saved.mode else { continue }
                next.append(.background(harnessID: id, cwd: cwd, settingID: definition.id,
                                        inherited: false, source: overrides.harnesses[id] ?? .null))
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
            await Self.prefetch(next, host: host)
            // Model capabilities change independently of installation paths.
            // Revalidate at the native catalog TTL without clearing visible
            // editors or forcing unrelated Harness caches to expire.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                await Self.prefetch(next, host: host, reload: true)
            }
        }
    }

    private static func prefetch(_ configurations: [NativeHarnessSettingsConfiguration], host: NativeHarnessHost,
                                 reload: Bool = false) async {
        guard !Task.isCancelled else { return }
        let loads = Dictionary(grouping: configurations, by: \.harnessID).values.map { configurations in
            Task { @MainActor [host] in
                let execution = configurations.filter(\.isExecutionConfiguration)
                let defaults = configurations.filter { !$0.isExecutionConfiguration }
                // Each Harness advances independently. Ordinary defaults
                // cannot queue ahead of the profiles onboarding will mount.
                guard !Task.isCancelled else { return }
                await host.prefetchSettings(configurations: execution, reload: reload)
                // Leave the queue free for execution recovery after failure;
                // an explicitly opened defaults editor can still demand a read.
                guard !Task.isCancelled, execution.allSatisfy({
                    host.cachedSettingsSurface(configuration: $0)?.loadState == .ready
                }) else { return }
                await host.prefetchSettings(configurations: defaults, reload: reload)
            }
        }
        await withTaskCancellationHandler {
            for load in loads { await load.value }
        } onCancel: {
            for load in loads { load.cancel() }
        }
    }

    func stop() {
        task?.cancel(); task = nil; configurations = []; refreshSequences = [:]; authority = nil
        host.setSettingsAvailable(false)
    }
}
