import MokuseiCore
import MokuseiPluginUI
import SwiftUI

/// Preset identity and hand-written guidance have separate ownership. Choosing a
/// preset or changing locale never rewrites the user's retained custom text.
struct NativeModelRoutingPreferences: View {
    @Binding var value: JSONValue
    let locale: DesktopLocale
    private var selected: String { value["routingPreset"]?.stringValue ?? "custom" }
    private var options: [(String, String)] {
        [("economy", locale.text("经济", "Economy")), ("balanced", locale.text("平衡", "Balanced")),
         ("performance", locale.text("性能", "Performance")), ("custom", locale.text("自定义", "Custom"))]
    }
    var body: some View {
        SettingsRow(label: locale.text("模型选择偏好", "Model selection preferences"), stacked: true) {
            GlassEffectContainer {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 12)], spacing: 12) {
                    ForEach(options, id: \.0) { id, title in
                        NativeSettingsChoiceButton(title, selected: selected == id) { choose(id) }
                            .nativeSettingsAction("routingPreset." + id, label: title, selected: selected == id) { choose(id) }
                    }
                }
            }
            Text(explanation).font(NativeTypography.settings(size: 12)).foregroundStyle(NativePalette.settings.muted.swiftUI)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
    }
    private var explanation: String {
        switch selected {
        case "economy": locale.text("仅使用高性价比模型。", "Use only cost-effective models.")
        case "balanced": locale.text("常规任务用高性价比模型，复杂任务用前沿模型。", "Use cost-effective models for routine tasks and frontier models for complex tasks.")
        case "performance": locale.text("仅使用前沿模型。", "Use only frontier models.")
        default: locale.text("按你的偏好选择；留空由 Moku 决定。", "Use your preferences; leave blank to let Moku choose.")
        }
    }
    private func choose(_ id: String) {
        guard selected != id else { return }
        NativeSettingsChangeContext.withDiscreteChange {
            value = settingsReplacing(value, path: ["routingPreset"], value: id == "custom" ? nil : .text(id))
        }
    }
}
