import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiHarnessClaude

/// Mounted production controls and their actual bindings; only the native
/// catalog and the parent settings owner are fixtures. No CLI/API calls occur.
@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct ClaudeSettingsControlReplayTests {
    @Test func snapshotChoicesRetainNativeSemantics() async throws {
        let fixture = try ClaudeSettingsFixture(snapshot: true)
        let window = mount(fixture)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle(fixture, window)
        #expect(fixture.controls["claude.model"]?["kind"] == .text("select"))
        #expect(fixture.controls["claude.effort"]?["kind"] == .text("select"))
        #expect(fixture.controls["claude.permissionMode"]?["kind"] == .text("select"))
        #expect(fixture.changes == 0)

        try await select("model", label: "Custom model…", fixture, window)
        #expect(fixture.changes == 0) // Opening the editor never rewrites the saved model.
        try await operate("customModel", "set", .text(" invalid "), fixture, window)
        #expect(fixture.controls["claude.customModel"]?["invalid"] == .bool(true))
        #expect(fixture.changes == 0)
        try await operate("customModel", "set", .text("external-model"), fixture, window)
        #expect(fixture.controls["claude.customModel"]?["value"] == .text("external-model"))
        #expect(fixture.controls["claude.effort"]?["enabled"] == .bool(false))
        #expect(fixture.changes == 0) // Unknown capability cannot complete a snapshot.

        try await select("model", label: "Fixed model", fixture, window)
        #expect(fixture.value.json["threadSettings"]?["model"] == .text("fixed"))
        #expect(fixture.value.json["threadSettings"]?["effort"] == nil)
        #expect(fixture.controls["claude.effort"]?["enabled"] == .bool(false))
        let fixedChanges = fixture.changes
        try await select("model", label: "Effort model", fixture, window)
        #expect(fixture.changes == fixedChanges)
        try await operate("effort", "select", .text("medium"), fixture, window)
        #expect(fixture.value.json["threadSettings"]?["model"] == .text("effort"))
        #expect(fixture.value.json["threadSettings"]?["effort"] == .text("medium"))

        for mode in ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"] {
            try await operate("permissionMode", "select", .text(mode), fixture, window)
            #expect(fixture.value.json["threadSettings"]?["permissionMode"] == .text(mode))
        }
        #expect(fixture.value.json["threadSettings"]?["allowedTools"] == .array([.text("Read")]))
        #expect(fixture.value.json["threadSettings"]?["disallowedTools"] == .array([.text("Bash")]))
        try capture(window, "snapshot")
    }

    @Test func defaultsAndUnavailableModelStayEditable() async throws {
        let fixture = try ClaudeSettingsFixture(snapshot: false)
        fixture.value = try ClaudeHarnessSettings(json: .object([
            "useDefaultThreadSettings": .bool(false),
            "threadSettings": .object(["model": .text("not-in-catalog"), "effort": .text("high")])
        ]))
        let window = mount(fixture, width: 520)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle(fixture, window)
        #expect(fixture.controls["claude.customModel"]?["value"] == .text("not-in-catalog"))
        #expect(fixture.changes == 0)
        try capture(window, "custom-compact")
        try await select("model", label: "Effort model", fixture, window)
        #expect(fixture.value.json["threadSettings"]?["effort"] == .text("high"))
        try await select("model", label: "Decomposed identifier", fixture, window)
        #expect(fixture.value.json["threadSettings"]?["model"] == .text("cafe\u{301}"))
        let decomposed = try #require(fixture.controls["claude.model"]?["options"]?.arrayValue?.first { $0["label"] == .text("Decomposed identifier") })
        #expect(fixture.controls["claude.model"]?["value"] == decomposed["id"])
        try await operate("model", "select", .text(""), fixture, window)
        #expect(fixture.value.json["threadSettings"]?["model"] == nil)
        #expect(fixture.value.json["threadSettings"]?["effort"] == nil)
        try await operate("permissionMode", "select", .text(""), fixture, window)
        #expect(fixture.value.json["threadSettings"]?["permissionMode"] == nil)
        #expect(fixture.controls["claude.customModel"] == nil)
        try await operate("useDefaults", "set", .bool(true), fixture, window)
        #expect(fixture.value.json == .object(["threadSettings": .object([:])]))
        #expect(fixture.controls["claude.model"] == nil)
        try await operate("useDefaults", "set", .bool(false), fixture, window)
        #expect(fixture.value.json["useDefaultThreadSettings"] == .bool(false))
        #expect(fixture.controls["claude.model"]?["value"] == .text(""))
    }

    private func mount(_ fixture: ClaudeSettingsFixture, width: CGFloat = 900) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: fixture.snapshot ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: ClaudeSettingsReplaySurface(fixture: fixture, width: width))
        window.orderFront(nil)
        return window
    }
    private func settle(_ fixture: ClaudeSettingsFixture, _ window: NSWindow) async throws {
        for _ in 0..<100 {
            window.contentView?.layoutSubtreeIfNeeded()
            if !fixture.controls.isEmpty && fixture.controls.values.allSatisfy({ $0["pending"] == .bool(false) }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PluginContractError("Claude settings controls did not settle")
    }
    private func operate(_ field: String, _ operation: String, _ value: JSONValue,
                         _ fixture: ClaudeSettingsFixture, _ window: NSWindow) async throws {
        let id = "claude." + field
        let control = try #require(fixture.controls[id])
        try fixture.registry.perform(id: id, handle: try #require(control["handle"]?.stringValue),
                                     operation: operation, value: value, context: fixture.context)
        try await settle(fixture, window)
    }
    private func select(_ field: String, label: String, _ fixture: ClaudeSettingsFixture, _ window: NSWindow) async throws {
        let options = try #require(fixture.controls["claude." + field]?["options"]?.arrayValue)
        let option = try #require(options.first { $0["label"] == .text(label) })
        try await operate(field, "select", try #require(option["id"]), fixture, window)
    }
    private func capture(_ window: NSWindow, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MOKUSEI_CLAUDE_SETTINGS_ARTIFACTS"] else { return }
        let view = try #require(window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(name + ".png"))
    }
}

@MainActor @Observable
private final class ClaudeSettingsFixture {
    var value: ClaudeHarnessSettings
    var changes = 0
    let snapshot: Bool
    let registry = NativeSettingsInteractions()
    let context = NativeSettingsInteractionContext(visit: UUID(), section: "claude")
    let resource: HarnessSettingsResource<ClaudeSettingsPresentationData>
    var controls: [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: registry.snapshot(context: context).compactMap { control in
            control["id"]?.stringValue.map { ($0, control) }
        })
    }
    init(snapshot: Bool) throws {
        self.snapshot = snapshot
        value = try ClaudeHarnessSettings(json: .object([
            "useDefaultThreadSettings": .bool(false), "threadSettings": .object([
                "model": .text("effort"), "effort": .text("high"), "permissionMode": .text("auto"),
                "allowedTools": .array([.text("Read")]), "disallowedTools": .array([.text("Bash")])
            ])
        ]))
        let catalog = try ClaudeSettingsPresentationData(json: .object([
            "cli": .object(["status": .text("available"), "executablePath": .text("/fixture/claude")]),
            "models": .array([
                .object(["value": .text("effort"), "displayName": .text("Effort model"),
                         "supportedEfforts": .array([.text("medium"), .text("high")]),
                         "thinking": .object(["kind": .text("effort"), "efforts": .array([.text("medium"), .text("high")]), "canDisable": .bool(false)])]),
                .object(["value": .text("fixed"), "displayName": .text("Fixed model"), "supportedEfforts": .array([]),
                         "thinking": .object(["kind": .text("fixed")])]),
                .object(["value": .text("caf\u{e9}"), "displayName": .text("Composed identifier"), "supportedEfforts": .array([]),
                         "thinking": .object(["kind": .text("fixed")])]),
                .object(["value": .text("cafe\u{301}"), "displayName": .text("Decomposed identifier"), "supportedEfforts": .array([]),
                         "thinking": .object(["kind": .text("fixed")])])
            ])
        ]))
        resource = HarnessSettingsResource(state: .ready(catalog), reload: { _ in catalog })
    }
}

private struct ClaudeSettingsReplaySurface: View {
    let fixture: ClaudeSettingsFixture
    let width: CGFloat
    var body: some View {
        NativeSettingsFormScope {
            ClaudeHarnessSettingsView(props: .init(section: .thread, executionSnapshot: fixture.snapshot,
                settingsFormPage: true, value: fixture.value, resource: fixture.resource, host: nil,
                change: { fixture.changes += 1; fixture.value = $0 }))
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NativePalette.settings.main.swiftUI)
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.colorScheme, fixture.snapshot ? .dark : .light)
        .environment(\.nativeSettingsViewportWidth, width)
        .environment(\.nativeSettingsInteractions, fixture.registry)
        .environment(\.nativeSettingsInteractionContext, fixture.context)
        .environment(\.nativeSettingsInteractionRefresh, fixture.registry.refresh)
        .environment(\.nativeSettingsInteractionScope, "claude")
    }
}
