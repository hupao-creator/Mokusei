import AppKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiUI
import MokuseiHarnessCodex

@MainActor @Suite(.serializedNative)
struct NativeSettingsDiscoveryTests {
    @Test func independentInstallationRepliesAndRetirement() async throws {
        let saved: JSONValue = .object(["moku": .object([
            "hostHarnessPreference": .text("codex"), "targetHarnessIds": .array([]),
            "executionHarnesses": .object([:]), "routingGuidance": .null
        ]), "harnesses": .object([:]), "pluginSettings": .array([])])
        var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
        var manualReads = 0
        let model = NativeSettingsModel(settings: saved, revision: 1,
            save: { value, revision in .saved(settings: value, revision: revision + 1) }, clearHistory: {},
            loadInstallations: { manualReads += 1; return .object([:]) }, installHarness: { _ in },
            loadInstallation: { id in try await withCheckedThrowingContinuation { pending[id] = $0 } })
        model.receive(snapshot: nil, runtimeAvailable: true)
        model.startDiscovery(harnessIDs: ["codex", "opencode"])
        defer {
            model.discardForReload()
            for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        }
        try await SwiftUIReplay.wait { pending.count == 2 }
        pending.removeValue(forKey: "codex")?.resume(returning: .object(["status": .text("installed"), "executablePath": .text("fixture")]))
        try await SwiftUIReplay.wait { model.installationState("codex") == .installed }
        #expect(model.installationLoadState == .loaded && model.probing)
        #expect(model.installationState("opencode") == .checking)
        #expect(manualReads == 0 && model.savedSettings == saved)
        #expect(model.detailRefreshSequences["codex"] == nil)
        model.stopDiscovery()
        pending.removeValue(forKey: "opencode")?.resume(returning: .object(["status": .text("installed")]))
        await Task.yield()
        #expect(model.installations["opencode"]?.status == .checking)
        #expect(model.installationState("codex") == .installed && !model.probing)
        await model.refreshInstallations()
        #expect(manualReads == 1 && model.savedSettings == saved)
    }
}

/// Hold the installation boundary while mounting the production Settings page.
/// Notices and retry actions come from the same controls used by the app.
@MainActor enum NativeSettingsLoadingReplay {
    static func verify(directory: URL) async throws {
        let settings: JSONValue = .object(["moku": .object([
            "hostHarnessPreference": .text("codex"), "targetHarnessIds": .array([.text("codex")]),
            "executionHarnesses": .object([:]), "routingGuidance": .null
        ]), "harnesses": .object([:]), "pluginSettings": .array([])])
        var response: CheckedContinuation<JSONValue, Error>?
        var reads = 0
        let model = NativeSettingsModel(settings: settings, revision: 1,
            save: { value, revision in .saved(settings: value, revision: revision + 1) }, clearHistory: {},
            loadInstallations: {
                reads += 1
                return try await withCheckedThrowingContinuation { response = $0 }
            }, installHarness: { _ in })
        model.receive(snapshot: nil, runtimeAvailable: true)
        model.mokuInFlight = true
        let preferences = DesktopPreferences(directory: directory)
        try preferences.setLocale(.english)
        let navigation = NativeSettingsNavigation(section: "moku")
        let window = SwiftUIReplay.window(NativeSettingsPage(model: model, navigation: navigation,
            preferences: preferences, harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())],
            harnessSettings: { _ in AnyView(NativeSettingsNotice(message: "Ready execution editor")) },
            onSetAppearance: { _ in }, onSetLocale: { _ in }, onClose: { _ in }), width: 800, height: 720)
        defer {
            model.discardForReload()
            response?.resume(throwing: CancellationError()); response = nil
            window.orderOut(nil); window.contentView = nil
        }
        func controls() -> [JSONValue] { navigation.interactions.snapshot(context: navigation.interactionContext(section: "moku")) }
        func notices() -> [String] { controls().filter { $0["kind"] == .text("notice") }.compactMap { $0["value"]?.stringValue } }
        func hasError() -> Bool { controls().contains { $0["severity"] == .text("error") } }
        func capture(_ name: String) throws {
            guard let path = ProcessInfo.processInfo.environment["MOKUSEI_SETTINGS_LOADING_ARTIFACTS"],
                  let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let target = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: target.appendingPathComponent(name + ".png"))
        }
        func retry() async throws {
            try await SwiftUIReplay.wait { controls().contains { $0["id"] == .text("moku.retryDiscovery") && $0["pending"] == .bool(false) } }
            let action = try #require(controls().first { $0["id"] == .text("moku.retryDiscovery") })
            try navigation.interactions.perform(id: "moku.retryDiscovery", handle: try #require(action["handle"]?.stringValue),
                operation: "activate", value: .null, context: navigation.interactionContext(section: "moku"))
            try await SwiftUIReplay.wait { response != nil }
        }
        func complete(_ value: JSONValue) async throws {
            response?.resume(returning: value); response = nil
            try await SwiftUIReplay.wait { !model.probing }
        }

        try await SwiftUIReplay.wait { notices().contains("Loading Agent configuration…") }
        try capture("loading")
        #expect(model.installationLoadState == .notLoaded && !hasError())
        let initialRead = Task { await model.refreshInstallations() }
        try await SwiftUIReplay.wait { response != nil }
        #expect(model.installationLoadState == .loading && !hasError())
        let joinedRead = Task { await model.refreshInstallations() }
        await Task.yield()
        #expect(reads == 1)
        response?.resume(throwing: RuntimeError("FIXTURE", "Discovery fixture failed")); response = nil
        await initialRead.value; await joinedRead.value
        try await SwiftUIReplay.wait { notices().contains("Discovery fixture failed") }
        try capture("failure")
        #expect(hasError() && !notices().contains { $0.contains("selected Moku provider") })

        try await retry()
        try await SwiftUIReplay.wait { notices().contains("Loading Agent configuration…") && !hasError() }
        try await complete(.object([:]))
        try await SwiftUIReplay.wait { notices().contains { $0.contains("No Agents are available") } }
        try capture("empty")
        #expect(model.installationLoadState == .loaded && !hasError())
        #expect(model.installationState("codex") == .missing)

        try await retry()
        try await complete(.object(["codex": .object(["status": .text("installed")])]))
        try await SwiftUIReplay.wait { notices().contains("Ready execution editor") }
        try capture("ready")
        #expect(!hasError())
        model.mokuInFlight = false
        // A periodic refresh must not replace a usable roster with loading.
        let refresh = Task { await model.refreshInstallations() }
        try await SwiftUIReplay.wait { response != nil }
        #expect(model.installationLoadState == .loaded && notices().contains("Ready execution editor"))
        try await complete(.object(["codex": .object(["status": .text("installed")])]))
        await refresh.value
        let detectionFailure = Task { await model.refreshInstallations() }
        try await SwiftUIReplay.wait { response != nil }
        try await complete(.object(["codex": .object(["status": .text("error"), "message": .text("CLI detection failed")])]))
        await detectionFailure.value
        try await SwiftUIReplay.wait { notices().contains("codex: CLI detection failed") || notices().contains("Codex: CLI detection failed") }
        #expect(hasError() && !notices().contains { $0.contains("selected Moku provider") })
        try await retry()
        try await complete(.object(["codex": .object(["status": .text("installed")])]))
        try await SwiftUIReplay.wait { notices().contains("Ready execution editor") }
        model.draft.receive(settings: replace(settings, host: "unavailable"), revision: 2)
        try await SwiftUIReplay.wait { notices().contains("The selected Moku provider is unavailable. Please choose another.") }
        #expect(hasError())

        // Retiring discovery fences a completion that ignored cancellation.
        let obsolete = Task { await model.refreshInstallations() }
        try await SwiftUIReplay.wait { response != nil }
        model.stopDiscovery()
        response?.resume(returning: .object([:])); response = nil
        await obsolete.value
        #expect(model.installations["codex"]?.status == .installed && !model.probing)
        print("PASS: mounted Moku settings idle/loading/failure/retry/empty/ready/invalid states, coalescing and stale discovery fence")
    }

    private static func replace(_ settings: JSONValue, host: String) -> JSONValue {
        var root = settings.objectValue ?? [:]
        var moku = root["moku"]?.objectValue ?? [:]
        moku["hostHarnessPreference"] = .text(host); root["moku"] = .object(moku)
        return .object(root)
    }
}
