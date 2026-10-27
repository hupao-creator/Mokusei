import Foundation
import MokuseiCore
import MokuseiPluginAPI

@MainActor
public struct NativeHarnessHostCallbacks {
    public let beforeCommand: () async throws -> Void
    public let canExecute: (HarnessThread) -> Bool
    public let openExternal: (JSONText) async throws -> Void
    public let openFollowUp: (JSONText, JSONText) -> Void
    public let onError: (Error) -> Void
    public let previewAttachment: ((JSONText, JSONText) async throws -> Data)?
    public let resolveMedia: (@Sendable (URL) async throws -> Data)?

    public init(beforeCommand: @escaping () async throws -> Void = {},
                canExecute: @escaping (HarnessThread) -> Bool = { $0.archived != true },
                openExternal: @escaping (JSONText) async throws -> Void,
                openFollowUp: @escaping (JSONText, JSONText) -> Void,
                onError: @escaping (Error) -> Void,
                previewAttachment: ((JSONText, JSONText) async throws -> Data)? = nil,
                resolveMedia: (@Sendable (URL) async throws -> Data)? = nil) {
        self.beforeCommand = beforeCommand; self.canExecute = canExecute
        self.openExternal = openExternal; self.openFollowUp = openFollowUp; self.onError = onError
        self.previewAttachment = previewAttachment; self.resolveMedia = resolveMedia
    }
}

/// Thread workspace navigation can route links and editable drafts to its
/// sidecards while runtime commands remain bound by composition.
@MainActor
public struct NativeHarnessThreadRoutes {
    public let interrupt: (() async throws -> Void)?
    public let openFollowUp: ((JSONText) -> Void)?
    public let openExternal: ((JSONText) async throws -> Void)?
    public init(interrupt: (() async throws -> Void)? = nil,
                openFollowUp: ((JSONText) -> Void)? = nil,
                openExternal: ((JSONText) async throws -> Void)? = nil) {
        self.interrupt = interrupt; self.openFollowUp = openFollowUp; self.openExternal = openExternal
    }
}

/// Application-owned conversations provide current public presentation and
/// lifecycle authority without entering the ordinary thread catalog.
@MainActor
public struct NativeHarnessConversationSource {
    public let read: () -> HarnessThread?
    public let canExecute: () -> Bool
    public init(read: @escaping () -> HarnessThread?, canExecute: @escaping () -> Bool) {
        self.read = read; self.canExecute = canExecute
    }
}

/// Composition owns runtime authority and resource lifetimes. It is deliberately
/// not Observable: a streamed row must never invalidate the workspace catalog.
@MainActor
public final class NativeHarnessHost {
    public let registry: HarnessPluginRegistry
    let client: RuntimeClient
    let callbacks: NativeHarnessHostCallbacks
    private let currentThread: (JSONText) -> HarnessThread?
    private var resources: [String: HarnessContentResource] = [:]
    private var surfaces: [UUID: WeakHarnessSurface] = [:]
    private var settingsSurfaces: [UUID: WeakHarnessSettingsSurface] = [:]
    private var globalSettingsSurfaces: [NativeHarnessSettingsConfiguration: NativeHarnessSettingsSurface] = [:]
    private var settingsAuthority: UUID?
    public let settingsLifetime = NativeHarnessSettingsLifetime()
    private var allowedGlobalSettings: Set<NativeHarnessSettingsConfiguration>?

    public init(client: RuntimeClient, registry: HarnessPluginRegistry,
                currentThread: @escaping (JSONText) -> HarnessThread?,
                callbacks: NativeHarnessHostCallbacks) {
        self.client = client; self.registry = registry; self.currentThread = currentThread; self.callbacks = callbacks
    }

    public func receive(_ event: RuntimeClientEvent) {
        switch event {
        case let .threadContent(id, state):
            guard let resource = resources[id] else { return }
            switch state {
            case .loading: resource.publish(.loading)
            case .ready(let value): resource.publish(.ready(value))
            case .error(let message): resource.publish(.error(message))
            }
        case .snapshot(_, let authority), .mutation(_, _, let authority):
            if settingsAuthority != authority {
                releaseGlobalSettings()
                settingsAuthority = authority
            }
            // The shell applies catalog changes before forwarding this event.
            for (id, weakSurface) in surfaces {
                guard let surface = weakSurface.value else { surfaces[id] = nil; continue }
                if !surface.hasAuthority { surface.invalidate() }
            }
            for (id, weakSurface) in settingsSurfaces {
                guard let surface = weakSurface.value else { settingsSurfaces[id] = nil; continue }
                surface.reconcileAuthority()
            }
        case .connection(let status):
            if status != .connected { setSettingsAvailable(false) }
        case .synchronizing, .overviewFilter, .failure: break
        }
    }

    public func makeThreadSurface(input: HarnessThreadInput,
                                  presentation: HarnessConversationPresentation = .main(excludedExecutionIDs: []),
                                  source: NativeHarnessConversationSource? = nil,
                                  routes: NativeHarnessThreadRoutes? = nil,
                                  onIndexChange: @escaping (ThreadConversationIndex) -> Void = { _ in }) throws -> NativeHarnessThreadSurface {
        _ = try authoritativeThread(threadID: input.thread.id, harnessID: input.thread.harnessID, source: source)
        let surface = NativeHarnessThreadSurface(host: self, plugin: try registry.require(input.thread.harnessID),
                                                 input: input, presentation: presentation, source: source, routes: routes, onIndexChange: onIndexChange)
        surfaces[surface.id] = WeakHarnessSurface(surface)
        return surface
    }

    /// The registry snapshot owns both envelope and native private view. Keep
    /// this object with a queued layout revision and render its card directly.
    public func overview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewSnapshot {
        try registry.require(input.thread.harnessID).projectOverview(input: input, availableColumns: availableColumns)
    }

    public func mokuPresentation(input: HarnessThreadInput) throws -> HarnessMokuPresentation? {
        try registry.require(input.thread.harnessID).projectMokuDock(input: input)
    }

    public func executionTokenUsage(thread: HarnessThread, executionID: JSONText) throws -> HarnessExecutionTokenUsage? {
        guard let value = try registry.require(thread.harnessID).executionTokenUsage(thread: thread, executionID: executionID),
              value.count.isFinite, value.count > 0 else { return nil }
        return value
    }

    public func actions(for thread: HarnessThread, source: NativeHarnessConversationSource? = nil,
                        routes: NativeHarnessThreadRoutes? = nil) -> HarnessThreadActions {
        boundActions(threadID: thread.id, harnessID: thread.harnessID,
            observedCancellationID: thread.cancellationID, source: source, routes: { routes }, checkLifetime: {})
    }

    func authoritativeThread(threadID: JSONText, harnessID: JSONText, execution: Bool = false,
                             source: NativeHarnessConversationSource? = nil) throws -> HarnessThread {
        let current: HarnessThread?
        if let source { current = source.read() }
        else { current = currentThread(threadID) }
        guard let thread = current, thread.id == threadID, thread.harnessID == harnessID else {
            throw PluginContractError("This thread is no longer available to its Harness")
        }
        if execution && (thread.archived == true || !callbacks.canExecute(thread) || source?.canExecute() == false) {
            throw PluginContractError("This thread currently cannot accept actions")
        }
        return thread
    }

    func hasAuthority(threadID: JSONText, harnessID: JSONText) -> Bool {
        (try? authoritativeThread(threadID: threadID, harnessID: harnessID)) != nil
    }

    func register(_ resource: HarnessContentResource, id: String) { resources[id] = resource }
    func unregisterResource(_ id: String) { resources[id] = nil }
    func unregisterSurface(_ id: UUID) { surfaces[id] = nil }
    func unregisterSettingsSurface(_ id: UUID) {
        settingsSurfaces[id] = nil
        globalSettingsSurfaces = globalSettingsSurfaces.filter { $0.value.id != id }
    }

    public func makeSettingsSurface(configuration: NativeHarnessSettingsConfiguration) throws -> NativeHarnessSettingsSurface {
        if case .global = configuration.scope {
            guard settingsLifetime.available,
                  allowedGlobalSettings?.contains(configuration.editorIdentity) != false else { throw CancellationError() }
        }
        if case .global = configuration.scope,
           let surface = globalSettingsSurfaces[configuration.editorIdentity], !surface.isReleased {
            try surface.updateSource(configuration)
            return surface
        }
        let surface = NativeHarnessSettingsSurface(host: self, plugin: try registry.require(configuration.harnessID), configuration: configuration)
        try surface.checkAuthority()
        settingsSurfaces[surface.id] = WeakHarnessSettingsSurface(surface)
        if case .global = configuration.scope { globalSettingsSurfaces[configuration.editorIdentity] = surface }
        return surface
    }

    /// The workspace owns these reads independently of editor mounts. A child
    /// cancellation stops retries, while another editor can still join a read.
    public func prefetchSettings(configurations: [NativeHarnessSettingsConfiguration], reload: Bool = false) async {
        guard !Task.isCancelled else { return }
        let generation = settingsLifetime.generation
        let loads: [Task<Void, Never>] = configurations.compactMap { configuration in
            guard case .global = configuration.scope else { return nil }
            return Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled, self.settingsLifetime.generation == generation,
                      let surface = try? self.makeSettingsSurface(configuration: configuration) else { return }
                for delay in [0, 1, 3] {
                    do {
                        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                        try Task.checkCancellation()
                        // A newer saved source owns its own prefetch. Never
                        // let an obsolete retry restore the old source.
                        guard self.settingsLifetime.generation == generation, surface.configuration == configuration else { return }
                        if reload && delay == 0 { try await surface.reload() }
                        else { try await surface.loadIfNeeded() }
                        if surface.executionSnapshotError == nil { return }
                    } catch is CancellationError { return }
                    catch { /* Keep the resource's failure visible to its editor. */ }
                }
            }
        }
        await withTaskCancellationHandler {
            for load in loads { await load.value }
        } onCancel: {
            for load in loads { load.cancel() }
        }
    }

    /// Evict removed workspaces/scopes, without retaining every previous cwd.
    public func retainGlobalSettings(configurations: [NativeHarnessSettingsConfiguration]) {
        let identities = Set(configurations.map(\.editorIdentity))
        allowedGlobalSettings = identities
        for (identity, surface) in Array(globalSettingsSurfaces) where !identities.contains(identity) {
            surface.release()
        }
    }

    public func releaseGlobalSettings(harnessID: JSONText? = nil) {
        settingsLifetime.generation = UUID()
        let current = globalSettingsSurfaces.values.filter { harnessID == nil || $0.configuration.harnessID == harnessID }
        for surface in current { surface.release() }
    }

    public func setSettingsAvailable(_ available: Bool) {
        guard settingsLifetime.available != available else { return }
        settingsLifetime.available = available
        if !available { releaseGlobalSettings() }
        else { settingsLifetime.generation = UUID() }
    }

    public func makeThreadSettingsSurface(input: HarnessThreadInput) throws -> NativeHarnessSettingsSurface {
        try makeSettingsSurface(configuration: .thread(input.thread))
    }

    public func releaseAll() async {
        setSettingsAvailable(false)
        let current = surfaces.values.compactMap(\.value)
        let settings = settingsSurfaces.values.compactMap(\.value)
        for surface in settings { surface.release() }
        for surface in current { await surface.release() }
        let orphaned = resources.values
        resources.removeAll(); surfaces.removeAll(); settingsSurfaces.removeAll()
        for resource in orphaned { await resource.release() }
        for module in registry.modules { module.clearProjectionCache() }
    }
}

@MainActor private final class WeakHarnessSurface {
    weak var value: NativeHarnessThreadSurface?
    init(_ value: NativeHarnessThreadSurface) { self.value = value }
}
@MainActor private final class WeakHarnessSettingsSurface {
    weak var value: NativeHarnessSettingsSurface?
    init(_ value: NativeHarnessSettingsSurface) { self.value = value }
}
