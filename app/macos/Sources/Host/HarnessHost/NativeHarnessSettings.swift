import AppKit
import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

private var nativeSettingsDidBecomeActiveNotification: Notification.Name {
    NSApplication.didBecomeActiveNotification
}

public enum NativeHarnessExecutionOwner: String, Hashable, Sendable { case moku }

/// Observable separately from the host, so connection lifecycle changes can
/// reattach editors without making streamed thread resources observable.
@MainActor @Observable
public final class NativeHarnessSettingsLifetime {
    public internal(set) var generation = UUID()
    public internal(set) var available = false
}
public enum NativeHarnessSettingsScope: Hashable, Sendable {
    case global(applicationSettings: JSONText? = nil, executionOwner: NativeHarnessExecutionOwner? = nil)
    case thread(JSONText)
}

/// Only the saved settings slice and workspace identity participate in the
/// request key. Draft edits and unrelated streamed revisions do not reload it.
public struct NativeHarnessSettingsConfiguration: Hashable, Sendable {
    public let harnessID: JSONText
    public let cwd: JSONText
    public let source: JSONValue
    public let scope: NativeHarnessSettingsScope
    public init(harnessID: JSONText, cwd: JSONText, source: JSONValue,
                scope: NativeHarnessSettingsScope = .global()) {
        self.harnessID = harnessID; self.cwd = cwd; self.source = source; self.scope = scope
    }
    public static func thread(_ thread: HarnessThread) -> Self {
        .init(harnessID: thread.harnessID, cwd: thread.cwd,
              source: .object(["worktree": thread.worktree ?? .null, "settings": thread.settings,
                               "settingsRevision": .integer(thread.settingsRevision)]),
              scope: .thread(thread.id))
    }
    public static func background(harnessID: JSONText, cwd: JSONText, settingID: JSONText,
                                  inherited: Bool, source: JSONValue) -> Self {
        // Inherit/override can select a different runtime workspace even when
        // the concrete Harness profile is identical.
        .init(harnessID: harnessID, cwd: cwd,
              source: .object(["inherited": .bool(inherited), "settings": source]),
              scope: .global(applicationSettings: settingID))
    }
    /// Saved settings can change on another device while this editor has a draft.
    /// Only changing its workspace or owner replaces the editor's state.
    var editorIdentity: Self {
        .init(harnessID: harnessID, cwd: cwd, source: .null, scope: scope)
    }
    func request(refresh: Bool) -> JSONValue {
        var object: [JSONText: JSONValue]
        switch scope {
        case .thread(let id): object = ["scope": .text("thread"), "threadId": .string(id)]
        case let .global(applicationSettings, executionOwner):
            object = ["scope": .text("global"), "harnessId": .string(harnessID)]
            object["applicationSettings"] = applicationSettings.map(JSONValue.string)
            object["executionOwner"] = executionOwner.map { .text($0.rawValue) }
        }
        if refresh { object["refresh"] = .bool(true) }
        return .object(object)
    }
}

@MainActor @Observable
public final class NativeHarnessSettingsSurface {
    public let id = UUID()
    public private(set) var configuration: NativeHarnessSettingsConfiguration
    public private(set) var isReleased = false
    public private(set) var executionSnapshotError: JSONText?
    public private(set) var isSavingThreadSettings = false
    public private(set) var threadSettingsFailure: String?
    public private(set) var threadSettingsEditorID = UUID()
    private var baselineThreadSettings: ThreadSettingsSnapshot?
    private var latestThreadSettings: ThreadSettingsSnapshot?
    private var pendingThreadChange: JSONValue?
    @ObservationIgnored private let host: NativeHarnessHost
    @ObservationIgnored private var session: HarnessSettingsSession!
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var needsReload = true
    @ObservationIgnored private let diagnostics: SettingsDiagnostics

    public var isReady: Bool { !isReleased && session.isReady }
    public var hasThreadSettingsConflict: Bool {
        guard let baselineThreadSettings, let latestThreadSettings else { return false }
        return baselineThreadSettings.revision != latestThreadSettings.revision
    }
    public var canRetryThreadSettings: Bool { pendingThreadChange != nil }

    init(host: NativeHarnessHost, plugin: AnyHarnessPlugin, configuration: NativeHarnessSettingsConfiguration) {
        self.host = host; self.configuration = configuration
        let initialThreadSettings = ThreadSettingsSnapshot(configuration)
        baselineThreadSettings = initialThreadSettings
        latestThreadSettings = initialThreadSettings
        diagnostics = SettingsDiagnostics(client: host.client)
        session = plugin.makeSettingsSession(load: { [weak self] refresh in
            guard let self else { throw CancellationError() }; return try await load(refresh: refresh)
        }, onError: { [weak host] error in host?.callbacks.onError(error) })
    }

    public func reload(refresh: Bool = false) async throws {
        try checkAuthority()
        let source = configuration
        try await session.reload(refresh)
        if !isReleased, configuration == source { needsReload = executionSnapshotError != nil }
    }

    public func loadIfNeeded() async throws {
        try checkAuthority()
        if needsReload || !session.isReady { try await reload() }
    }

    /// Global resources outlive tab/host selection; thread resources still
    /// belong exclusively to their mounted editor. Full teardown revokes both.
    func unmount() {
        if case .thread = configuration.scope { release() }
    }

    func updateSource(_ next: NativeHarnessSettingsConfiguration) throws {
        try checkAuthority()
        guard next.editorIdentity == configuration.editorIdentity else { throw CancellationError() }
        guard next != configuration else { return }
        if let snapshot = ThreadSettingsSnapshot(next) { observeThreadSettings(snapshot) }
        configuration = next; sequence += 1; needsReload = true
        session.sourceChanged()
    }

    public func release() {
        guard !isReleased else { return }
        isReleased = true; sequence += 1; executionSnapshotError = nil; pendingThreadChange = nil
        session.invalidate(); host.unregisterSettingsSurface(id)
    }

    func reconcileAuthority() {
        guard case .thread(let threadID) = configuration.scope else { return }
        do {
            try checkAuthority()
            let current = try host.authoritativeThread(threadID: threadID, harnessID: configuration.harnessID)
            try updateSource(.thread(current))
        } catch { release() }
    }

    func checkAuthority() throws {
        guard !isReleased else { throw CancellationError() }
        if case .thread(let threadID) = configuration.scope {
            let current = try host.authoritativeThread(threadID: threadID, harnessID: configuration.harnessID)
            guard NativeHarnessSettingsConfiguration.thread(current).editorIdentity == configuration.editorIdentity,
                  baselineThreadSettings != nil else {
                throw PluginContractError("Thread settings belong to another workspace")
            }
        }
    }

    private func load(refresh: Bool) async throws -> JSONValue {
        let started = Date()
        diagnostics.record(.presentation, .started)
        do {
            let result = try await SettingsDiagnosticContext.$flowID.withValue(diagnostics.flowID) {
                try await loadPresentation(refresh: refresh)
            }
            diagnostics.record(.presentation, executionSnapshotError == nil ? .completed : .failed,
                               durationMs: Date().timeIntervalSince(started) * 1000)
            return result
        } catch {
            diagnostics.record(.presentation, .failed, durationMs: Date().timeIntervalSince(started) * 1000)
            throw error
        }
    }

    private func loadPresentation(refresh: Bool) async throws -> JSONValue {
        try checkAuthority()
        sequence += 1
        let requestSequence = sequence
        let result = try await host.client.invoke("harness:settings-presentation", args: [configuration.request(refresh: refresh)])
        try checkAuthority()
        guard requestSequence == sequence else { throw CancellationError() }
        let expectedScope: JSONValue
        switch configuration.scope {
        case .global: expectedScope = .text("global")
        case .thread(let threadID):
            expectedScope = .text("thread")
            guard result["threadId"] == .string(threadID) else { throw PluginContractError("Settings presentation returned another thread") }
        }
        guard result["scope"] == expectedScope, result["harnessId"] == .string(configuration.harnessID),
              let value = result["value"] else { throw PluginContractError("Settings presentation returned a mismatched scope or Harness") }
        if let error = result["executionSnapshotError"] {
            guard case .string(let text) = error else { throw PluginContractError("Invalid execution settings snapshot error") }
            executionSnapshotError = text
        } else { executionSnapshotError = nil }
        return value
    }

    public func threadSettings(input: HarnessThreadInput) throws -> AnyView {
        try checkAuthority()
        guard case .thread(let id) = configuration.scope, id == input.thread.id else {
            throw PluginContractError("Settings surface belongs to another thread")
        }
        guard let baselineThreadSettings, case .object(var values) = input.thread.json else {
            throw PluginContractError("Thread settings have no saved version")
        }
        // Keep the plugin's baseline stable while delivering the live execution
        // observation, so remote saves neither erase its draft nor enable edits
        // during an execution. The host owns the shared conflict interaction.
        values["settings"] = baselineThreadSettings.settings
        values["settingsRevision"] = .integer(baselineThreadSettings.revision)
        let editorInput = HarnessThreadInput(thread: try HarnessThread(json: .object(values)),
                                            readingTarget: input.readingTarget, git: input.git)
        return try session.threadSettings(input: editorInput) { [weak self] change in
            guard let self else { throw CancellationError() }
            try await saveThreadSettings(change, expectedRevision: baselineThreadSettings.revision)
        }
    }

    /// This is the explicit second submission after a rejected compare-and-swap.
    /// It resubmits only the captured delta; the editor baseline stays frozen until
    /// the host accepts it, and another intervening save can conflict again.
    public func retryThreadSettings() async throws {
        try checkAuthority()
        guard let pendingThreadChange, let latestThreadSettings else { return }
        try await saveThreadSettings(pendingThreadChange, expectedRevision: latestThreadSettings.revision)
    }

    public func continueEditingThreadSettings() {
        guard !isSavingThreadSettings else { return }
        pendingThreadChange = nil; threadSettingsFailure = nil
    }

    public func reloadThreadSettings() throws {
        try checkAuthority()
        guard !isSavingThreadSettings, let latestThreadSettings else { return }
        baselineThreadSettings = latestThreadSettings; pendingThreadChange = nil
        threadSettingsFailure = nil; threadSettingsEditorID = UUID()
    }

    func saveThreadSettings(_ change: JSONValue, expectedRevision: Int) async throws {
        try checkAuthority()
        guard !isSavingThreadSettings, case .thread(let id) = configuration.scope else { throw CancellationError() }
        isSavingThreadSettings = true; threadSettingsFailure = nil
        defer { isSavingThreadSettings = false }
        do {
            let result = try await host.updateThreadSettings(threadID: id, harnessID: configuration.harnessID,
                change: change, expectedSettingsRevision: expectedRevision) { [weak self] in
                    guard let self else { throw CancellationError() }; try checkAuthority()
                }
            let snapshot = ThreadSettingsSnapshot(revision: result.settingsRevision, settings: result.settings)
            observeThreadSettings(snapshot)
            guard result.saved else {
                pendingThreadChange = change
                throw PluginContractError("Thread settings changed on another device. Your draft is retained; choose retry or reload above.")
            }
            guard result.settingsRevision >= expectedRevision else {
                throw PluginContractError("Thread settings update returned an older version")
            }
            baselineThreadSettings = snapshot; pendingThreadChange = nil
            threadSettingsEditorID = UUID()
        } catch {
            threadSettingsFailure = error.localizedDescription
            throw error
        }
    }

    private func observeThreadSettings(_ snapshot: ThreadSettingsSnapshot) {
        if snapshot.revision >= (latestThreadSettings?.revision ?? -1) { latestThreadSettings = snapshot }
    }

    public func harnessSettings(section: HarnessSettingsSection, executionSnapshot: Bool = false,
                                settingsFormPage: Bool = false, value: JSONValue,
                                change: @escaping (JSONValue) throws -> Void) throws -> AnyView {
        try checkAuthority()
        let harnessID = configuration.harnessID
        let settingsHost = HarnessSettingsHost(cwd: configuration.cwd,
            invokeExtension: { [weak self] method, payload in
                guard let self else { throw CancellationError() }
                try checkAuthority(); try await host.callbacks.beforeCommand(); try checkAuthority()
                return try await host.client.invoke("harness:extension", args: [.object([
                    "harnessId": .string(harnessID), "method": .string(method), "payload": payload
                ])])
            }, openExternal: { [weak self] url in
                guard let self else { throw CancellationError() }; try checkAuthority()
                try await host.callbacks.openExternal(url)
            })
        return try session.harnessSettings(section: section, executionSnapshot: executionSnapshot,
            settingsFormPage: settingsFormPage, value: value, host: settingsHost, change: { [weak self] value in
                guard let self else { throw CancellationError() }; try checkAuthority(); try change(value)
            })
    }
}

private struct ThreadSettingsSnapshot {
    let revision: Int
    let settings: JSONValue

    init(revision: Int, settings: JSONValue) { self.revision = revision; self.settings = settings }
    init?(_ configuration: NativeHarnessSettingsConfiguration) {
        guard case .thread = configuration.scope, let revision = configuration.source["settingsRevision"]?.intValue,
              revision >= 0, let settings = configuration.source["settings"] else { return nil }
        self.init(revision: revision, settings: settings)
    }
}

@MainActor
public struct NativeHarnessSettingsView: View {
    private let host: NativeHarnessHost
    private let configuration: NativeHarnessSettingsConfiguration
    private let section: HarnessSettingsSection
    private let executionSnapshot: Bool
    private let settingsFormPage: Bool
    private let refreshSequence: Int
    @Binding private var value: JSONValue
    @State private var surface: NativeHarnessSettingsSurface?
    @State private var failure: String?
    @State private var opening = false
    @State private var openID = UUID()
    @Environment(\.locale) private var locale

    private func text(_ chinese: String, _ english: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? chinese : english
    }

    public init(host: NativeHarnessHost, configuration: NativeHarnessSettingsConfiguration,
                section: HarnessSettingsSection, executionSnapshot: Bool = false,
                settingsFormPage: Bool = false, refreshSequence: Int = 0, value: Binding<JSONValue>) {
        self.host = host; self.configuration = configuration; self.section = section
        self.executionSnapshot = executionSnapshot; self.settingsFormPage = settingsFormPage; _value = value
        self.refreshSequence = refreshSequence
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !host.settingsLifetime.available {
                NativeSettingsNotice(message: text("连接后台服务后可读取 Agent 配置。", "Connect to the runtime service to load Agent configuration."))
            } else if let failure, !opening {
                NativeSettingsNotice(message: text("读取设置失败：", "Unable to load settings: ") + failure, kind: .error,
                                     action: AnyView(retry))
            } else if let surface, surface.configuration.editorIdentity == configuration.editorIdentity, !surface.isReleased,
                      surface.isReady || !opening {
                if let error = surface.executionSnapshotError, executionSnapshot {
                    NativeSettingsNotice(message: text("读取运行配置失败：", "Unable to load execution settings: ") + error.string,
                                         kind: .error, action: AnyView(retry))
                }
                if executionSnapshot, surface.executionSnapshotError == nil, surface.isReady, value == .null || value == .object([:]) {
                    NativeHarnessStatusView(message: "运行配置尚未固定。请明确填写以下配置后保存。",
                                            english: "Execution settings are not pinned yet. Fill in the configuration below and save.")
                }
                content(surface)
            } else {
                NativeSettingsNotice(message: text("正在读取 Agent 配置…", "Loading Agent configuration…"),
                                     leading: AnyView(ProgressView().controlSize(.small)))
            }
        }
        .task(id: SettingsLoadIdentity(configuration: configuration, generation: host.settingsLifetime.generation)) {
            if host.settingsLifetime.available { await open() }
        }
        .onChange(of: refreshSequence) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: nativeSettingsDidBecomeActiveNotification)) { _ in refresh(force: false) }
        .onDisappear { openID = UUID(); opening = false; failure = nil; surface?.unmount(); surface = nil }
    }

    @ViewBuilder private func content(_ surface: NativeHarnessSettingsSurface) -> some View {
        switch Result(catching: { try surface.harnessSettings(section: section, executionSnapshot: executionSnapshot,
            settingsFormPage: settingsFormPage, value: value, change: { value = $0 }) }) {
        case .success(let content): content
        case .failure(let error): NativeHarnessStatusView(message: "此 Harness 的设置暂时不可用。", english: "This Harness settings view is unavailable.", detail: error.localizedDescription)
        }
    }
    private var retry: some View {
        Button(text(opening ? "重试中…" : "重试", opening ? "Retrying…" : "Retry")) { refresh() }
            .buttonStyle(.borderless).disabled(opening || !host.settingsLifetime.available)
            .nativeSettingsAction("retryLoad", label: "Retry loading settings") { refresh() }
    }

    private func open(refresh: Bool? = nil) async {
        let requestID = UUID(); openID = requestID; opening = true; failure = nil
        defer { if openID == requestID { opening = false } }
        do {
            try Task.checkCancellation()
            failure = nil
            if let surface, !surface.isReleased, surface.configuration.editorIdentity == configuration.editorIdentity {
                try surface.updateSource(configuration)
                if let refresh { try await surface.reload(refresh: refresh) }
                else { try await surface.loadIfNeeded() }
                return
            }
            surface?.unmount(); surface = nil
            let next = try host.makeSettingsSurface(configuration: configuration)
            surface = next
            try await next.loadIfNeeded()
        } catch is CancellationError { }
        catch { if !Task.isCancelled, openID == requestID { failure = error.localizedDescription } }
    }
    private func refresh(force: Bool = true) {
        guard !opening, host.settingsLifetime.available else { return }
        Task { await open(refresh: force) }
    }
}

private struct SettingsLoadIdentity: Equatable {
    let configuration: NativeHarnessSettingsConfiguration
    let generation: UUID
}
