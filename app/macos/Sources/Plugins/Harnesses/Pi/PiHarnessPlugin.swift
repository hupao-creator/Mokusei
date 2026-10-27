import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Pi's private protocol remains with the Node harness. This build-time plugin
/// owns the full native presentation and never publishes a canonical timeline.
public struct PiHarnessPlugin: HarnessPlugin {
    public init() {}
    public var descriptor: HarnessPluginDescriptor {
        HarnessPluginDescriptor(id: "pi", displayName: "Pi Agent", threadCapabilities:
            HarnessThreadCapabilities(instructions: true, threadContext: true, sendContext: true, toolModes: [.exclusive]))
    }
    public var logoSource: String { Self.logo }
    public func logo(size: CGFloat) -> some View { PiLogo(size: size) }
    public var translations: HarnessTranslationCatalog {
        ["en-US": Dictionary(uniqueKeysWithValues: piEnglish.map { (JSONText($0.key), JSONText($0.value)) })]
    }
    public var threadSettingsCodec: PluginValueCodec<JSONValue> {
        PluginValueCodec(decode: { try piValidateSettings($0, update: true) }, encode: { try piValidateSettings($0, update: true) })
    }
    public var harnessSettingsCodec: PluginValueCodec<JSONValue> {
        PluginValueCodec(decode: { try piValidateSettings($0, update: false) }, encode: { try piValidateSettings($0, update: false) })
    }
    public var settingsPresentationCodec: PluginValueCodec<JSONValue> {
        PluginValueCodec(decode: piValidatePresentation, encode: piValidatePresentation)
    }
    public func projectOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewProjection<PiOverviewView> {
        try piOverview(input: input, availableColumns: availableColumns)
    }
    public func executionTokenUsage(thread: HarnessThread, executionID: JSONText) throws -> HarnessExecutionTokenUsage? {
        let usage = try PiState(thread.sessionState).executionUsage[executionID]
        return usage.map { HarnessExecutionTokenUsage(value: JSONText(piCompactTokens($0.total)), count: $0.total, suffix: "tokens") }
    }
    public func projectMokuDock(input: HarnessThreadInput) throws -> HarnessMokuPresentation? { piMokuPresentation(try PiState(input.thread.sessionState)) }
    public func threadView(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext) -> some View {
        PiThreadView(input: input, actions: actions, context: context).id(input.thread.id)
    }
    public func overviewCard(input: HarnessThreadInput, projection: PiOverviewView, actions: HarnessThreadActions, openThread: @escaping () -> Void) -> some View {
        PiOverviewCard(input: input, projection: projection, actions: actions, openThread: openThread)
    }
    public func threadSettings(input: HarnessThreadInput, resource: HarnessSettingsResource<JSONValue>, update: @escaping (JSONValue) async throws -> Void) -> some View {
        PiThreadSettingsView(input: input, resource: resource, update: update).id(input.thread.id)
    }
    public func harnessSettings(props: HarnessSettingsProps<JSONValue, JSONValue>) -> some View { PiHarnessSettingsView(props: props) }

    static let logo = "data:image/svg+xml," + """
    <?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 800"><style>.logo-mark { fill: #000; } @media (prefers-color-scheme: dark) { .logo-mark { fill: #fff; } }</style><path class="logo-mark" fill-rule="evenodd" d="M165.29 165.29 H517.36 V400 H400 V517.36 H282.65 V634.72 H165.29 Z M282.65 282.65 V400 H400 V282.65 Z"/><path class="logo-mark" d="M517.36 400 H634.72 V634.72 H517.36 Z"/></svg>
    """.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
}

func piLocalized(_ source: String, _ locale: Locale) -> String {
    locale.language.languageCode?.identifier == "zh" ? source : piEnglish[source] ?? NativePluginLocalization.localize(source, locale: locale)
}
private let piEnglish: [String: String] = [
    "请补全模型相关配置；完成前不会保存此组修改。": "Complete the model settings to save these changes.",
    "Pi Thread 配置": "Pi Thread settings", "Pi 原生默认": "Pi native default", "Pi 状态不可用": "Pi status unavailable",
    "正在读取 Pi 环境…": "Loading the Pi environment…", "重试中…": "Retrying…"
]
