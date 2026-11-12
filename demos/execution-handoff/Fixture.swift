import SwiftUI
import MokuseiCore
import MokuseiPluginUI

/// Synthetic executions only; no Harness, Runtime, profile or network services.
enum Fixture {
    static let previous = """
    原生阅读页已经整理好了。当前结果保留在主 detail 中，你可以继续阅读，同时让下一轮 execution 在右侧执行。

    ### 已完成的调整
    - 统一标题、正文与完成时间的阅读层级。
    - 执行过程默认收起，保留最终回复。
    - 新任务在 sidecard 中运行，不打断当前阅读。

    ### 下一步
    补齐键盘导航与窄窗口布局，让这条工作流可以连续使用。
    """
    static let result = """
    键盘导航与窄窗口布局已经完成，可以接着使用了。

    ### 本轮更新
    - **键盘导航**：保持原生焦点顺序，Escape 返回当前阅读页。
    - **窄窗口**：正文与操作区保留足够空间，长内容仍可滚动。
    - **阅读位置**：完成后进入这一轮结果，上一轮仍可重新阅读。

    改动已整理在独立 worktree，等待你查看。
    """
    static let more = """

    ### 交互细节
    原生文本支持选择和复制。滚动位置属于各自的 execution，交接动画不会把上一轮的阅读位置带入新结果。

    ### 布局说明
    标题、执行摘要、最终回复和完成时间保持相同的顺序。窗口变窄时，正文按可用宽度换行，垂直滚动继续由原生阅读组件负责。

    ### 后续检查
    1. 在长结果中向下滚动，查看文末的完成时间。
    2. 重新播放交接，比较普通速度与慢速。
    3. 打开减弱动态效果，观察直接交接后的阅读位置。

    ### 结果
    所有内容都是可重复使用的内存 fixture；再次播放会回到相同的上一轮与当前轮，方便比较。
    """
}

struct ExecutionDocument: View {
    let latest: Bool
    let longResult: Bool
    let sidecard: Bool
    let completed: Bool
    let token: String
    let ready: () -> Void

    private var executionID: JSONText { latest ? "execution-current" : "execution-previous" }
    private var title: String { latest ? "补齐键盘导航与窄窗口布局" : "整理 Thread 阅读体验" }
    private var answer: String {
        if sidecard && !completed { return "正在整理键盘导航和窄窗口布局。\n\n阅读页、侧卡片与返回路径已检查，正在准备本轮结果…" }
        return latest ? Fixture.result + (longResult ? Fixture.more : "") : Fixture.previous
    }
    private var turn: some View {
        ThreadDetailTurn(id: executionID,
            author: .object(["model": .text("GPT-6"), "effort": .text("high")]),
            rows: [.init(id: JSONText(executionID.string + "-reply"), kind: .content,
                node: AnyView(NativeMarkdownView(text: answer, openExternal: { _ in },
                    documentToken: token, onDocumentApplied: { document in
                        if document?.token == token { ready() }
                    })), finalReply: true)],
            createdAt: latest ? 1793869620000 : 1793869200000,
            updatedAt: 1793869740000, status: completed ? "已完成" : "运行中",
            completedAt: completed ? 1793869740000 : nil,
            usage: completed ? AnyView(ThreadTokenUsage(input: 12840, output: 2160)) : nil,
            active: !completed)
    }
    var body: some View {
        Group {
            if sidecard {
                HarnessMessageTimeline(timelineKey: "handoff-sidecard",
                    rows: [.init(id: executionID, createdAt: 0, node: AnyView(turn))],
                    toolbar: AnyView(HStack(spacing: 7) {
                        NativeIcon(name: completed ? "Check" : "Activity", size: 13)
                        Text(completed ? "执行已完成" : "执行中").font(NativeTypography.inter(size: 12, weight: 500))
                        Spacer()
                        Text("Codex").font(NativeTypography.mono(size: 11))
                    }.foregroundStyle(NativePalette.thread.muted.swiftUI).padding(.bottom, 12)),
                    contentTopInset: 12, allowsJumpToLatest: false, showOlderRows: false)
                    .environment(\.threadDetailVisibility, .init(work: true))
                    .padding(.vertical, 22)
            } else {
                ThreadConversation(threadId: latest ? "demo-latest" : "demo-previous", title: title,
                    icon: "🪄", rows: [.init(id: executionID, createdAt: 0,
                        execution: .init(id: executionID, title: title, prompt: "", answer: answer,
                            completedAt: 1793869740000), node: AnyView(turn))])
                    .environment(\.nativeThreadReservesHistoryRail, true)
                    .nativeReadingPanelViewport(topInset: 22)
            }
        }
        .environment(\.nativeThreadUsesLoadingSkeleton, false)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .font(NativeTypography.inter(size: 16))
        .foregroundStyle(NativePalette.thread.ink.swiftUI)
        .background(NativePalette.thread.canvas.swiftUI)
    }
}
