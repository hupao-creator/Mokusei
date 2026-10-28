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

        "使用上下方向键选择轮次，按回车阅读": "Use Up and Down to choose a turn, then Return to read it",
        "对话目录": "Conversation contents", "当前轮次": "Current turn",
        "第 {count} 轮对话": "Turn {count}", "按回车阅读这轮对话": "Press Return to read this turn",
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
        "网页": "Web page", "后退": "Back", "前进": "Forward", "网址": "Address",
        "批注网页": "Annotate page", "收起网页": "Collapse web page",
        "请输入有效的 HTTP 或 HTTPS 网址": "Enter a valid HTTP or HTTPS address",
        "仅发送文字": "Send text only", "{count} 条批注": "{count} annotations",
        "查看 {count} 条待发送批注": "View {count} pending annotations",
        "补充说明…": "Additional notes…", "补充说明": "Additional notes",
        "发送批注": "Send annotations", "发送中": "Sending", "批注 {index}": "Annotation {index}",
        "返回批注列表": "Back to annotations", "预览批注截图": "Preview annotation screenshot",
        "删除此批注": "Delete this annotation", "批注 {index} 评论": "Annotation {index} comment",
        "填写批注…": "Add a comment…", "删除批注 {index}": "Delete annotation {index}",
        "批注原始截图": "Original annotation screenshot", "描述要修改的内容…": "Describe the changes…",
        "批注内容": "Annotation comment", "添加批注": "Add annotation",
        "网页下载已取消": "Web download cancelled", "已阻止打开该地址": "Opening this address was blocked",
        "网页进程已退出，请重试": "The web process exited. Please try again.",
        "网页响应失败（HTTP {status}）": "The page returned HTTP {status}",
        "网页选区已变化，请重新选择": "The page selection changed. Please select it again.",
        "网页区域不可见": "The selected area is not visible", "截图失败": "Screenshot failed",
        "截图超过 20 MB": "The screenshot exceeds 20 MB", "好": "OK",
        "轻点元素或拖动框选 · 再点批注按钮取消": "Click an element or drag to select · Click Annotate again to cancel",
        "点击元素或拖拽框选 · Esc 取消": "Click an element or drag to select · Esc to cancel",
        "执行失败，批注已恢复。可以重试，或仅发送文字。": "Execution failed. Annotations were restored. Retry or send text only.",
        "执行已停止，批注已恢复。": "Execution stopped. Annotations were restored.",
        "此 Thread 已归档，请取消归档后发送。": "This thread is archived. Unarchive it before sending.",
        "请先处理此 Thread 等待中的交互，再发送批注。": "Respond to this thread's pending interaction before sending annotations.",
        "批注截图数量不匹配": "The annotation screenshot count does not match",
        "执行失败，批注仍保留。详情见线程记录。": "Execution failed. Annotations are retained. See the thread for details.",
        "执行已停止，批注仍保留。": "Execution stopped. Annotations are retained.",
        "无效的网页选区": "Invalid page selection", "无效的网页选区尺寸": "Invalid page selection size",
        "无效的网页滚动位置": "Invalid page scroll position", "网页选择器过长": "The page selector is too long",
        "网页选区文本过长": "The selected page text is too long",
        "一只小猫坐在电脑后面，等待新的想法。": "A cat behind a computer, waiting for a new idea.",
        "low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra high", "minimal": "Minimal", "none": "None"
    ]
}
