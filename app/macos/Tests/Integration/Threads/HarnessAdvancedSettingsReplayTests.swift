import AppKit
import Observation
import SwiftUI
import Testing
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiTestSupport
import MokuseiHarnessCodex
import MokuseiHarnessClaude
import MokuseiHarnessPi
import MokuseiHarnessOpenCode

/// Real Harness editors own the fields and bindings; fixtures supply only the
/// native catalog and persisted settings. Collapse and locale changes must not save.
@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct HarnessAdvancedSettingsReplayTests {
    @Test(arguments: ["codex", "claude", "pi", "opencode"], [false, true])
    func advancedControlsRetainValuesAndFollowLocale(harness: String, snapshot: Bool) async throws {
        let fixture = AdvancedSettingsFixture(harness: harness, snapshot: snapshot)
        let surface: AnyView
        switch harness {
        case "codex": surface = try editor(CodexHarnessPlugin(), fixture)
        case "claude": surface = try editor(ClaudeHarnessPlugin(), fixture)
        case "pi": surface = try editor(PiHarnessPlugin(), fixture)
        default: surface = try editor(OpenCodeHarnessPlugin(), fixture)
        }
        let window = HarnessSettingsReplay.window(surface, width: 900, height: 800)
        defer { window.orderOut(nil); window.contentView = nil }
        func control(_ field: String) -> JSONValue? {
            fixture.registry.snapshot(context: fixture.context).first { $0["id"] == .text(harness + "." + field) }
        }
        func operate(_ field: String, _ operation: String, _ value: JSONValue) async throws {
            let row = try #require(control(field))
            try fixture.registry.perform(id: harness + "." + field, handle: try #require(row["handle"]?.stringValue),
                operation: operation, value: value, context: fixture.context)
            try await HarnessSettingsReplay.wait {
                fixture.registry.snapshot(context: fixture.context).allSatisfy { $0["pending"] == .bool(false) }
            }
        }
        try await HarnessSettingsReplay.wait { control("model") != nil }
        let original = fixture.value
        #expect(control("permissionMode") == nil)
        #expect(control("serviceTier") == nil)
        #expect(control("useDefaults") == nil)
        #expect(control("agent") == nil)
        if harness == "pi" || harness == "opencode" {
            #expect(control("provider")?["label"] == .text("Provider"))
            fixture.locale = "zh-Hans"
            try await HarnessSettingsReplay.wait { control("provider")?["label"] == .text("提供商") }
            #expect(control("provider")?["value"] == .text("fixture"))
        } else { fixture.locale = "zh-Hans" }
        if harness != "pi" || !snapshot {
            try await HarnessSettingsReplay.wait { control("advancedOptions")?["label"] == .text("高级选项") }
            #expect(control("advancedOptions")?["value"] == .bool(false))
            try await operate("advancedOptions", "set", .bool(true))
            if harness != "pi" {
                try await HarnessSettingsReplay.wait { control("permissionMode") != nil }
                #expect(control("permissionMode")?["value"] == original["threadSettings"]?["permissionMode"])
            }
            if harness == "codex" { #expect(control("serviceTier")?["value"] == .text("priority")) }
            if !snapshot { #expect(control("useDefaults")?["value"] == .bool(false)) }
            try await operate("advancedOptions", "set", .bool(false))
            try await HarnessSettingsReplay.wait { control("permissionMode") == nil && control("useDefaults") == nil }
            try await operate("advancedOptions", "set", .bool(true))
            #expect(fixture.value == original && fixture.writes == 0)
            fixture.locale = "en-US"
            try await HarnessSettingsReplay.wait { control("advancedOptions")?["label"] == .text("Advanced options") }
            if harness != "pi" {
                let permission = harness == "codex" ? "full-access" : harness == "claude" ? "manual" : "default"
                try await operate("permissionMode", "select", .text(permission))
                try await HarnessSettingsReplay.wait { fixture.value["threadSettings"]?["permissionMode"] == .text(permission) }
                #expect(fixture.writes == 1)
                if harness == "opencode" { #expect(fixture.value["threadSettings"]?["agent"] == .text("build")) }
            }
        } else { #expect(control("advancedOptions") == nil) }
    }

    private func editor<P: HarnessPlugin>(_ plugin: P, _ fixture: AdvancedSettingsFixture) throws -> AnyView {
        let catalog = try plugin.settingsPresentationCodec.decode(fixture.catalog)
        let resource = HarnessSettingsResource(state: .ready(catalog), reload: { _ in catalog })
        _ = try plugin.harnessSettingsCodec.decode(fixture.value)
        return AnyView(AdvancedSettingsSurface(plugin: plugin, fixture: fixture, resource: resource))
    }
}

@MainActor @Observable
private final class AdvancedSettingsFixture {
    var value: JSONValue
    var locale = "en-US"
    var writes = 0
    let catalog: JSONValue
    let snapshot: Bool
    let registry = NativeSettingsInteractions()
    let context: NativeSettingsInteractionContext
    init(harness: String, snapshot: Bool) {
        self.snapshot = snapshot
        context = .init(visit: UUID(), section: harness)
        var profile: [JSONText: JSONValue] = ["model": .text("fixture")]
        switch harness {
        case "codex":
            profile.merge(["effort": .text("high"), "serviceTier": .text("priority"), "permissionMode": .text("approve-for-me")]) { _, next in next }
            catalog = .object(["cli": .object(["available": .bool(true)]), "models": .array([])])
        case "claude":
            profile.merge(["effort": .text("high"), "permissionMode": .text("auto")]) { _, next in next }
            catalog = .object(["cli": .object(["status": .text("available"), "executablePath": .text("/fixture/claude")]), "models": .array([
                .object(["value": .text("fixture"), "displayName": .text("Fixture"), "supportedEfforts": .array([.text("high")]),
                         "thinking": .object(["kind": .text("effort"), "efforts": .array([.text("high")]), "canDisable": .bool(false)])])
            ])])
        case "pi":
            profile.merge(["provider": .text("fixture"), "thinkingLevel": .text("high")]) { _, next in next }
            catalog = .object(["cli": .object(["status": .text("ready")]), "models": .array([
                .object(["provider": .text("fixture"), "id": .text("fixture"), "name": .text("Fixture"), "thinkingLevels": .array([.text("high")])])
            ])])
        default:
            profile.merge(["provider": .text("fixture"), "variant": .text("default"), "permissionMode": .text("auto"), "agent": .text("plan")]) { _, next in next }
            catalog = .object(["cli": .object(["status": .text("ready")]), "models": .array([
                .object(["provider": .text("fixture"), "id": .text("fixture"), "name": .text("Fixture"), "variants": .array([]),
                         "input": .array([.text("text")]), "output": .array([.text("text")])])
            ]), "agents": .array([
                .object(["id": .text("plan"), "name": .text("Plan"), "mode": .text("primary"), "description": .text("Plan description must not appear")]),
                .object(["id": .text("build"), "name": .text("Build"), "mode": .text("primary")])
            ])])
        }
        value = .object(["useDefaultThreadSettings": .bool(false), "threadSettings": .object(profile)])
    }
}

private struct AdvancedSettingsSurface<P: HarnessPlugin>: View {
    let plugin: P
    let fixture: AdvancedSettingsFixture
    let resource: HarnessSettingsResource<P.SettingsPresentation>
    var body: some View {
        if let value = try? plugin.harnessSettingsCodec.decode(fixture.value) {
            plugin.harnessSettings(props: .init(section: .thread, executionSnapshot: fixture.snapshot,
                settingsFormPage: true, value: value, resource: resource, host: nil,
                change: { fixture.value = try! plugin.harnessSettingsCodec.encode($0); fixture.writes += 1 }))
                .environment(\.locale, Locale(identifier: fixture.locale))
                .environment(\.nativeSettingsInteractions, fixture.registry)
                .environment(\.nativeSettingsInteractionContext, fixture.context)
                .environment(\.nativeSettingsInteractionRefresh, fixture.registry.refresh)
                .padding(24)
        }
    }
}

@MainActor private enum HarnessSettingsReplay {
    static func window(_ content: AnyView, width: CGFloat, height: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.makeKeyAndOrderFront(nil)
        return window
    }
    static func wait(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<150 {
            NSApp.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "Mounted settings did not settle", sourceLocation: sourceLocation)
    }
}
