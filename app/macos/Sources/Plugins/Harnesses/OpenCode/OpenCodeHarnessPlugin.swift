import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Native OpenCode presentation. CLI, permissions, native sessions and execution
/// ownership remain in the existing independent runtime backend.
public struct OpenCodeHarnessPlugin: HarnessPlugin {
    public init() {}
    public var descriptor: HarnessPluginDescriptor { .init(id: "opencode", displayName: "OpenCode",
        threadCapabilities: .init(instructions: true, threadContext: true, sendContext: true, toolModes: [.extend, .exclusive])) }
    public var logoSource: String { OpenCodeLogo.source }
    public func logo(size: CGFloat) -> some View { OpenCodeLogo(size: size) }
    public var translations: HarnessTranslationCatalog { ["en-US": Dictionary(uniqueKeysWithValues: ocEnglish.map { (JSONText($0.key), JSONText($0.value)) })] }
    public var threadSettingsCodec: PluginValueCodec<OpenCodeThreadSettingsUpdate> { OpenCodeThreadSettingsUpdate.codec }
    public var harnessSettingsCodec: PluginValueCodec<OpenCodeHarnessSettings> { OpenCodeHarnessSettings.codec }
    public var settingsPresentationCodec: PluginValueCodec<OpenCodeSettingsPresentationData> { OpenCodeSettingsPresentationData.codec }
    public func projectOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewProjection<OpenCodeOverviewView> {
        try projectOpenCodeOverview(input: input, availableColumns: availableColumns)
    }
    public func executionTokenUsage(thread: HarnessThread, executionID: JSONText) throws -> HarnessExecutionTokenUsage? {
        let state = try OpenCodeState(thread.sessionState)
        guard let usage = ocExecutionUsage(state.messages.filter { $0.executionID == executionID }, auxiliary: state.auxiliary.filter { $0.ocText("executionId") == executionID }) else { return nil }
        return .init(value: JSONText(ocCompactTokens(usage.total)), count: usage.total, suffix: "tokens")
    }
    public func projectMokuDock(input: HarnessThreadInput) throws -> HarnessMokuPresentation? { projectOpenCodeMoku(try OpenCodeState(input.thread.sessionState)) }
    public func threadView(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext) -> some View {
        OpenCodeThreadView(input: input, actions: actions, context: context).id(input.thread.id)
    }
    public func overviewCard(input: HarnessThreadInput, projection: OpenCodeOverviewView, actions: HarnessThreadActions, openThread: @escaping () -> Void) -> some View {
        OpenCodeOverviewCard(input: input, projection: projection, actions: actions, openThread: openThread)
    }
    public func threadSettings(input: HarnessThreadInput, resource: HarnessSettingsResource<OpenCodeSettingsPresentationData>, update: @escaping (OpenCodeThreadSettingsUpdate) async throws -> Void) -> some View {
        OpenCodeThreadSettingsView(input: input, resource: resource, update: update)
    }
    public func harnessSettings(props: HarnessSettingsProps<OpenCodeHarnessSettings, OpenCodeSettingsPresentationData>) -> some View { OpenCodeHarnessSettingsView(props: props) }
}
func ocLocalized(_ source: String, locale: Locale) -> String {
    guard locale.language.languageCode?.identifier != "zh" else { return NativePluginLocalization.localize(source, locale: locale) }
    return ocEnglish[source] ?? NativePluginLocalization.localize(source, locale: locale)
}
private let ocEnglish: [String: String] = [
    "请补全模型相关配置；完成前不会保存此组修改。": "Complete the model settings to save these changes.",
    "基础模型变体": "Base model variant", "OpenCode Thread 配置": "OpenCode Thread settings", "OpenCode Thread 默认配置": "Default OpenCode Thread settings",
    "OpenCode 原生默认": "OpenCode native default", "自动批准权限请求（保留拒绝规则）": "Approve permission requests automatically (keep deny rules)",
    "按原生规则询问": "Ask according to native rules", "当前原生模型": "Current native model", "OpenCode 模型变体": "OpenCode model variant", "OpenCode Agent": "OpenCode agent",
    "OpenCode 状态不可用": "OpenCode state unavailable", "OpenCode 请求已失效": "This OpenCode request is no longer available",
    "正在读取 OpenCode 环境…": "Loading the OpenCode environment…", "正在刷新 OpenCode…": "Refreshing OpenCode…",
    "来自源 OpenCode 会话的分支历史": "History from the source OpenCode session", "OpenCode 分支历史（只读）": "OpenCode fork history (read-only)",
    "OpenCode 拒绝原因（可选）": "Reason for denying OpenCode (optional)", "OpenCode 子会话": "OpenCode child session", "打开 OpenCode 表单": "Open OpenCode form",
    "打开 OpenCode 请求页面": "Open the OpenCode request page", "我已完成此步骤": "I have completed this step", "其他回答，每行一项": "Other answers, one per line", "是": "Yes", "否": "No",
    "该 OpenCode 免费模型可用于保留原生工具的普通任务和线程问答，但不支持 Moku 或独占工具的元数据生成。请选择其他已配置的 Host 或模型；不会自动改用付费模型。": "This free OpenCode model supports ordinary tasks and thread questions with native tools, but not Moku or metadata generation with exclusive tools. Select another configured Host or model; Mokusei will not automatically switch to a paid model.",
    "模型": "Model", "推理选择": "Thinking", "权限模式": "Permission mode", "请选择": "Select", "目录中不可用": "Unavailable in catalog", "未选择": "Not selected",
    "该 Thread 正在运行，请等待完成或停止后再修改。": "This thread is running. Wait for it to finish or stop it before editing.", "应用 Thread 配置": "Apply thread settings",
    "可用": "Available", "不可用": "Unavailable", "重试": "Retry", "允许一次": "Allow once", "本会话始终允许": "Allow for this session", "拒绝": "Deny", "提交": "Submit", "取消": "Cancel",
    "已中断": "Interrupted", "失败": "Failed", "等待你的响应": "Waiting for your response", "运行中": "Running", "已完成": "Completed", "工具": "Tool", "思考过程": "Reasoning"
]
