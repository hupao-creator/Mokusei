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
            HStack(spacing: 4) {
                ForEach(options, id: \.0) { id, title in
                    Button {
                        choose(id)
                    } label: {
                        Text(title).font(NativeTypography.settings(size: 12, weight: selected == id ? 600 : 400))
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(selected == id ? NativePalette.settings.text.swiftUI : NativePalette.settings.muted.swiftUI)
                            .background { if selected == id { Capsule().fill(NativePalette.settings.selectedTabFill.swiftUI) } }
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(selected == id ? .isSelected : [])
                        .nativeSettingsAction("routingPreset." + id, label: title, selected: selected == id) { choose(id) }
                }
            }.padding(4).background(Capsule().fill(NativePalette.settings.sidebar.swiftUI))
            Text(explanation).font(NativeTypography.settings(size: 12)).foregroundStyle(NativePalette.settings.muted.swiftUI)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
    }
    private var explanation: String {
        switch selected {
        case "economy": locale.text("仅使用高性价比模型；如 GPT Luna、GPT Reserve、Claude Haiku 或 DeepSeek Flash。", "Use only cost-effective models, such as GPT Luna, GPT Reserve, Claude Haiku or DeepSeek Flash.")
        case "balanced": locale.text("常规任务使用高性价比模型，复杂任务使用 frontier 模型，如 GPT Astra、GPT Sol 或 Claude Opus / Fable。", "Use cost-effective models for routine tasks and frontier models such as GPT Astra, GPT Sol or Claude Opus / Fable for complex tasks.")
        case "performance": locale.text("仅使用 frontier 模型，如 GPT Astra、GPT Sol 或 Claude Opus / Fable。", "Use only frontier models, such as GPT Astra, GPT Sol or Claude Opus / Fable.")
        default: locale.text("保留并使用你的手动偏好；留空则由 Moku 自行选择。", "Keep and use your manual preferences; leave blank to let Moku choose.")
        }
    }
    private func choose(_ id: String) {
        guard selected != id else { return }
        NativeSettingsChangeContext.withDiscreteChange {
            value = settingsReplacing(value, path: ["routingPreset"], value: id == "custom" ? nil : .text(id))
        }
    }
}
