# 当前 tag space 的 Super Thread 收纳预算

**阅读资格决定哪些报告可以收，当前视图的 16 格软预算决定收几份。** 在 All 中，10 张单格任务卡和 4 份带封面的报告共占 18 格。若四份报告都合格，最早的两份共用一张 2 格 Collection，正好剩 16 格。切到只包含其中 8 张任务卡的标签，四份报告又能各自展示。[预算算法](../../app/macos/Sources/Host/Overview/NativeOverviewCollectionBudget.swift) · [Overview 工程手册](../../app/macos/Sources/Host/Overview/README.md#viewed-application-collections)

## 先确定视图成员和阅读资格

本次设计核对的源码基线为 `5ec282f5852c4f2cd8867821b64e869aff2032b1`。空间选择、阅读证据和卡片尺寸分别有自己的来源。

| 依据 | 规则 |
| --- | --- |
| 当前 tag space | All、目录、目录内的语义标签和 Inbox 的语义标签各自取成员，同名标签按目录范围区分。先筛选可见且未归档的成员，再用当前视图里的报告覆盖其引用的精确执行。例如报告引用任务的 E1，而最新执行已是 E2，任务可以重新单列并计入预算。[成员选择与执行覆盖](../../app/macos/Sources/Host/Overview/NativeOverviewSelection.swift#L384-L417) |
| 初次获得资格 | 已保留资格，或自上次实际关闭起经过**严格大于 300 秒**，满足其一即可。首次在 10:00:00 关闭，10:05:00 仍单列，10:05:01 已可成为候选。缺失或在未来的关闭时间无法满足经过时间条件。打开会清掉旧关闭时间。[关闭间隔](../../app/macos/Sources/Shared/PluginAPI/ApplicationOverviewCollection.swift#L16-L22) · [资格判定](../../app/macos/Sources/Host/Overview/NativeOverviewWorkspaceModel.swift#L338-L341) |
| 回访 | 已合格的报告在一次访问中累计前台阅读恰好 120 秒仍保留资格，超过 120 秒才清除，关闭后重新等待。失焦、覆盖、界面尚未就绪和断连会暂停计时。普通任务若唯一归属某份报告，阅读该任务也归到这份报告，按 Thread 身份认领。报告与其关联任务之间可延续同次访问，轮播翻页只改变选中项。[阅读归属与时长](../../app/macos/Sources/Host/Overview/NativeOverviewWorkspaceModel.swift#L249-L320) · [前台条件](../../app/macos/Sources/Host/Shell/NativeWorkspaceView.swift#L370-L394) |
| 报告更新 | 已知指纹发生变化会撤销旧关闭时间和保留资格。指纹包括标题、正文和封面版本、emoji、简介、精确执行引用集合。标签传播和来源执行状态变化本身保留阅读证据。阅读记录按本机 profile 和真实报告身份保存，所有视图共享。[Report 指纹](../../app/macos/Sources/Plugins/Applications/Report/NativeReportApplication.swift#L28-L39) · [指纹核对](../../app/macos/Sources/Host/Overview/NativeOverviewWorkspaceModel.swift#L343-L363) |
| 实际占格 | 每张卡占其独立投影的列数乘行数。有封面的报告为 1×2，无封面为 1×1，Collection 固定为 1×2。普通任务取 Harness 组合后的跨度，Git 或待处理交互可以改变大小。[Report 投影](../../app/macos/Sources/Plugins/Applications/Report/NativeReportApplication.swift#L25-L51) · [任务卡组合](../../app/macos/Sources/Shared/PluginUI/Cards/ThreadCardComposer.swift#L34-L47) |

## 超过预算时收哪几份

以筛选和覆盖完成后的**全部独立卡**计算展开占格 `A`，包括已平移到窗口外的卡。若 `A ≤ 16`，全部单列。只有实际阅读合格的报告进入候选，按创建时间从早到晚排列，同一创建时间沿用 catalog 的稳定顺序。用创建顺序能给近期产出保留直接入口，短回访改变关闭时间也不会打乱顺序。

超预算时，设 `S(k)` 为最早的 `k` 份候选单列时的占格和，`G` 为插件声明的合集占格。选第一个满足 **`k ≥ 2 且 A − S(k) + G ≤ 16`** 的前缀。跨度混合时，先收较早报告可能比优先挑大卡多收一份。如果收完所有候选仍超预算，只要至少两份且净省格数为正，就收下全部候选并允许剩余溢出。只有一份或合并省不出格子时，各自单列。

Host 每次都从展开输入计算。例如 18 格已收成 16 格，下一次相同投影仍从 18 格起算。集合身份由类型与当前浏览空间确定，占据最早被收成员的排序位置，快照、页数和返回映射只包含实际选中的成员。普通任务已经占满 16 格时，继续累计任务占格已无助于决定收几份，可以提前结束求和。当前仅 Report 声明收纳策略。若有多个类型参与，按每种类型首个合格成员出现的次序，共用同一视图的剩余超额。[完整投影与分组](../../app/macos/Sources/Host/Overview/NativeOverviewWorkspaceModel.swift#L705-L813)

## 占格算例

A、B、C、D 按创建时间从早到晚排列，均带封面。任务数已经扣除了被报告覆盖的执行。

| 场景 | 展开占格 | 显示结果 |
| --- | ---: | --- |
| “导出”标签有 8 张单格任务卡，A–D 都合格 | 8 + 4×2 = 16 | 四份报告各自展示。 |
| 切到 All，多出 1 张单格任务卡 | 9 + 4×2 = 17 | 收 A、B，17 − 4 + 2 = **15**。C、D 单列。切回“导出”时四份报告重新展开。 |
| All 有 10 张任务卡，其中一张因 Git 扩展为 2×1 | 9 + 2 + 4×2 = 19 | 只收 A、B 会剩 17 格，收 A、B、C 后是 **15** 格，D 单列。 |
| All 有 10 张单格任务卡，A 的正文刚更新 | 10 + 4×2 = 18 | A 退出候选，收 B、C 后为 **16** 格。更新后的 A 可以直接打开。 |
| 15 张单格任务卡，A、B 合格，C 首次生成 | 15 + 3×2 = 21 | 收 A、B 后仍有 **19** 格，C 单列。若 B 也失去资格，只剩 A 一份候选，全部展开为 21 格。 |
| 15 张单格任务卡和两份合格的无封面报告 | 15 + 2×1 = 17 | 合集占 2 格，净省 0 格，全都单列。换成 14 张任务卡和三份无封面合格报告，同样从 17 格起算，收三份后恰好 **16** 格。 |

4×4 表示 16 格内容面积。有封面的报告占两格，八份这样的报告正好占满预算，仍各自展示。基格为 320×196 pt、间距为 16 pt。实际行列由布局求解器决定，用户可以平移查看窗口外的卡片。[网格尺寸](../../app/macos/Sources/Shared/PluginUI/Design/NativePalette.swift#L75-L80) · [布局求解器](../../app/macos/Sources/Host/Overview/NativeOverviewLayout.swift#L144-L195)

## 更新与验证

切换筛选、成员或执行覆盖变化、单卡跨度变化、阅读资格到期或失效时，完整投影按当前空间决定成员。普通文本更新可直接刷新卡片，增量路径拿到的少数变动卡片不能充当整个视图的占格。稀疏视图无需为收纳启动到期计时器。读 A 期间若展开占格从 18 降到 16，短访后 A 仍合格，返回目标却是 A 的独立卡。可观察字段 `eligible` 表示阅读资格，`collected` 表示在本视图实际收纳。[增量更新](../../app/macos/Sources/Host/Overview/NativeOverviewWorkspaceModel.swift#L591-L624) · [返回目标](../../app/macos/Sources/Host/Shell/NativeWorkspaceView.swift#L294-L309) · [资格与收纳观察](../../app/macos/Sources/Host/Overview/NativeOverviewWorkspaceModel.swift#L370-L381)

预算属性独立枚举合法前缀，依次比较剩余超额和收进集合的报告数。隔离桌面回放通过实际打开、关闭和五分钟到期，在 All 与较小目录间切换，再从合集打开成员并返回。上表为规则算例，原生交互的实测范围以回放清单和对应提交的运行制品为准。[PBT 清单](../../tools/verification/pbt/README.md) · [E2E 场景](../../tools/e2e/README.md#current-scenario-contract)
