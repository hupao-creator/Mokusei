import Foundation

/// Shared component copy only. Harness catalogs remain owned by their plugins.
public enum NativePluginLocalization {
    public static func localize(_ source: String, locale: Locale) -> String {
        guard locale.language.languageCode?.identifier != "zh" else {
            return ["low": "低", "medium": "中", "high": "高", "xhigh": "极高", "minimal": "极少", "none": "无"][source] ?? source
        }
        return NativePluginEnglishCatalog.values[source] ?? english[source] ?? source
    }

    private static let english: [String: String] = [
        "尚无回复": "No response yet", "准备开始": "Preparing to start", "正在执行": "Running",
        "回复会显示在这里": "Responses will appear here",
        "请处理卡片中的请求": "Respond to the request on this card",
        "打开对话查看请求": "Open the conversation to view the request",
        "尚未收到回复，可打开对话查看": "No response received. Open the conversation for details",
        "尚未收到回复": "No response received", "执行已结束": "Execution ended",
        "没有可显示的回复": "No response to display", "尚无可显示的回复": "No response to display yet",

        "历史对话": "Conversation history", "前 1 轮对话": "1 previous turn",
        "窗口控制": "Window controls", "窗口与返回导航": "Window and back navigation",
        "前 {count} 轮对话": "{count} previous turns", "返回当前会话": "Back to current conversation",
        "显示用户消息": "Show user messages", "隐藏用户消息": "Hide user messages",
        "显示执行过程": "Show execution details", "收起执行过程": "Hide execution details",
        "历史执行不可用": "Historical execution unavailable", "无法找到报告关联的历史执行。": "The linked historical execution could not be found.",
        "这轮对话已不可用。": "This conversation turn is no longer available.", "正在读取": "Loading",
        "消息显示": "Message display", "消息时间线": "Message timeline", "已加载消息": "Loaded messages",
        "显示更早的 {count} 条消息": "Show {count} earlier messages", "回到最新": "Jump to latest",
        "运行中": "Running", "对话轮次": "Conversation turn", "未知模型": "Unknown model", "未记录": "Not recorded",
        "完成时间：": "Completed:", "已运行 {duration}": "Ran for {duration}",
        "输入": "Input", "输出": "Output", "缓存读取": "Cache read", "缓存写入": "Cache write", "推理": "Reasoning",
        "执行过程": "Execution details", "1 段思考": "1 reasoning segment", "{count} 段思考": "{count} reasoning segments",
        "1 次工具调用": "1 tool call", "{count} 次工具调用": "{count} tool calls",
        "本轮思考 {count} tokens": "Turn reasoning: {count} tokens",
        "本轮已上报思考 {count} tokens": "Reported turn reasoning: {count} tokens",
        "最近一次思考 {count} tokens": "Last-call reasoning: {count} tokens",
        "计划": "Plan", "已展开": "Expanded", "已收起": "Collapsed", "网页批注": "Web annotations",
        "加载截图…": "Loading screenshot…", "收起截图": "Hide screenshot", "预览截图": "Preview screenshot", "仅文字批注": "Text-only annotation",
        "一只小猫坐在电脑后面，等待新的想法。": "A cat behind a computer, waiting for a new idea.",
        "low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra high", "minimal": "Minimal", "none": "None"
    ]
}
