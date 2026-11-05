import Foundation

struct ReportFixture {
    let emoji: String
    let title: String
    let shortDescription: String
    let executions: [ExecutionFixture]
    var harnesses: [FixtureHarness] {
        FixtureHarness.allCases.filter { harness in executions.contains { $0.harness == harness } }
    }

    static let sample = ReportFixture(
        emoji: "📊", title: "Report 与 Tag 工具留存分析",
        shortDescription: "对照两个后台 Agent 的工具调用记录，梳理调用频次、成功情况与统计边界。",
        executions: [
            ExecutionFixture(id: "report-audit", harness: .codex, emoji: "🔎", title: "审查 Report Agent 工具调用频率",
                role: "Report Agent", time: "11 月 4 日 · 16:42", usage: "80.7K",
                prompt: "审查 Mokusei 目录下 Report Agent 留存的工具调用记录，统计调用频次与成功情况，说明数据范围。",
                answer: """
                ## Report Agent 调用概况

                本次只统计绑定到 **Mokusei** 目录的留存记录，共找到 **104 次工具调用**。

                - 成功：93 次
                - 失败：11 次
                - 未决：0 次

                ### 调用集中在读取与整理

                `read_thread` 调用了 28 次，`get_thread_status` 调用了 22 次。两者合计 50 次，占当前样本的近一半。

                报告写入方面，`create_report` 为 20 次，`update_report` 为 6 次。另有 18 次生命周期读取，用于补齐执行前后的状态。

                ### 统计边界

                这是一份**持久化留存样本**，不代表所有历史调用。失败结果保留在统计中，不能只根据最终报告是否生成来判断执行成功。

                ### 结论

                Report Agent 的工作以读取上下文和整理报告为主。后续对比应保持相同的目录范围、时间窗口和留存规则。
                """),
            ExecutionFixture(id: "tag-audit", harness: .claude, emoji: "🏷️", title: "调查 Tag Agent 概览调用依赖成因",
                role: "Tag Agent", time: "11 月 4 日 · 17:08", usage: "86.8K",
                prompt: "调查 Tag Agent 为什么依赖概览上下文，并整理 Mokusei 目录下留存的工具调用样本。",
                answer: """
                ## Tag Agent 调用概况

                在两份可按目录核实的持久化会话中，共记录 **124 次调用、72 个批次**，记录的工具错误为 0。

                ### 主要工作是调整标签

                `set_thread_tags` 调用了 98 次；`read_overview_context` 为 19 次；`create_tags` 为 7 次。

                ### 为什么读取概览

                标签整理需要理解当前目录已有的命名与归类方式。概览上下文提供跨 Thread 的信息，帮助 Agent 判断应复用哪些标签。

                ### 不同样本不能直接比较

                记录时间跨 11 月 2 日与 4 日。另有 4 次失败执行，**不能等同于工具错误**，也不能和 Report Agent 的 11 次工具调用失败直接相加。

                ### 结论

                调用量主要来自标签写入；理解概览上下文是这些写入的前置步骤。当前样本只适合说明调用结构。
                """)])
}

struct ExecutionFixture: Identifiable, Equatable {
    let id: String
    let harness: FixtureHarness
    let emoji, title, role, time, usage, prompt, answer: String
}

enum FixtureHarness: String, CaseIterable {
    case codex = "Codex", claude = "Claude"
}

extension ReportFixture {
    static var groupedSample: ReportFixture {
        var executions = sample.executions
        for (index, harness) in [FixtureHarness.codex, .codex, .claude].enumerated() {
            let source = sample.executions.first { $0.harness == harness }!
            executions.append(.init(id: "source-\(index)", harness: harness, emoji: source.emoji,
                title: source.title + " · \(index + 2)", role: source.role, time: source.time,
                usage: source.usage, prompt: source.prompt, answer: source.answer))
        }
        return .init(emoji: sample.emoji, title: sample.title, shortDescription: sample.shortDescription, executions: executions)
    }
}
