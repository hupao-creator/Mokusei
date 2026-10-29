import Foundation
import AppKit
import SwiftUI
import Testing
import MokuseiCore
import MokuseiPluginAPI
import MokuseiUI

struct SettingsPrefetchConnectionSource: RuntimeConnectionSource {
    let profile: RuntimeProfile
    let port: Int
    private var manager: RuntimeProcessManager { RuntimeProcessManager(profile: profile) }
    func start() async throws -> RuntimeConnection { redirect(try await manager.start()) }
    func status() async throws -> RuntimeConnection? { try await manager.status().map(redirect) }
    func stop(expectedEpoch: String?) async throws { try await manager.stop(expectedEpoch: expectedEpoch) }
    func setOutputLocale(_ locale: String) throws { try manager.setOutputLocale(locale) }
    private func redirect(_ value: RuntimeConnection) -> RuntimeConnection {
        RuntimeConnection(port: port, token: value.token, epoch: value.epoch,
            protocolVersion: value.protocolVersion, pid: value.pid, dataDir: value.dataDir)
    }
}

/// An HTTP fault/counting proxy wraps the real daemon. The workspace, typed
/// Codex resource, source fences and reconnect handling are production code.
@MainActor
enum NativeSettingsPrefetchReplay {
    static func verify(workspace: NativeWorkspaceModel, endpoint: URL) async throws {
        let host = workspace.harnessHost
        let control = endpoint.appendingPathComponent("_prefetch")
        func counts() async throws -> JSONValue { try await request(control) }
        func configure(_ value: JSONValue) async throws { _ = try await request(control, value) }
        func defaults() -> NativeHarnessSettingsConfiguration {
            .init(harnessID: "codex", cwd: JSONText(workspace.settingsModel.defaultCwd),
                  source: workspace.settingsModel.savedSettings["harnesses"]?["codex"] ?? .null)
        }
        func execution(_ application: JSONText? = nil) -> NativeHarnessSettingsConfiguration {
            let cwd = JSONText(workspace.settingsModel.defaultCwd)
            let source = workspace.settingsModel.savedSettings["moku"]?["executionHarnesses"]?["codex"] ?? .null
            if let application { return .background(harnessID: "codex", cwd: cwd, settingID: application, inherited: true, source: source) }
            return .init(harnessID: "codex", cwd: cwd, source: source, scope: .global(executionOwner: .moku))
        }

        // No Settings page, presentation or editor has been constructed yet.
        try await eventually("all settings scopes acquire before page mount, including retry") {
            let value = try await counts()
            return value["codex:global"]?.intValue == 2 && value["codex:moku"]?.intValue == 2
                && value["codex:report.settings"]?.intValue == 1 && value["codex:tag.settings"]?.intValue == 1
                && workspace.settingsModel.installationState("codex") == .installed
        }
        let configurations = [defaults(), execution(), execution("report.settings"), execution("tag.settings")]
        let surfaces = try configurations.map { try host.makeSettingsSurface(configuration: $0) }
        try await eventually("all prefetched resources become ready") {
            surfaces.allSatisfy { $0.isReady && $0.executionSnapshotError == nil }
        }
        #expect(Set(surfaces.map(\.id)).count == 4)
        #expect(surfaces.allSatisfy { $0.executionSnapshotError == nil })
        let before = try await counts()
        async let first: Void = host.prefetchSettings(configurations: configurations)
        async let second: Void = host.prefetchSettings(configurations: configurations)
        _ = await (first, second)
        for (configuration, surface) in zip(configurations, surfaces) {
            #expect(try host.makeSettingsSurface(configuration: configuration) === surface)
            try await surface.loadIfNeeded()
        }
        #expect(try await counts() == before)

        // A real pending HTTP read is joined by both consumers.
        try await configure(.object(["failures": .integer(0)]))
        async let readA: Void = surfaces[0].reload()
        async let readB: Void = surfaces[0].reload()
        _ = try await (readA, readB)
        #expect(try await counts()["codex:global"] == .integer(1))

        // Replacing a saved source fences the old in-flight completion while
        // preserving the owning editor. The fresh read must become ready.
        try await configure(.object(["failures": .integer(0)]))
        let obsolete = Task { try await surfaces[0].reload() }
        try await eventually("old source read reaches HTTP") { try await counts()["codex:global"] == .integer(1) }
        let changed = NativeHarnessSettingsConfiguration(harnessID: "codex", cwd: defaults().cwd,
            source: .object(["fixtureSource": .integer(1)]))
        let updated = try host.makeSettingsSurface(configuration: changed)
        #expect(updated === surfaces[0])
        try await updated.loadIfNeeded()
        _ = try? await obsolete.value
        #expect(updated.isReady && updated.configuration == changed)
        #expect(try await counts()["codex:global"] == .integer(2))

        // Persistent failure has a finite background budget; a later editor
        // retries the same failed resource successfully.
        try await configure(.object(["failures": .integer(100)]))
        host.releaseGlobalSettings()
        await host.prefetchSettings(configurations: [defaults()])
        #expect(try await counts()["codex:global"] == .integer(3))
        let failed = try host.makeSettingsSurface(configuration: defaults())
        #expect(!failed.isReady)
        let navigation = NativeSettingsNavigation(section: "general")
        let failureWindow = SwiftUIReplay.window(NativeHarnessSettingsView(host: host, configuration: defaults(),
            section: .cli, settingsFormPage: true, readOnly: true, value: .constant(defaults().source))
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.nativeSettingsInteractions, navigation.interactions)
            .environment(\.nativeSettingsInteractionContext, navigation.interactionContext(section: "general"))
            .environment(\.nativeSettingsInteractionRefresh, navigation.interactions.refresh), width: 700, height: 500)
        defer { failureWindow.orderOut(nil); failureWindow.contentView = nil }
        func failureControls() -> [JSONValue] {
            navigation.interactions.snapshot(context: navigation.interactionContext(section: "general"))
        }
        try await SwiftUIReplay.wait(timeout: .seconds(10)) {
            failureControls().contains { $0["severity"] == .text("error") && $0["value"]?.stringValue?.contains("Unable to load settings") == true }
        }
        #expect(!failureControls().contains { $0["value"] == .text("Loading Agent configuration…") })
        try await configure(.object(["failures": .integer(0)]))
        let retry = try #require(failureControls().first { $0["id"] == .text("general.retryLoad") })
        #expect(retry["enabled"] == .bool(true))
        try navigation.interactions.perform(id: "general.retryLoad", handle: try #require(retry["handle"]?.stringValue),
            operation: "activate", value: .null, context: navigation.interactionContext(section: "general"))
        try await eventually("mounted editor retries failed acquisition") { failed.isReady }
        #expect(try await counts()["codex:global"] == .integer(1))
        failureWindow.orderOut(nil); failureWindow.contentView = nil

        // Teardown occurs before queued children can start; they cannot create
        // a resource after the owner's generation has been revoked.
        try await configure(.object(["failures": .integer(0)]))
        let queued = Task { await host.prefetchSettings(configurations: configurations) }
        await host.releaseAll()
        await queued.value
        #expect(try await counts() == .object([:]))
        #expect(throws: CancellationError.self) { try host.makeSettingsSurface(configuration: defaults()) }
        workspace.resetSettingsForReload()
        try await eventually("full reload reacquires all scopes") {
            try await counts()["codex:tag.settings"] == .integer(1)
        }
        try await eventually("new settings model completes installation discovery") {
            workspace.settingsModel.installationState("codex") == .installed && !workspace.settingsModel.probing
        }

        // Mount the production editor across installation invalidation and
        // stream recovery. Its SwiftUI tasks share the same cached resources.
        let editor = NSHostingView(rootView: NativeHarnessSettingsView(host: host, configuration: defaults(),
            section: .cli, value: .constant(defaults().source)).frame(width: 700, height: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))

        // Installation discovery is workspace-owned. Replacing a path revokes
        // every scope for that Harness, even with Settings closed.
        let old = try configurations.map { try host.makeSettingsSurface(configuration: $0) }
        try await configure(.object(["installationChanged": .bool(true)]))
        await workspace.settingsModel.refreshInstallations()
        #expect(old.allSatisfy { $0.isReleased })
        try await eventually("installation change reloads every scope") {
            let value = try await counts()
            return ["global", "moku", "report.settings", "tag.settings"].allSatisfy { value["codex:" + $0] == .integer(1) }
        }

        // Break the real client's stream, then recover through its production
        // connection source. Offline editors cannot reacquire retired handles.
        let connected = try host.makeSettingsSurface(configuration: defaults())
        try await configure(.object(["offline": .bool(true)]))
        try await eventually("workspace observes stream disconnect") { !workspace.runtimeAvailable }
        #expect(connected.isReleased)
        #expect(!host.settingsLifetime.available)
        #expect(throws: CancellationError.self) { try host.makeSettingsSurface(configuration: defaults()) }
        try await configure(.object(["offline": .bool(false)]))
        try await eventually("reconnect restarts prefetch without a page visit") {
            let value = try await counts()
            return workspace.runtimeAvailable && (value["codex:global"]?.intValue ?? 0) > 0
        }
        let reconnected = try host.makeSettingsSurface(configuration: defaults())
        #expect(reconnected !== connected)
        try await reconnected.loadIfNeeded()
        #expect(reconnected.isReady)
        // Acquisition is bounded per Harness. The default editor may become
        // ready before the workspace's other scopes finish after reconnect.
        let reconnectedScopes = try [defaults(), execution(), execution("report.settings"), execution("tag.settings")]
            .map { try host.makeSettingsSurface(configuration: $0) }
        try await eventually("reconnected scopes finish acquisition before checking unmount reuse") {
            reconnectedScopes.allSatisfy { $0.isReady && $0.executionSnapshotError == nil }
        }
        let mountedCounts = try await counts()
        window.contentView = nil
        try await Task.sleep(for: .milliseconds(200))
        #expect(try host.makeSettingsSurface(configuration: defaults()) === reconnected)
        #expect(try await counts() == mountedCounts)
        #expect(workspace.operationError == nil)
        print("PASS: settings prefetch before mount, scope cache, HTTP dedup, bounded retry, teardown, installation invalidation and real reconnect")
    }

    private static func request(_ url: URL, _ value: JSONValue? = nil) async throws -> JSONValue {
        var request = URLRequest(url: url)
        if let value { request.httpMethod = "POST"; request.httpBody = try value.encodedData() }
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return try JSONValue(data: data)
    }
    private static func eventually(_ description: String, _ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !(try await predicate()) {
            guard ContinuousClock.now < deadline else { throw ReplayFailure(description: description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private struct ReplayFailure: Error { let description: String }
}
