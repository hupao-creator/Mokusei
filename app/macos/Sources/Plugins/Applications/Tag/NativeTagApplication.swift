import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

@MainActor public enum NativeTagApplication {
    public static func make() throws -> ApplicationPluginModule {
        let manifest = try ApplicationPluginManifest(id: "tag", displayName: "Tag", contributes: .init(
            backgroundAgents: ["tag.agent"], settings: ["tag.settings"]))
        return try ApplicationPluginModule(manifest: manifest, settings: [AnyApplicationSettingsPlugin(TagSettingsPlugin())])
    }
}

@MainActor private struct TagSettingsPlugin: ApplicationSettingsPlugin {
    var key: ApplicationValueKey<ApplicationBackgroundExecutionSettings> { nativeBackgroundSettingsKey("tag.settings", owner: "tag") }
    let label: JSONText = "标签管理"
    let requires = [ApplicationCapabilities.backgroundConfigurationUI.requirement]
    func settings(props: ApplicationSettingsProps<ApplicationBackgroundExecutionSettings>) -> some View {
        NativeBackgroundSettingsView(props: props,
            description: applicationText(props.locale, "自动生成和整理语义标签，让会话筛选更清晰。", "Automatically create and organize semantic tags for clearer conversation filtering."))
    }
}
