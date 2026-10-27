import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Build-time presentation entry point. Runtime commands remain with the
/// existing Codex backend; all of its presentation is native Swift.
public struct CodexHarnessPlugin: HarnessPlugin {
    public init() {}
    public var descriptor: HarnessPluginDescriptor {
        HarnessPluginDescriptor(id: "codex", displayName: "Codex",
            threadCapabilities: HarnessThreadCapabilities(instructions: true, threadContext: true,
                sendContext: true, toolModes: [.extend, .exclusive]))
    }
    public var logoSource: String { CodexLogo.source }
    public func logo(size: CGFloat) -> some View { CodexLogo(size: size) }
    public var translations: HarnessTranslationCatalog {
        ["en-US": Dictionary(uniqueKeysWithValues: codexEnglish.map { (JSONText($0.key), JSONText($0.value)) })]
    }
    public var threadSettingsCodec: PluginValueCodec<CodexThreadSettingsUpdate> { CodexThreadSettingsUpdate.codec }
    public var harnessSettingsCodec: PluginValueCodec<CodexHarnessSettings> { CodexHarnessSettings.codec }
    public var settingsPresentationCodec: PluginValueCodec<CodexSettingsPresentationData> { CodexSettingsPresentationData.codec }

    public func projectOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewProjection<CodexOverviewView> {
        try projectCodexOverview(input: input, availableColumns: availableColumns)
    }
    public func executionTokenUsage(thread: HarnessThread, executionID: JSONText) throws -> HarnessExecutionTokenUsage? {
        try codexExecutionTokenUsage(thread: thread, executionID: executionID)
    }
    public func projectMokuDock(input: HarnessThreadInput) throws -> HarnessMokuPresentation? {
        projectCodexMokuPresentation(state: try CodexState(input.thread.sessionState, createdAt: input.thread.createdAt).raw)
    }
    public func threadView(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext) -> some View {
        CodexThreadView(input: input, actions: actions, context: context)
    }
    public func overviewCard(input: HarnessThreadInput, projection: CodexOverviewView, actions: HarnessThreadActions,
                             openThread: @escaping () -> Void) -> some View {
        CodexOverviewCard(input: input, projection: projection, actions: actions, openThread: openThread)
    }
    public func threadSettings(input: HarnessThreadInput, resource: HarnessSettingsResource<CodexSettingsPresentationData>,
                               update: @escaping (CodexThreadSettingsUpdate) async throws -> Void) -> some View {
        CodexThreadSettingsView(input: input, resource: resource, update: update)
    }
    public func harnessSettings(props: HarnessSettingsProps<CodexHarnessSettings, CodexSettingsPresentationData>) -> some View {
        CodexHarnessSettingsView(props: props)
    }
}

func codexLocalized(_ source: String, locale: Locale) -> String {
    guard locale.language.languageCode?.identifier != "zh" else { return source }
    return codexEnglish[source] ?? NativePluginLocalization.localize(source, locale: locale)
}

private let codexEnglish: [String: String] = [
    "该 Codex 请求已失效。": "This Codex request has expired.", "Codex 消息时间线": "Codex message timeline",
    "Codex 线程发生系统错误": "A system error occurred in the Codex thread", "后台终端": "Background terminals",
    "保存后的设置在下一次 Codex 操作时生效；Primary Native Session 不会被替换。": "Saved settings take effect on the next Codex operation; the primary native session is preserved.",
    "用于新建 Thread 的原生配置默认值。": "Native defaults for new threads.",
    "跟随 Codex 默认模型": "Use the Codex default model", "请选择模型": "Select a model", "请选择 Thinking": "Select thinking",
    "Thinking 能力未知，无法执行": "Thinking capability is unknown; execution is unavailable", "未选择": "Not selected",
    "服务层级": "Service tier", "Mokusei 默认": "Mokusei default", "Mokusei 默认（approve-for-me）": "Mokusei default (approve-for-me)",
    "ask-for-approval · 按需询问用户": "ask-for-approval · ask the user as needed", "approve-for-me · 原生自动审批": "approve-for-me · native auto review",
    "full-access · 完全访问": "full-access · full access", "未知模型": "Unknown model", "内容必须是有效 JSON。": "Content must be valid JSON.",
    "内容必须是 JSON object。": "Content must be a JSON object.", "正在读取 Codex 环境…": "Loading the Codex environment…",
    "已读取 Codex 环境": "Codex environment loaded", "Codex CLI 不可用": "Codex CLI unavailable", "Codex Thread 默认配置": "Codex Thread defaults",
    "Codex 运行配置": "Codex execution configuration", "无法确认此模型的推理强度能力。": "The reasoning effort capabilities of this model could not be confirmed.",
    "推理强度能力不可确认": "Reasoning effort capabilities could not be confirmed", "运行配置会明确保存，修改后从下一次运行生效。": "Execution settings are saved explicitly. Changes take effect on the next run.",
    "模型不提供推理强度配置": "Reasoning effort is not configurable for this model", "请选择推理强度": "Select reasoning effort",
    "请选择服务层级": "Select a service tier", "请选择权限模式": "Select a permission mode", "标准": "Standard", "Codex Thread": "Codex thread",
    "需处理": "Needs attention", "已完成": "Completed", "失败": "Failed", "已取消": "Cancelled", "空闲": "Idle",
    "等待输入": "Waiting for input", "思考过程": "Reasoning", "上下文已压缩": "Context compacted", "补充": "Follow-up", "你": "You",
    "已允许": "Allowed", "已拒绝": "Denied", "已提交": "Submitted", "已处理": "Resolved", "允许一次": "Allow once",
    "本会话始终允许": "Always allow in this session", "拒绝": "Deny", "取消": "Cancel", "允许": "Allow", "提交": "Submit", "重试": "Retry",
    "读取对话内容失败。": "Failed to load conversation content.",
    "Codex MCP schema presentation 无效": "The Codex MCP schema presentation is invalid."
]
