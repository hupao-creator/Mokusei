import AppKit
import Observation
import SwiftUI
import Testing
import MokuseiCore
import MokuseiPluginUI
import MokuseiTestSupport
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeModelRoutingPreferencesTests {
    @Test func capsulesSaveRestoreAndPreserveCustomText() async throws {
        let fixture = RoutingPreferenceFixture()
        let window = SwiftUIReplay.window(RoutingPreferenceSurface(fixture: fixture), width: 700, height: 240)
        defer { window.orderOut(nil); window.contentView = nil }
        func control(_ id: String) -> JSONValue? {
            fixture.registry.snapshot(context: fixture.context).first { $0["id"] == .text("moku.routingPreset." + id) }
        }
        try await SwiftUIReplay.wait { control("custom") != nil }
        #expect(control("custom")?["value"] == .bool(true))
        #expect(fixture.draft.value["moku"]?["routingGuidance"] == .text("My existing manual choices"))
        for preset in ["economy", "balanced", "performance", "custom"] {
            let row = try #require(control(preset))
            try fixture.registry.perform(id: "moku.routingPreset." + preset, handle: try #require(row["handle"]?.stringValue),
                operation: "activate", value: .null, context: fixture.context)
            try await SwiftUIReplay.wait { control(preset)?["value"] == .bool(true) && fixture.draft.status == .saved }
            #expect(fixture.draft.saved["moku"]?["routingPreset"] == .text(preset))
            #expect(fixture.draft.saved["moku"]?["routingGuidance"] == .text("My existing manual choices"))
            let reopened = NativeSettingsDraft(settings: fixture.draft.saved, revision: fixture.draft.revision,
                save: { value, revision in .saved(settings: value, revision: revision + 1) })
            #expect(reopened.value == fixture.draft.saved)
        }
        let writes = fixture.writes
        fixture.locale = .chinese
        try await SwiftUIReplay.wait { control("economy")?["label"] == .text("经济") }
        #expect(control("balanced")?["label"] == .text("平衡"))
        #expect(control("performance")?["label"] == .text("性能"))
        #expect(control("custom")?["label"] == .text("自定义"))
        #expect(fixture.writes == writes)

    }
}

@MainActor @Observable private final class RoutingPreferenceFixture {
    var locale = DesktopLocale.english
    var writes = 0
    var draft: NativeSettingsDraft!
    let registry = NativeSettingsInteractions()
    let context = NativeSettingsInteractionContext(visit: UUID(), section: "moku")
    init() {
        draft = NativeSettingsDraft(settings: .object(["moku": .object([
            "routingGuidance": .text("My existing manual choices")
        ])]), revision: 1, save: { [weak self] value, revision in
            self?.writes += 1
            return .saved(settings: value, revision: revision + 1)
        })
        draft.runtimeAvailable = true
    }
}

private struct RoutingPreferenceSurface: View {
    let fixture: RoutingPreferenceFixture
    var body: some View {
        NativeSettingsFormScope {
            NativeModelRoutingPreferences(value: Binding(get: { fixture.draft.value["moku"]! }, set: { next in
                fixture.draft.change(settingsReplacing(fixture.draft.value, path: ["moku"], value: next))
            }), locale: fixture.locale)
        }.padding(24)
            .environment(\.nativeSettingsInteractions, fixture.registry)
            .environment(\.nativeSettingsInteractionContext, fixture.context)
            .environment(\.nativeSettingsInteractionRefresh, fixture.registry.refresh)
    }
}
