import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiVoice

@MainActor @Observable
public final class NativeWorkspaceModel {
    public let client: RuntimeClient
    public let preferences: DesktopPreferences
    public let plugins: NativePluginComposition
    public let timer: NativeMokuTimerController
    public let catalog = NativeWorkspaceCatalog()
    @ObservationIgnored public let startupPerformance: NativeStartupPerformance?
    public var hasInitialContent: Bool { hasSnapshot && catalog.hasMoku }
    private var hasSnapshot = false
    public private(set) var connection: RuntimeConnectionStatus = .connecting
    public private(set) var connectionRevision = 0
    public private(set) var recoveryRevision = 0
    public private(set) var snapshotAuthority: UUID?
    public private(set) var state: JSONValue? {
        didSet {
            let loaded = state != nil
            if hasSnapshot != loaded { hasSnapshot = loaded }
        }
    }
    public private(set) var connectionError: String? {
        didSet { if connectionError != nil && !hasInitialContent { startupPerformance?.fail() } }
    }
    @ObservationIgnored private var catalogError: String?
    public private(set) var reconnecting = false
    public private(set) var synchronizing = true
    public private(set) var operationError: String? { didSet { operationErrorID = UUID() } }
    @ObservationIgnored private var operationErrorID = UUID()
    public private(set) var stopping = false
    public var settingsOpen = false
    public var runtimeAvailable: Bool {
        connection == .connected && !synchronizing && connectionError == nil && !stopping
    }
    public var localizedOperationError: String? {
        guard let operationError else { return nil }
        // Translate only Core-owned copy. Provider/native messages stay intact.
        let translations = [
            "附件数量不能超过 20 个": "You can attach at most 20 files.",
            "附件正在处理中，请稍候": "Attachments are being processed. Please wait.",
            "此 Thread 已归档，取消归档后才能追加任务。": "This Thread is archived. Unarchive it to add a task.",
            "关联 Thread 已删除，无法打开。": "The linked Thread was deleted and cannot be opened."
        ]
        return preferences.locale == .english ? translations[operationError] ?? operationError : operationError
    }
    @ObservationIgnored private let catalogPreparation = NativeCatalogPreparation()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var localeTask: Task<Void, Error>?
    @ObservationIgnored private var connectionRequestID: UUID?
    @ObservationIgnored public var onCatalogChange: ((RuntimeClientEvent) -> Void)?
    @ObservationIgnored public var onConnectionChange: ((RuntimeConnectionStatus) -> Void)?
    @ObservationIgnored public var onOverviewFilter: ((JSONValue) -> Void)?
    @ObservationIgnored public var onFollowUp: ((JSONText, JSONText) -> Void)?
    @ObservationIgnored public var onStopped: (() async -> Void)?
    @ObservationIgnored public lazy var services = NativeWorkspaceServices(workspace: self)
    @ObservationIgnored public lazy var voice = NativeVoiceCoordinator(client: client, beforeCommand: { [weak self] in
        guard let self else { throw CancellationError() }; try await self.prepareCommand()
    })
    @ObservationIgnored public lazy var settingsModel = makeSettingsModel()
    @ObservationIgnored private lazy var settingsPrefetch = NativeWorkspaceSettingsPrefetch(host: harnessHost)
    @ObservationIgnored public lazy var harnessHost = NativeHarnessHost(
        client: client, registry: plugins.harnesses,
        currentThread: { [weak self] in self?.catalog.thread($0) },
        callbacks: NativeHarnessHostCallbacks(
            beforeCommand: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.prepareCommand()
            },
            canExecute: { [weak self] thread in self?.canExecute(thread) == true },
            openExternal: { [weak self] text in
                guard let self else { throw CancellationError() }
                try await self.services.openExternal(text)
            },
            openFollowUp: { [weak self] thread, draft in self?.onFollowUp?(thread, draft) },
            onError: { [weak self] error in self?.report(error) },
            previewAttachment: { [weak self] thread, attachment in
                guard let self else { throw CancellationError() }
                return try await self.services.preview(threadID: thread, attachmentID: attachment)
            }
        )
    )

    public init(client: RuntimeClient, preferences: DesktopPreferences, plugins: NativePluginComposition,
                startupPerformance: NativeStartupPerformance? = nil,
                timer: NativeMokuTimerController? = nil) {
        self.client = client
        self.preferences = preferences
        self.plugins = plugins
        self.timer = timer ?? NativeMokuTimerController()
        self.startupPerformance = startupPerformance
        preferences.diagnostics = SettingsDiagnostics(client: client)
    }

    private func makeSettingsModel() -> NativeSettingsModel {
        let model = NativeSettingsModel(settings: catalog.settings, revision: catalog.settingsRevision,
            save: { [weak self] settings, revision in
                guard let self else { throw CancellationError() }
                let response = try await self.invoke("app:update-settings", args: [.object([
                    "settings": settings, "expectedSettingsRevision": .integer(revision)
                ])])
                guard let settings = response["settings"], let revision = response["settingsRevision"]?.intValue,
                      revision >= 0, let status = response["status"]?.stringValue else {
                    throw PluginContractError("Invalid saved settings response")
                }
                switch status {
                case "saved": return .saved(settings: settings, revision: revision)
                case "conflict": return .conflict(settings: settings, revision: revision)
                default: throw PluginContractError("Unknown settings save outcome")
                }
            }, clearHistory: { [weak self] in
                guard let self else { throw CancellationError() }; _ = try await self.invoke("history:clear")
            }, loadInstallations: { [weak self] in
                guard let self else { throw CancellationError() }; return try await self.invoke("harness:detect-installations")
            }, installHarness: { [weak self] id in
                guard let self else { throw CancellationError() }; _ = try await self.invoke("harness:install", args: [.text(id)])
            }, loadInstallation: { [weak self] id in
                guard let self else { throw CancellationError() }; return try await self.invoke("harness:detect-installation", args: [.text(id)])
            })
        model.draft.diagnostics = SettingsDiagnostics(client: client)
        model.onDiscoveryChange = { [weak self] in self?.refreshSettingsPrefetch() }
        model.draft.onClosedSaveError = { [weak self] message in
            self?.operationError = message
            let noticeID = self?.operationErrorID
            return { [weak self] in if self?.operationErrorID == noticeID { self?.operationError = nil } }
        }
        model.receive(snapshot: state, runtimeAvailable: runtimeAvailable)
        model.activeHostHarnessID = catalog.moku?.harnessID.string
        model.mokuRunning = catalog.executions.contains { $0["threadId"] == catalog.moku.map { .string($0.id) } }
        return model
    }

    public func start() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self, client] in
            while !Task.isCancelled {
                let stream = await client.events()
                for await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .connection(let status):
                        self.harnessHost.receive(event)
                        if status == .connected, self.connection != .connected { self.connectionRevision += 1 }
                        if status != .connected, self.connection == .connected { self.recoveryRevision += 1 }
                        self.connection = status
                        self.voice.configureMoku(owner: self.catalog.moku?.id,
                            available: status == .connected && !self.stopping)
                        if status == .connected { self.connectionError = self.catalogError }
                        self.settingsModel.receive(snapshot: self.state, runtimeAvailable: self.runtimeAvailable)
                        self.onConnectionChange?(status)
                    case .synchronizing(let value):
                        self.synchronizing = value
                        self.settingsModel.receive(snapshot: self.state, runtimeAvailable: self.runtimeAvailable)
                        self.onCatalogChange?(event)
                    case .snapshot(let snapshot, _): await self.installPrepared(snapshot, event: event)
                    case .mutation(_, let snapshot, let authority):
                        // The serial stream loop awaits preparation before the
                        // next event: no latest-state pull, coalescing or reordering.
                        if self.snapshotAuthority != authority || (snapshot["revision"]?.intValue ?? -1) > self.catalog.revision {
                            await self.installPrepared(snapshot, event: event)
                        }
                    case .failure(let error):
                        if error.code == "READING_CACHE_UNAVAILABLE" {
                            // A device storage warning does not retire a healthy
                            // host connection, disable live actions or end media.
                            self.operationError = error.message
                            continue
                        }
                        // This local observer will immediately reattach. It is
                        // not a transport outage and must not retire voice.
                        if error.code != "CONSUMER_OVERFLOW" {
                            self.connectionError = error.message
                            self.refreshAvailability()
                        }
                    case .overviewFilter(let request): self.onOverviewFilter?(request)
                    case .threadContent: self.harnessHost.receive(event)
                    }
                    self.voice.receive(event)
                    self.refreshSettingsPrefetch()
                }
                guard let self, !self.stopping, !Task.isCancelled else { return }
                // A bounded observer closes on overflow. Reattaching installs an
                // authoritative current snapshot instead of leaving the UI stale.
            }
        }
        beginConnection(retry: false)
    }

    func installPrepared(_ snapshot: JSONValue, event: RuntimeClientEvent) async {
        do {
            let prepared = try await catalogPreparation.prepare(snapshot)
            // Shutdown may fail and leave this window alive. Keep installing
            // ordered catalog events until the observer is actually cancelled.
            guard !Task.isCancelled else { return }
            let authority: UUID
            switch event {
            case .snapshot(_, let value), .mutation(_, _, let value): authority = value
            default: throw PluginContractError("Catalog event has no authority")
            }
            if snapshotAuthority != authority { catalog.invalidateApplicationEntries() }
            catalog.install(prepared)
            if snapshotAuthority != authority {
                snapshotAuthority = authority
                recoveryRevision += 1
            }
            state = snapshot
            timer.receive(catalog.moku)
            if hasInitialContent { startupPerformance?.dataReady() }
            catalogError = nil
            if connection == .connected { connectionError = nil }
            settingsModel.receive(snapshot: snapshot, runtimeAvailable: runtimeAvailable)
            settingsModel.activeHostHarnessID = catalog.moku?.harnessID.string
            settingsModel.mokuRunning = catalog.executions.contains { $0["threadId"] == catalog.moku.map { .string($0.id) } }
            voice.configureMoku(owner: catalog.moku?.id, available: connection == .connected && !stopping)
            harnessHost.receive(event)
            onCatalogChange?(event)
        } catch {
            catalogError = error.localizedDescription
            connectionError = error.localizedDescription
            refreshAvailability()
        }
    }

    private func refreshAvailability() {
        settingsModel.receive(snapshot: state, runtimeAvailable: runtimeAvailable)
        refreshSettingsPrefetch()
        onConnectionChange?(connection)
    }

    private func refreshSettingsPrefetch() {
        settingsPrefetch.update(workspace: self)
        if runtimeAvailable {
            settingsModel.startDiscovery(harnessIDs: plugins.harnesses.modules.map { $0.descriptor.id.string })
        } else { settingsModel.stopDiscovery() }
    }

    public func report(_ error: Error) { operationError = error.localizedDescription }
    public func dismissOperationError() { operationError = nil }
    public func resetSettingsForReload() {
        settingsPrefetch.stop()
        settingsModel.discardForReload()
        settingsModel = makeSettingsModel()
        refreshSettingsPrefetch()
        operationError = nil
    }

    public func canExecute(_ thread: HarnessThread) -> Bool {
        executionAvailable(thread) && thread.archived != true
    }

    public func executionAvailable(_ thread: HarnessThread) -> Bool {
        let key = JSONText(codeUnits: JSONText("harness:").codeUnits + thread.harnessID.codeUnits)
        let plugin = catalog.plugins.first { $0["key"] == .string(key) }
        return runtimeAvailable
            && plugin?["enabled"] != .bool(false)
            && (plugin?["unavailableReason"]?.stringValue?.isEmpty ?? true)
    }

    public func prepareCommand() async throws {
        guard !stopping else { throw CancellationError() }
        while true {
            let locale = preferences.locale
            try await publishOutputLocale(locale).value
            guard !stopping else { throw CancellationError() }
            if preferences.locale == locale { return }
        }
    }

    public func invoke(_ channel: String, args: [JSONValue] = []) async throws -> JSONValue {
        try await prepareCommand()
        return try await client.invoke(channel, args: args)
    }

    public func retry() async {
        guard !stopping else { return }
        connectionError = catalogError
        await beginConnection(retry: true).value
    }

    @discardableResult
    private func beginConnection(retry: Bool) -> Task<Void, Never> {
        if connectionRequestID != nil, let startupTask { return startupTask }
        let id = UUID()
        connectionRequestID = id
        reconnecting = retry
        let task = Task { [weak self, client] in
            guard let self else { return }
            defer {
                if self.connectionRequestID == id {
                    self.connectionRequestID = nil
                    self.reconnecting = false
                }
            }
            do {
                // Work may begin during service startup, so it must see the
                // current language before any launch/reconnect is permitted.
                while true {
                    guard !self.stopping else { return }
                    let locale = self.preferences.locale
                    try await self.publishOutputLocale(locale).value
                    if self.preferences.locale == locale { break }
                }
                guard !self.stopping else { return }
                if retry { try await client.retryConnection() }
                else { try await client.start() }
            } catch is CancellationError {
                // The application owns the explicit shutdown path.
            } catch {
                self.connectionError = error.localizedDescription
                self.refreshAvailability()
            }
        }
        startupTask = task
        return task
    }

    public func setAppearance(_ appearance: DesktopAppearance) {
        do { try preferences.setAppearance(appearance); operationError = nil }
        catch { operationError = error.localizedDescription }
    }

    public func setLocale(_ locale: DesktopLocale) {
        guard !stopping else { return }
        do { try updateLocale(locale); operationError = nil }
        catch { operationError = error.localizedDescription; return }
    }

    public func updateLocale(_ locale: DesktopLocale) throws {
        guard !stopping else { throw CancellationError() }
        try preferences.setLocale(locale)
        publishOutputLocale(locale)
    }

    @discardableResult
    private func publishOutputLocale(_ locale: DesktopLocale) -> Task<Void, Error> {
        let previous = localeTask
        let task = Task<Void, Error> { [weak self, client] in
            _ = try? await previous?.value
            guard let self, self.preferences.locale == locale else { return }
            do { try await client.setOutputLocale(locale.rawValue) }
            catch {
                if self.preferences.locale == locale { self.operationError = error.localizedDescription }
                throw error
            }
        }
        localeTask = task
        return task
    }

    /// Cleanup failures are reported after releasing the local workspace. They
    /// must never restore a half-stopped application or veto the user's exit.
    public func stop() async throws {
        guard !stopping else { return }
        stopping = true
        timer.stop()
        // Pause pending settings timers before awaiting voice/service teardown.
        refreshAvailability()
        // Revoke local media immediately, but do not let an unacknowledged
        // remote voice stop delay the service's own shutdown request.
        let mediaStop = Task { await voice.stopAll() }
        var failure: Error?
        do {
            // Join the entire wrapper, including locale publication before it
            // enters RuntimeClient.start, so close cannot race a late launch.
            await startupTask?.value
            _ = try? await localeTask?.value
            try await client.stopService()
        } catch { failure = error }
        await mediaStop.value
        await onStopped?()
        await client.close()
        await harnessHost.releaseAll()
        startupTask?.cancel()
        eventTask?.cancel()
        startupTask = nil
        eventTask = nil
        if let failure { throw failure }
    }
}
