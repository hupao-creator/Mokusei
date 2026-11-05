import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

@MainActor public enum NativeAttentionApplication {
    public static func make() throws -> ApplicationPluginModule {
        let manifest = try ApplicationPluginManifest(id: "attention", displayName: "Attention", contributes: .init(
            backgroundAgents: ["attention.agent"], settings: ["attention.settings"]))
        return try ApplicationPluginModule(manifest: manifest, settings: [AnyApplicationSettingsPlugin(AttentionSettingsPlugin())])
    }
}

@MainActor private struct AttentionSettingsPlugin: ApplicationSettingsPlugin {
    var key: ApplicationValueKey<ApplicationBackgroundExecutionSettings> { nativeBackgroundSettingsKey("attention.settings", owner: "attention") }
    let label: JSONText = "注意力整理"
    let requires = [ApplicationCapabilities.backgroundConfigurationUI.requirement]
    func settings(props: ApplicationSettingsProps<ApplicationBackgroundExecutionSettings>) -> some View {
        NativeBackgroundSettingsView(props: props,
            description: applicationText(props.locale, "自动收起暂时不再关注的会话。", "Hide threads that no longer need your attention from Overview."))
    }
}
