# 文档核查记录 · 2026-11-04

本记录是一次静态审计快照，不是持续有效的产品契约或测试通过凭证。
源码基线：`a77d3a354887eb054516e10d432f825378ca7c8a`（detached HEAD）。
工作树：`/Users/felixwang/Desktop/.Mokusei-mokusei-worktrees/refresh-project-docs`。
盘点采用 `git ls-files '*.md' '*.mdx'`，包括隐藏目录和 `CLAUDE.md`，共 **171** 个路径；
下表不含本记录自身。根目录、Go 模块、原生模块、构建/CI、交互工具、回放、demo、
设计调查、资源来源和仓库工作指引均进入清单。代码内注释、CLI 帮助和配置是核查依据；
生产 prompt、许可证和二进制素材不是本次重写对象。

用户追加 Spring Mode 后，本次不新增测试、不运行回归测试、不建 PR、不操作 main；
改动仅限 Markdown，提交留在此 detached worktree，由协调方统一整合。
本轮此前也没有运行回归测试，没有需要终止的测试进程。

整合补记：协调方随后纳入 `a83c221` 的全局搜索 oracle 修正与 `ffa0d78` 的
Headless 顺序链，并据此更新当前交互指南及 CI 说明。下文“待并行清理”描述保留为
原审计时点的依赖记录，不再表示当前 driver 仍有该旧断言。最终整合范围和验证限制见
[维护整合记录](maintenance-integration-2026-11-04.md)。

## 核查方法与覆盖

先阅读仓库指引、模块 README 和验证策略，再对照生产注册、接口、命令解析、配置与调用路径。
全库做文档分类、本地链接/锚点扫描、命令入口与显式路径检查；对下面列出的契约作重点源码核查。
清单中的“现行”不表示每句叙述均获得运行时证明；未修改文件也不自动视为已完整验证。

| 范围 | 主要依据与本次结论 |
| --- | --- |
| 全项目与构建 | [Makefile](../Makefile)、[devtool CLI](../internal/tooling/devtool/cli.go)、[Go bootstrap](../scripts/go.sh)、[Swift package](../app/macos/Package.swift)：入口、默认 Debug/Release、目标/资源、工具链与签名边界。根指南补充现行/历史文档的阅读边界。 |
| Go Core、插件宿主和模型 | [composition](../internal/core/composition/bootstrap.go)、[plugin contracts](../internal/core/plugin/)、[Runtime](../internal/core/runtime/)、[store](../internal/core/store/)、[hosts](../internal/hosts/)：注册、公开模型、持久化、配置与内容权属。未改领域词汇、协议或 schema。 |
| 服务与适配器 | [Moku composition](../internal/core/composition/moku.go)、[delivery](../internal/core/runtime/moku_delivery.go)、[search](../internal/services/threadsearch/query.go)、[workspaces](../internal/services/workspaces/manager.go)、[Harnesses](../internal/plugins/harness/)：生产通知持久化、keyword 搜索、detached worktree 与原生会话归属。 |
| 原生 UI 与生命周期 | [reading stack](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPageStack.swift)、[panel compositor](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelTransition.swift)、[Settings sections](../app/macos/Sources/Host/Settings/NativeSettingsNavigation.swift)、[Overview search](../app/macos/Sources/Host/Overview/NativeOverviewSearch.swift)、[Moku capsule](../app/macos/Sources/Host/MokuScene/NativeMokuCapsule.swift)：准备/呈现时机、关闭转场、可用页面、搜索范围和材质。 |
| 交互与回放指南 | [Overview driver](../tools/native-interaction/overview_chaos.py)、[reading driver](../tools/native-interaction/thread_chaos.py)、[replay launcher](../tools/verification/reading-presentation/run.py)、[CI replay groups](../scripts/ci/replays.py)：对照现存入口/分组/选项，区分 fixture 断言与产品保证。未执行这些 driver。 |
| 来源与历史 | [fonts](../app/macos/Sources/Shared/PluginUI/Resources/fonts/SOURCES.md)、[icons](../app/macos/Sources/Shared/PluginUI/Resources/icons/LUCIDE-SOURCES.md)、`design/`、evidence/results 与历史审计：保留版本、结论、数值、来源和原文；补足旧 Electron/npm 路径属于转换环境的说明。 |

## 有依据的修正

| 文档 | 原问题与修正依据 |
| --- | --- |
| [macOS 总览](../app/macos/README.md)、[WindowNavigation](../app/macos/Sources/Host/WindowNavigation/README.md) | 旧 65% 关闭交接已过时。`NativeReadingPanelTransition.startIfReady` 使用正文 keyTimes `[0, 0.8, 1]`、travel/scale `0.86` 和外壳 `[0, 0.86, 1]`；文档统一到 420ms 内 80%/86%/末 14%。 |
| WindowNavigation | 原文称 reader 必须等到到达才挂载。`preloadPanelReader` 与 `readerPreloading` 已允许普通 Agent 卡片在 native start 后隐藏准备；数据 prefetch 与 view preload 分别描述，呈现/输入仍受到达门控。 |
| [Overview](../app/macos/Sources/Host/Overview/README.md)、[交互矩阵](../tools/native-interaction/OVERVIEW.md) | Settings 已无归档恢复页面；`NativeSettingsNavigation.sections` 仅提供 General、Moku 与可用 Application sections。移除误导性的恢复指路，不推测新 UI。 |
| 交互矩阵、[Overview chaos](../tools/verification/overview-interaction/README.md) | 生产 `NativeOverviewSearch` 使用全局 eligible catalog，Runtime `Query` 返回 `keyword`。移除当前 scoped/hybrid 的产品描述，明确保留 driver 的旧断言仍待处理；同步无 context-menu 入口和目录/子标签分隔符说明。 |
| [reading controls](../tools/native-interaction/README.md)、[reading replay](../tools/verification/thread-interaction/README.md) | `thread_chaos.expand` 仅遍历实际挂载控件；Agent detail 的生产 reader 是 summary-only。fixture 内存在 reasoning/tool 数据不等于 UI 挂载了 disclosure 或获取了 execution detail。 |
| [材质 demo](../demos/moku-gradient-material/README.md)、[demo 目录](../demos/README.md)、[Overview fixture](../tools/verification/overview-input/README.md) | `NativeMokuCapsuleGlass` 强制 dark；demo 两列调用相同 clear 分支，旧浅色标签不是独立生产材质。Overview emoji badge 已是 opaque palette；修正“clear glass circle”验收指引。保留原提案目的与出处。 |
| [Overview 性能研究](../tools/verification/overview-performance/README.md) | 原场景矩阵含已退休的 glass on/off 条件。补充历史边界和当前入口，保留矩阵、历史数值与原结论。 |
| [Moku replay](../tools/verification/moku/README.md) | 原说明把生产通知写成无 durable retry 的内存队列。生产 `composition/moku.go` 注入 `PendingDeliveries`/`SendDelivery`，`coordinator.go` 仅在缺少 durable ports 时订阅 fallback；据此分开 lazy outbox 与 `user_thread_input.go` 的即时内存 fixture。 |
| [Moku recovery link](../tools/verification/release-health/README.md) 与 Moku replay | 修正两处失效锚点 `durable-completion-notifications`，指向实际 `durable-system-notifications`。 |
| [Store](../internal/core/store/README.md) | `platform/sqlite` 使用 `#cgo LDFLAGS: -lsqlite3`，Linux CI 也提供系统 SQLite；修正限定为 macOS system library 的表述。 |
| [Workspaces](../internal/services/workspaces/README.md) | `manager.go` 用 `git worktree add --detach`，并把 base cwd 的 subdirectory 拼入 execution cwd；补充不建 branch 和子目录保留语义。 |
| [CI](../scripts/ci/README.md)、[回放总览](../tools/verification/README.md) | 当前 `replays.py` 是 10 个 interop、12 个 native check（包括 runtime-build）。`make check-swift` 是 ordinary selection 后执行 native owners；旧审计的 8 个 XCTest skips 不是现行 inventory。正式 Overview 比较运行在 Actions runner。 |
| Tag morph、Note、Talk dismiss、Blink、voice cloud、Moku 与材质 demo 操作指南 | 默认 launcher 自行构建，或 `--skip-build` 仅需要当前 Debug 产物；用明确 build 前置条件取代不必要的全套 `make check` 前置要求，并沿用验证策略。仅修订命令说明，本轮没有执行这些构建/测试命令。 |
| 字体/图标来源 | 原生 package 已处理 7 个 TTF 和 141 个 Lucide lookup keys。注明旧 renderer/npm 路径是历史来源/转换 recipe，不是现行构建依赖；未改变来源、版本、许可声明、hash 或素材。 |

## 与并行清理的交叉点

这里记录的是本基线上的静态事实，不预判并行任务最终删除哪些文件：

- `tools/native-interaction/overview_chaos.py` 仍断言同名目录内搜索 `alpha` 不应命中另一目录，
  与当前全局搜索冲突；还保留非 keyword 分支。其两份指南已标注，不能据此声称搜索验收通过。
- `tools/native-interaction/thread_chaos.py` 和 `tools/verification/thread-interaction` 的历史 fixture
  包含工具/推理记录；若清理旧 disclosure 逻辑，需同步这两份 reading 指南和
  `tools/verification/reading-presentation/README.md` 的相关范围。本文没有删除记录或更改断言。
- `tools/verification/moku/user_thread_input.go` 与 `terminal_queue.go` 保留无 durable ports 的 fallback
  验证。生产 composition 不走直接用户输入订阅；删除/调整这些 fixture 时应同步 Moku replay 的
  fallback 覆盖说明，保留生产 outbox 的文档归属。
- `scripts/ci/replays.py`、`swift_ownership.py`、`swift-native.py`、`swift-tests.py` 和 Swift suites
  决定真实数量、owner 与 headless 选择。测试清理后复核 CI README、验证策略、`.agents/linting.md`、
  原生总览与 replay 总览中的数量/范围；不要把旧统计当作当前通过结果。
- `demos/README.md` 已标注的旧 `thread-card-cloud`、`tag-cloud-loading`、`thread-card-glass-timeline`
  依赖已移除的 `NativeContentHost.swift`；材质 demo 的浅色标签也已漂移。
  如并行任务删除旧源码/入口，应更新当前目录链接；历史 evidence、提案和数字保持原语境。
- `tools/verification/overview-glass/run.py` 已主动退出，旧参数只出现在明确退休的历史说明内；
  不将其恢复成当前命令，也不删除原研究记录。资源目录内的来源 Markdown 会被资源处理，
  保守 CI classifier 不能视其为快速路径。

## 验证与限制

本次允许并执行的验证是 diff/路径/本地链接及锚点审查、Python 命令选项的静态比对、
Makefile 与 CLI parser 阅读、工作树文件类型与 CI scope 判定。没有新增测试，也没有运行
`make check`、`make lint`、`swift test`、Go tests、功能回放、产品 build、签名包、GUI 或性能测量。
文档中保留的这些命令是供后续使用的说明，不是本次执行记录。

2026-11-04 只读查询远程规则：传统 branch protection endpoint 返回 404，但两条 active ruleset
仍要求 main PR、strict `Complete coverage`、review conversations resolved，required approvals 为 0。
不能把该 404 解释为没有保护。最初沙箱网络请求失败，随后授权网络查询成功。
最近读取的远程 main run `41475926061`（`8ca887b832aae6dd788781bb36df0b080533ba7f`）为 failure，
既不属于本次基线也不能认证本提交；本任务没有触发、重跑或取消 CI，没有 PR。

`scope.py` 只对白名单入口与 `.agents`/`scripts/ci` 直接 Markdown 给出文档快速路径。
本次含模块 README、工具指南和资源来源文档，实际 classifier 应输出
`documentation_only=false`，托管默认流程将要求完整检查。Spring Mode 下本轮不运行它们，
也不以本地文档检查替代门禁；最终 main 集成由协调方负责。

未核实：运行中的 UI/动画/焦点/硬件表现、原生 CLI/账号/模型服务和公网来源是否变化、
当前性能数字、历史 evidence 的重新复现，以及并行清理整合后的最终文件/覆盖数量。
本地链接检查证明目标存在，不证明外部网页可达或历史证据重新成立。
完整逐句行为证明超出本轮静态盘点；当前指南中未重点列出的复杂契约保留原文，
不得将本清单解释为对所有陈述的动态认证。并行任务合入后应复核这里列出的交叉文档。

文档检查结果：含本记录共 172 个 Markdown 路径，990 个本地链接、31 个 Markdown
锚点均找到目标；55 个外部链接仅分类、不访问。`git diff --check` 通过。
检查脚本仅位于临时目录，不作为仓库测试或生产代码提交。

## 逐文件清单

分类计数：历史 52、嵌入 1、工具 54、指引 9、提案 5、来源 3、混合 6、现行 41。
“历史/提案”检查记录性质和链接，不把当年的“当前”改成今天；“混合”保留基线并核查操作入口。

| 文档 | 类别 | 本轮核查边界 |
| --- | --- | --- |
| [.agents/issue-tracker.md](../.agents/issue-tracker.md) | 指引 | 入口、链接与本次约束 |
| [.agents/linting.md](../.agents/linting.md) | 指引 | 入口、链接与本次约束 |
| [.agents/skills/commit-message/SKILL.md](../.agents/skills/commit-message/SKILL.md) | 指引 | 入口、链接与本次约束 |
| [.agents/skills/grilling/SKILL.md](../.agents/skills/grilling/SKILL.md) | 指引 | 入口、链接与本次约束 |
| [.agents/skills/implement/SKILL.md](../.agents/skills/implement/SKILL.md) | 指引 | 入口、链接与本次约束 |
| [.agents/skills/to-spec/SKILL.md](../.agents/skills/to-spec/SKILL.md) | 指引 | 入口、链接与本次约束 |
| [.agents/skills/wait-what/SKILL.md](../.agents/skills/wait-what/SKILL.md) | 指引 | 入口、链接与本次约束 |
| [AGENTS.md](../AGENTS.md) | 指引 | 入口、链接与本次约束 |
| [CLAUDE.md](../CLAUDE.md) | 指引 | 入口、链接与本次约束 |
| [CONTEXT.md](../CONTEXT.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [README.md](../README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/README.md](../app/macos/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Sources/Core/README.md](../app/macos/Sources/Core/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Sources/Host/Git/README.md](../app/macos/Sources/Host/Git/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Sources/Host/Interaction/README.md](../app/macos/Sources/Host/Interaction/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Sources/Host/MokuScene/README.md](../app/macos/Sources/Host/MokuScene/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Sources/Host/Onboarding/README.md](../app/macos/Sources/Host/Onboarding/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Sources/Host/Overview/README.md](../app/macos/Sources/Host/Overview/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Sources/Host/Settings/README.md](../app/macos/Sources/Host/Settings/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Sources/Host/WindowNavigation/README.md](../app/macos/Sources/Host/WindowNavigation/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Sources/Plugins/Sidecards/README.md](../app/macos/Sources/Plugins/Sidecards/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Sources/Shared/PluginAPI/README.md](../app/macos/Sources/Shared/PluginAPI/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Sources/Shared/PluginUI/README.md](../app/macos/Sources/Shared/PluginUI/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Sources/Shared/PluginUI/Resources/fonts/SOURCES.md](../app/macos/Sources/Shared/PluginUI/Resources/fonts/SOURCES.md) | 来源 | 资源/来源路径；历史转换与现行构建区分 |
| [app/macos/Sources/Shared/PluginUI/Resources/icons/LUCIDE-SOURCES.md](../app/macos/Sources/Shared/PluginUI/Resources/icons/LUCIDE-SOURCES.md) | 来源 | 资源/来源路径；历史转换与现行构建区分 |
| [app/macos/Sources/Voice/README.md](../app/macos/Sources/Voice/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/Tests/NativeInputSupport/README.md](../app/macos/Tests/NativeInputSupport/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [app/macos/Tests/Support/README.md](../app/macos/Tests/Support/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [app/macos/build/README.md](../app/macos/build/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [app/macos/build/SOURCES.md](../app/macos/build/SOURCES.md) | 来源 | 资源/来源路径；历史转换与现行构建区分 |
| [app/macos/build/layout-logging.md](../app/macos/build/layout-logging.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [demos/README.md](../demos/README.md) | 工具 | 入口和生产复用边界；未启动 |
| [demos/landing-setup/README.md](../demos/landing-setup/README.md) | 提案 | 历史/独立 fixture 边界与替代入口 |
| [demos/moku-gradient-material/README.md](../demos/moku-gradient-material/README.md) | 工具 | 入口和生产复用边界；未启动 |
| [demos/moku-history-theme/README.md](../demos/moku-history-theme/README.md) | 工具 | 入口和生产复用边界；未启动 |
| [demos/moku-landing/README.md](../demos/moku-landing/README.md) | 工具 | 入口和生产复用边界；未启动 |
| [demos/moku-mention-transition/README.md](../demos/moku-mention-transition/README.md) | 工具 | 入口和生产复用边界；未启动 |
| [demos/moku-note-transition/README.md](../demos/moku-note-transition/README.md) | 工具 | 入口和生产复用边界；未启动 |
| [demos/moku-panel-transition/README.md](../demos/moku-panel-transition/README.md) | 工具 | 入口和生产复用边界；未启动 |
| [demos/moku-panel-transition/evidence/validation.md](../demos/moku-panel-transition/evidence/validation.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [demos/moku-thinking-orbit/README.md](../demos/moku-thinking-orbit/README.md) | 工具 | 入口和生产复用边界；未启动 |
| [demos/overview-thread-search/README.md](../demos/overview-thread-search/README.md) | 工具 | 入口和生产复用边界；未启动 |
| [demos/settings-navigation/README.md](../demos/settings-navigation/README.md) | 工具 | 入口和生产复用边界；未启动 |
| [demos/settings-tabs/README.md](../demos/settings-tabs/README.md) | 提案 | 历史/独立 fixture 边界与替代入口 |
| [demos/tag-filter-morph/README.md](../demos/tag-filter-morph/README.md) | 工具 | 入口和生产复用边界；未启动 |
| [demos/tag-glass-morph/README.md](../demos/tag-glass-morph/README.md) | 提案 | 历史/独立 fixture 边界与替代入口 |
| [demos/tag-selection-preview/README.md](../demos/tag-selection-preview/README.md) | 提案 | 历史/独立 fixture 边界与替代入口 |
| [demos/thread-card-cloud/README.md](../demos/thread-card-cloud/README.md) | 提案 | 历史/独立 fixture 边界与替代入口 |
| [demos/thread-panel-transition/README.md](../demos/thread-panel-transition/README.md) | 工具 | 入口和生产复用边界；未启动 |
| [design/agent-detail-dark-tone.md](../design/agent-detail-dark-tone.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/card-status-layout-shift.md](../design/card-status-layout-shift.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/detail-background-optimization.md](../design/detail-background-optimization.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/emoji-title-transition-handoff.md](../design/emoji-title-transition-handoff.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/empty-execution-summary.md](../design/empty-execution-summary.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/markdown-layout-performance.md](../design/markdown-layout-performance.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/markdown-repeat-visit-performance.md](../design/markdown-repeat-visit-performance.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/moku-talk-note-handoff.md](../design/moku-talk-note-handoff.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/moku-talk-note-transition.md](../design/moku-talk-note-transition.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/note-read-awareness-implementation.md](../design/note-read-awareness-implementation.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/note-read-awareness.md](../design/note-read-awareness.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/reading-entrance-choreography.md](../design/reading-entrance-choreography.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/reading-placeholder-alignment.md](../design/reading-placeholder-alignment.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/sidecard-fold-performance.md](../design/sidecard-fold-performance.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/terminal-assistant-disclosure.md](../design/terminal-assistant-disclosure.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/thread-attachment-ownership.md](../design/thread-attachment-ownership.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/thread-detail-input-dismissal.md](../design/thread-detail-input-dismissal.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/thread-loading-performance-cache.md](../design/thread-loading-performance-cache.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/thread-open-animation-investigation.md](../design/thread-open-animation-investigation.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/thread-open-window-backdrop.md](../design/thread-open-window-backdrop.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/thread-opening-admission.md](../design/thread-opening-admission.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/thread-opening-entry-admission.md](../design/thread-opening-entry-admission.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/thread-overview-isolation.md](../design/thread-overview-isolation.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/thread-scroll-observation.md](../design/thread-scroll-observation.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [design/thread-transition-latency.md](../design/thread-transition-latency.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [internal/README.md](../internal/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/core/model/README.md](../internal/core/model/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/core/plugin/README.md](../internal/core/plugin/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/core/runtime/README.md](../internal/core/runtime/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/core/store/README.md](../internal/core/store/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/hosts/applicationhost/README.md](../internal/hosts/applicationhost/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/hosts/contexthost/README.md](../internal/hosts/contexthost/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/platform/daemon/README.md](../internal/platform/daemon/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/platform/discovery/README.md](../internal/platform/discovery/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/platform/profile/README.md](../internal/platform/profile/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/platform/transport/README.md](../internal/platform/transport/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/plugins/README.md](../internal/plugins/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/plugins/applications/git/README.md](../internal/plugins/applications/git/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/plugins/applications/report/README.md](../internal/plugins/applications/report/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/plugins/applications/report/eli5-skill.md](../internal/plugins/applications/report/eli5-skill.md) | 嵌入 | 生产 prompt 输入，保持原文 |
| [internal/plugins/applications/tag/README.md](../internal/plugins/applications/tag/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/plugins/contexts/artificialanalysis/README.md](../internal/plugins/contexts/artificialanalysis/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/plugins/harness/claude/README.md](../internal/plugins/harness/claude/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/plugins/harness/codex/README.md](../internal/plugins/harness/codex/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/plugins/harness/opencode/README.md](../internal/plugins/harness/opencode/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/plugins/harness/pi/README.md](../internal/plugins/harness/pi/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/services/attachments/README.md](../internal/services/attachments/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/services/moku/README.md](../internal/services/moku/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/services/threadsearch/README.md](../internal/services/threadsearch/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/services/threadvoice/README.md](../internal/services/threadvoice/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [internal/services/workspaces/README.md](../internal/services/workspaces/README.md) | 现行 | 模块职责/入口与重点契约源码对照；非逐句动态验收 |
| [scripts/ci/README.md](../scripts/ci/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [scripts/ci/flaky-review.md](../scripts/ci/flaky-review.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [scripts/ci/headless.md](../scripts/ci/headless.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [scripts/ci/self-hosted.md](../scripts/ci/self-hosted.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [scripts/ci/verification-policy.md](../scripts/ci/verification-policy.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/native-interaction/OVERVIEW.md](../tools/native-interaction/OVERVIEW.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/native-interaction/README.md](../tools/native-interaction/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/README.md](../tools/verification/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/artificialanalysis/README.md](../tools/verification/artificialanalysis/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/claude/README.md](../tools/verification/claude/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/cloud-motion/README.md](../tools/verification/cloud-motion/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/codex/README.md](../tools/verification/codex/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/devtools/README.md](../tools/verification/devtools/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/moku-appearance/README.md](../tools/verification/moku-appearance/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/moku-blink/README.md](../tools/verification/moku-blink/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/moku-note-performance/README.md](../tools/verification/moku-note-performance/README.md) | 混合 | 操作入口与历史基线/测量分开核查 |
| [tools/verification/moku-note/README.md](../tools/verification/moku-note/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/moku-reasoning/README.md](../tools/verification/moku-reasoning/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/moku-system/README.md](../tools/verification/moku-system/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/moku-talk-dismiss/README.md](../tools/verification/moku-talk-dismiss/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/moku-transitions/README.md](../tools/verification/moku-transitions/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/moku-voice-cloud/README.md](../tools/verification/moku-voice-cloud/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/moku/README.md](../tools/verification/moku/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/native-interaction/README.md](../tools/verification/native-interaction/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/opencode/README.md](../tools/verification/opencode/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/overview-ci-performance/README.md](../tools/verification/overview-ci-performance/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/overview-ci-performance/runtime/README.md](../tools/verification/overview-ci-performance/runtime/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/overview-glass/README.md](../tools/verification/overview-glass/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/overview-glass/REPORT.md](../tools/verification/overview-glass/REPORT.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-input/PERFORMANCE.md](../tools/verification/overview-input/PERFORMANCE.md) | 混合 | 操作入口与历史基线/测量分开核查 |
| [tools/verification/overview-input/README.md](../tools/verification/overview-input/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/overview-input/evidence/glass-completion/README.md](../tools/verification/overview-input/evidence/glass-completion/README.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-input/evidence/glass-completion/run-3/summary.md](../tools/verification/overview-input/evidence/glass-completion/run-3/summary.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-input/evidence/glass-completion/run-4/summary.md](../tools/verification/overview-input/evidence/glass-completion/run-4/summary.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-input/evidence/glass-completion/run-5/summary.md](../tools/verification/overview-input/evidence/glass-completion/run-5/summary.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-input/evidence/moku-dock-refresh/README.md](../tools/verification/overview-input/evidence/moku-dock-refresh/README.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-interaction/README.md](../tools/verification/overview-interaction/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/overview-layout/BALANCE.md](../tools/verification/overview-layout/BALANCE.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-layout/README.md](../tools/verification/overview-layout/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/overview-layout/RESULTS.md](../tools/verification/overview-layout/RESULTS.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-layout/SECOND-SCREENSHOT.md](../tools/verification/overview-layout/SECOND-SCREENSHOT.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-performance/README.md](../tools/verification/overview-performance/README.md) | 混合 | 操作入口与历史基线/测量分开核查 |
| [tools/verification/overview-performance/RESULTS.md](../tools/verification/overview-performance/RESULTS.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-performance/SUMMARY.md](../tools/verification/overview-performance/SUMMARY.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-performance/evidence/baseline/summary.md](../tools/verification/overview-performance/evidence/baseline/summary.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-performance/evidence/glass-run-3/summary.md](../tools/verification/overview-performance/evidence/glass-run-3/summary.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-performance/evidence/round1/summary.md](../tools/verification/overview-performance/evidence/round1/summary.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-performance/evidence/round2/summary.md](../tools/verification/overview-performance/evidence/round2/summary.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-performance/evidence/round3/summary.md](../tools/verification/overview-performance/evidence/round3/summary.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/overview-text/README.md](../tools/verification/overview-text/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/pi/README.md](../tools/verification/pi/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/plugin-audit/README.md](../tools/verification/plugin-audit/README.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/reading-presentation/README.md](../tools/verification/reading-presentation/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/reading-presentation/evidence/subtag-ax-isolation.md](../tools/verification/reading-presentation/evidence/subtag-ax-isolation.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/reading-presentation/evidence/subtag-transition-speed.md](../tools/verification/reading-presentation/evidence/subtag-transition-speed.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/reading-presentation/evidence/switch-clipping.md](../tools/verification/reading-presentation/evidence/switch-clipping.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/reading-presentation/evidence/vertical-transition.md](../tools/verification/reading-presentation/evidence/vertical-transition.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/release-health/README.md](../tools/verification/release-health/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/runtime-performance/AUDIT.md](../tools/verification/runtime-performance/AUDIT.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/runtime-performance/HANDOFF.md](../tools/verification/runtime-performance/HANDOFF.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/runtime-performance/README.md](../tools/verification/runtime-performance/README.md) | 混合 | 操作入口与历史基线/测量分开核查 |
| [tools/verification/runtime-performance/results/20261025/README.md](../tools/verification/runtime-performance/results/20261025/README.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/scrollbars/README.md](../tools/verification/scrollbars/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/settings-performance/README.md](../tools/verification/settings-performance/README.md) | 混合 | 操作入口与历史基线/测量分开核查 |
| [tools/verification/swift-tests/README.md](../tools/verification/swift-tests/README.md) | 历史 | 识别基线/记录性质，检查链接；保留原结论 |
| [tools/verification/swiftfixture/README.md](../tools/verification/swiftfixture/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/thread-detail-performance/README.md](../tools/verification/thread-detail-performance/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/thread-detail-performance/integration.md](../tools/verification/thread-detail-performance/integration.md) | 混合 | 操作入口与历史基线/测量分开核查 |
| [tools/verification/thread-interaction/README.md](../tools/verification/thread-interaction/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/thread-search/README.md](../tools/verification/thread-search/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
| [tools/verification/transport/README.md](../tools/verification/transport/README.md) | 工具 | 命令/路径/范围静态核对；未运行回归 |
