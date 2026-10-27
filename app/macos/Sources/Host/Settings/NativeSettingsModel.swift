import AppKit
import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

public struct NativeHarnessSettingsRequest {
    public let harnessID: JSONText
    public let section: HarnessSettingsSection
    public let executionSnapshot: Bool
    public let scopeID: JSONText?
    public let refreshSequence: Int
    public let savedValue: JSONValue
    public let value: Binding<JSONValue>
}

/// Application-owned settings remain opaque to the settings shell. Composition
/// supplies native editors, each restricted to its own registered contribution.
@MainActor public struct NativeApplicationSettingsSection: Identifiable {
    public let id: String
    public let owner: String
    public let label: String
    public let englishLabel: String
    public let content: (_ saved: JSONValue, _ draft: Binding<JSONValue>) -> AnyView
    public init(id: String, owner: String, label: String, englishLabel: String? = nil,
                content: @escaping (_ saved: JSONValue, _ draft: Binding<JSONValue>) -> AnyView) {
        self.id = id; self.owner = owner; self.label = label; self.englishLabel = englishLabel ?? label; self.content = content
    }
}

public struct NativeSettingsPlugin: Sendable {
    public let key: String
    public let enabled: Bool
    public let unavailableReason: String?
    public init?(json: JSONValue) {
        guard let key = json["key"]?.stringValue, let enabled = json["enabled"]?.boolValue else { return nil }
        self.key = key; self.enabled = enabled
        unavailableReason = json["unavailableReason"]?.stringValue
    }
}

public struct NativeHarnessInstallation: Equatable, Sendable {
    public enum Status: String, Sendable { case checking, installed, missing, installing, error }
    public let status: Status
    public let executablePath: String?
    public let message: String?
    public init(status: Status, executablePath: String? = nil, message: String? = nil) {
        self.status = status; self.executablePath = executablePath; self.message = message
    }
    init(json: JSONValue) {
        status = Status(rawValue: json["status"]?.stringValue ?? "") ?? .error
        executablePath = json["executablePath"]?.stringValue
        message = json["message"]?.stringValue
    }
}

@MainActor @Observable
public final class NativeSettingsModel {
    public enum InstallationLoadState: Equatable, Sendable {
        case notLoaded, loading, loaded, failed(String)
    }
    public let draft: NativeSettingsDraft
    public private(set) var installationLoadState: InstallationLoadState = .notLoaded
    public private(set) var plugins: [NativeSettingsPlugin] = []
    public private(set) var installations: [String: NativeHarnessInstallation] = [:]
    public private(set) var installationErrors: [String: String] = [:]
    public private(set) var installing: Set<String> = []
    public private(set) var detailRefreshSequences: [String: Int] = [:]
    public private(set) var probing = false
    public private(set) var clearing = false
    public var confirmClear = false
    public var operationError: String?
    public private(set) var defaultCwd = ""
    public var activeHostHarnessID: String?
    public var mokuRunning = false
    public var mokuInFlight = false
    public var runtimeAvailable: Bool { draft.runtimeAvailable }
    public var savedSettings: JSONValue { draft.saved }
    @ObservationIgnored private let clearHistory: () async throws -> Void
    @ObservationIgnored private let loadInstallation: ((String) async throws -> JSONValue)?
    @ObservationIgnored private let loadInstallations: () async throws -> JSONValue
    @ObservationIgnored private let installHarness: (String) async throws -> Void
    @ObservationIgnored private var probeIsForced = false
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryGeneration = UUID()
    @ObservationIgnored private var harnessIDs: [String] = []
    @ObservationIgnored private var focusObserver: NSObjectProtocol?
    @ObservationIgnored private var retired = false
    @ObservationIgnored var onDiscoveryChange: (() -> Void)?

    public init(settings: JSONValue, revision: Int,
                save: @escaping (JSONValue, Int) async throws -> NativeSettingsSaveResult,
                clearHistory: @escaping () async throws -> Void,
                loadInstallations: @escaping () async throws -> JSONValue,
                installHarness: @escaping (String) async throws -> Void,
                loadInstallation: ((String) async throws -> JSONValue)? = nil) {
        draft = NativeSettingsDraft(settings: settings, revision: revision, save: save)
        self.clearHistory = clearHistory; self.loadInstallations = loadInstallations
        self.installHarness = installHarness; self.loadInstallation = loadInstallation
    }

    public func receive(snapshot: JSONValue?, runtimeAvailable: Bool) {
        guard !retired else { return }
        if let snapshot {
            if let settings = snapshot["settings"], let revision = snapshot["settingsRevision"]?.intValue {
                draft.receive(settings: settings, revision: revision)
            }
            plugins = (snapshot["plugins"]?.arrayValue ?? []).compactMap(NativeSettingsPlugin.init)
            defaultCwd = snapshot["defaultCwd"]?.stringValue ?? defaultCwd
        }
        if draft.runtimeAvailable != runtimeAvailable { draft.runtimeAvailable = runtimeAvailable }
    }

    public func startDiscovery(harnessIDs: [String]) {
        guard !retired else { return }
        guard discoveryTask == nil || self.harnessIDs != harnessIDs else { return }
        stopDiscovery(); self.harnessIDs = harnessIDs
        let generation = UUID(); discoveryGeneration = generation
        discoveryTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.discoveryGeneration == generation {
                if self.runtimeAvailable { await self.refreshInstallations(force: false) }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        let activationNotification = NSApplication.didBecomeActiveNotification
        focusObserver = NotificationCenter.default.addObserver(forName: activationNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshInstallations(force: false) }
            }
    }

    public func stopDiscovery() {
        discoveryGeneration = UUID(); discoveryTask?.cancel(); discoveryTask = nil
        probeTask?.cancel(); probeTask = nil; probing = false
        if installationLoadState == .loading { installationLoadState = .notLoaded }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
    }

    /// Call before moving focus away from the old page during a full reload.
    /// Ordinary settings dismissal deliberately keeps the retained draft alive.
    public func discardForReload() {
        guard !retired else { return }
        retired = true
        stopDiscovery()
        draft.discardForReload()
    }

    public func refreshInstallations(force: Bool = true) async {
        guard !retired, runtimeAvailable else { return }
        if let probeTask {
            let wasForced = probeIsForced
            await probeTask.value
            if force && !wasForced && !Task.isCancelled { await refreshInstallations(force: true) }
            return
        }
        probeIsForced = force
        probing = true
        // Periodic discovery keeps a successful roster visible. Initial reads
        // and explicit recovery must not validate against an unfinished roster.
        if installationLoadState != .loaded { installationLoadState = .loading }
        let generation = discoveryGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if !self.retired, self.discoveryGeneration == generation {
                    self.probing = false; self.probeTask = nil
                    self.onDiscoveryChange?()
                }
            }
            if !force, let loadInstallation = self.loadInstallation, !self.harnessIDs.isEmpty {
                for id in self.harnessIDs where self.installations[id] == nil {
                    self.installations[id] = .init(status: .checking)
                }
                let loads = self.harnessIDs.map { id in
                    Task { @MainActor in
                        let installation: NativeHarnessInstallation
                        do { installation = .init(json: try await loadInstallation(id)) }
                        catch is CancellationError { return }
                        catch { installation = .init(status: .error, message: error.localizedDescription) }
                        guard !Task.isCancelled, !self.retired, self.discoveryGeneration == generation else { return }
                        if let previous = self.installations[id], previous.status != .checking, previous.status != installation.status || previous.executablePath != installation.executablePath {
                            self.detailRefreshSequences[id, default: 0] += 1
                        }
                        self.installations[id] = installation
                        self.installationLoadState = .loaded
                        if installation.status == .installed { self.installationErrors.removeValue(forKey: id) }
                        self.onDiscoveryChange?()
                    }
                }
                await withTaskCancellationHandler {
                    for load in loads { await load.value }
                } onCancel: {
                    for load in loads { load.cancel() }
                }
                return
            }
            do {
                let result = try await self.loadInstallations()
                guard !self.retired, self.discoveryGeneration == generation else { return }
                guard let values = result.objectValue else { throw RuntimeError("INVALID_INSTALLATIONS", "Invalid Harness installation response") }
                let next = Dictionary(uniqueKeysWithValues: values.map { ($0.key.string, NativeHarnessInstallation(json: $0.value)) })
                for (id, installation) in next {
                    if let previous = self.installations[id], previous.status != .checking, previous.status != installation.status || previous.executablePath != installation.executablePath {
                        self.detailRefreshSequences[id, default: 0] += 1
                    }
                }
                self.installations = next
                self.installationLoadState = .loaded
                self.installationErrors = self.installationErrors.filter { self.installations[$0.key]?.status != .installed }
            } catch {
                guard !self.retired, self.discoveryGeneration == generation else { return }
                self.installationLoadState = .failed(error.localizedDescription)
                self.installations = Dictionary(uniqueKeysWithValues: self.harnessIDs.map { ($0, .init(status: .error, message: error.localizedDescription)) })
            }
        }
        probeTask = task; await task.value
    }

    public func install(_ id: String) async {
        guard !retired, runtimeAvailable, !installing.contains(id) else { return }
        installing.insert(id); installationErrors.removeValue(forKey: id)
        do {
            try await installHarness(id)
            guard !retired else { return }
            await probeTask?.value
            await refreshInstallations()
            detailRefreshSequences[id, default: 0] += 1
            onDiscoveryChange?()
        } catch { if !retired { installationErrors[id] = error.localizedDescription } }
        installing.remove(id); await refreshInstallations()
    }

    public func installationState(_ id: String) -> NativeHarnessInstallation.Status {
        if installing.contains(id) { return .installing }
        if installationErrors[id] != nil { return .error }
        if let installation = installations[id] { return installation.status }
        switch installationLoadState {
        case .notLoaded, .loading: return .checking
        case .loaded: return .missing
        case .failed: return .error
        }
    }

    public func requestClear() async {
        guard !retired, runtimeAvailable, !clearing, draft.status != .saving, draft.status != .pending else { return }
        guard confirmClear else { confirmClear = true; return }
        clearing = true; operationError = nil
        do { try await clearHistory() } catch { if !retired { operationError = error.localizedDescription } }
        confirmClear = false; clearing = false
    }

    public func harnessValueBinding(_ id: String, execution: Bool) -> Binding<JSONValue> {
        let path = execution ? ["moku", "executionHarnesses", id] : ["harnesses", id]
        return Binding(get: { settingsAt(self.draft.value, path: path) ?? .object([:]) },
                       set: { self.draft.change(settingsReplacing(self.draft.value, path: path, value: $0),
                                                textEdit: !NativeSettingsChangeContext.isDiscreteChange) })
    }

    public func applicationValueBinding(_ id: String) -> Binding<JSONValue> {
        Binding(get: { self.draft.value["pluginSettings"]?.arrayValue?.first { $0["id"]?.stringValue == id }?["value"] ?? .null },
                set: { value in
                    let entries = (self.draft.value["pluginSettings"]?.arrayValue ?? []).map { entry in
                        entry["id"]?.stringValue == id ? settingsReplacing(entry, path: ["value"], value: value) : entry
                    }
                    self.draft.change(settingsReplacing(self.draft.value, path: ["pluginSettings"], value: .array(entries)),
                                      textEdit: !NativeSettingsChangeContext.isDiscreteChange)
                })
    }
}
