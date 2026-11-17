# 当前事实与验证索引

本索引连接事实的所属文档、生产边界和验证证据；规格正文仍在所属文档。
实现证据指向当前仓库的产品与基建源码，不包含外部工作树或未落地能力。
完整入口和证据界限见[逐文档覆盖表](coverage.md)。Git 保存变更与设计历史。

## 验证主责与当前能力

| 主责 | 边界 | 此源码的实际能力 |
| --- | --- | --- |
| PBT | Moku runtime 的准入、状态、不变量、取消及持久性 | 没有配置 PBT runner/属性套件；源码契约不等于属性已验证 |
| e2e | 用户交互及跨组件/协议流程 | 有生产语义交互入口和独立 demo，没有配置交互断言 gate；fixture 不认证真实持久化/发送 |
| benchmark | 用户体验：打开/滚动/输入响应、输出时交互、资源开销 | 有独立外部采集、内部 CPU probe 和显式 dispatch 的 Release 比较；存在采集/归因限制，没有必需的统计回归 gate |
| 构建/静态 | 格式、依赖、注册、vet、Go/Swift 编译 | Makefile 与 CI 可执行；`Complete coverage` 仅聚合这些检查，不是行为覆盖率 |

普通单测不是验证 boundary。额外 PBT 必须说明独有缺陷覆盖与补充理由，不能替代主责。
没有实现或没有证据的覆盖保持明确缺口；`blocked`、`skipped`、未运行和其他提交结果不算通过。

## 事实所有者

这些 ID 是链接键，不复制正文规格。每项“源码核对”只建立实现依据，均不宣称动态验证通过。

| ID | 所属文档与当前事实边界 | 实现证据 | 验证关系 / 当前缺口 |
| --- | --- | --- | --- |
| `moku-admission` | [Moku](../internal/services/moku/README.md)、[Runtime](../internal/core/runtime/README.md)：配置、执行准入、lazy delivery、确定未消费的重试 | [coordinator.go](../internal/services/moku/coordinator.go)、[threads.go](../internal/core/runtime/threads.go)、[moku_delivery.go](../internal/core/runtime/moku_delivery.go) | PBT 主责；本树无属性 runner；不以构建认证重试/取消 |
| `moku-tools` | [Moku 工具](../internal/services/moku/README.md#tools-and-creation)：真实 schema、`ask_thread`、Talk/Timer/Note 边界 | [tools.go](../internal/services/moku/tools.go)、[tool_schema.go](../internal/services/moku/tool_schema.go)、[prompt.go](../internal/services/moku/prompt.go) | PBT / 协议 e2e；模型遵守指令不由 schema 或源码审查保证 |
| `native-catalog` | [目录准入](../internal/services/moku/catalog-evidence.md)：非空完整原生枚举、未知来源、缓存与再次准入 | [discovery](../internal/platform/discovery/)、[tool_schema.go](../internal/services/moku/tool_schema.go) | PBT 可补充缓存不变量并说明理由；真实账户/安装验证无当前证据 |
| `store-lifecycle` | [Store](../internal/core/store/README.md)：事务、快照、事件、receipt、drain | [store.go](../internal/core/store/store.go)、[sqlite.go](../internal/core/store/sqlite.go)、[snapshot.go](../internal/core/store/snapshot.go)、[lifecycle.go](../internal/core/store/lifecycle.go) | Moku runtime PBT 依赖；[CPU probe](../tools/verification/runtime-performance/README.md)仅测限定调用 |
| `transport-client` | [transport](../internal/platform/transport/README.md)、[Core](../app/macos/Sources/Core/README.md)：版本、帧、租约、delta、命令回执 | [protocol.go](../internal/platform/transport/protocol.go)、[content.go](../internal/platform/transport/content.go)、[RuntimeProtocol.swift](../app/macos/Sources/Core/RuntimeProtocol.swift)、[RuntimeCommandJournal.swift](../app/macos/Sources/Core/RuntimeCommandJournal.swift) | 跨 Go/Swift e2e；没有配置互操作断言 replay |
| `profile-attachments` | [profile](../internal/platform/profile/README.md)、[附件](../internal/services/attachments/README.md)、[工作区](../internal/services/workspaces/README.md)：进程/草稿/回执 owner 与 collection | [profile](../internal/platform/profile/)、[attachments](../internal/services/attachments/)、[workspaces](../internal/services/workspaces/)、[RuntimeProfileClientLease.swift](../app/macos/Sources/Core/RuntimeProfileClientLease.swift) | e2e；并发/异常清理无动态认证；不能按年龄推断 owner 消失 |
| `application-scope` | [Application host](../internal/hosts/applicationhost/README.md)、[Report](../internal/plugins/applications/report/README.md)、[Tag](../internal/plugins/applications/tag/README.md)：scope、CAS、后台批次、绑定与 archive | [applicationhost](../internal/hosts/applicationhost/)、[report](../internal/plugins/applications/report/)、[tag](../internal/plugins/applications/tag/)、[runner.go](../internal/plugins/applications/background/runner.go) | e2e；Moku runtime PBT 可引用其事件边界，额外 PBT 需说明独有缺陷覆盖；CPU list measurement 不证明事务隔离或模型报告质量 |
| `reader-lifecycle` | [阅读机制](../design/reading.md)：准备/绘制/输入门槛、缓存、历史标题、Sidecard/Report return | [NativeReadingParentSurface.swift](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingParentSurface.swift)、[RuntimeReadingRetention.swift](../app/macos/Sources/Core/RuntimeReadingRetention.swift)、[NativeHarnessThreadSurface.swift](../app/macos/Sources/Host/HarnessHost/NativeHarnessThreadSurface.swift) | e2e；[reading benchmark](../tools/benchmarks/reading/README.md)只观测指定 checkpoint/滚动 |
| `composer-identity` | [输入归属](../design/composer.md)、[MokuScene](../app/macos/Sources/Host/MokuScene/README.md)：草稿、单动作席、focus、receipt、Report 输入禁入 | [NativeWorkspaceView.swift](../app/macos/Sources/Host/Shell/NativeWorkspaceView.swift)、[NativeMokuDock.swift](../app/macos/Sources/Host/MokuScene/NativeMokuDock.swift)、[NativeExecutionContinuation.swift](../app/macos/Sources/Host/Shell/NativeExecutionContinuation.swift) | e2e；独立 preview 不证明 Runtime 发送或 uncertain receipt 恢复 |
| `note-exposure` | [Note 曝光](../design/note-exposure.md)：确切版本覆盖与 Runtime 原文回执 | [NativeMokuNote.swift](../app/macos/Sources/Host/MokuScene/NativeMokuNote.swift)、[command_validation.go](../internal/core/model/command_validation.go)、[moku.go](../internal/core/runtime/moku.go) | Moku runtime PBT + UI/协议 e2e；[Note probe](../tools/verification/moku-note-performance/README.md)不认证回执到达 |
| `overview-layout` | [Overview](../app/macos/Sources/Host/Overview/README.md)、[布局/封面](../design/overview.md)：414×253 网格、FitAll、最新身份、collection | [NativeOverviewLayout.swift](../app/macos/Sources/Host/Overview/NativeOverviewLayout.swift)、[NativeOverviewCamera.swift](../app/macos/Sources/Host/Overview/NativeOverviewCamera.swift)、[NativeReportCollection.swift](../app/macos/Sources/Plugins/Applications/Report/NativeReportCollection.swift)、[NativeReportCover.swift](../app/macos/Sources/Plugins/Applications/Report/NativeReportCover.swift) | e2e / benchmark；额外几何 PBT 需说明理由；无当前几何属性 gate |
| `markdown` | [Markdown](../design/markdown.md)、[PluginUI](../app/macos/Sources/Shared/PluginUI/README.md)：UTF-8、宽度、原生 viewport、稳定 renderer | [NativeMarkdownSourceMap.swift](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownSourceMap.swift)、[NativeMarkdownText.swift](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownText.swift)、[NativeMarkdownCodeViewport.swift](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownCodeViewport.swift) | e2e / reading benchmark；未认证完整语法/选择/剪贴板，额外解析 PBT 需说明理由 |
| `settings-onboarding` | [Settings](../app/macos/Sources/Host/Settings/README.md)、[Onboarding](../app/macos/Sources/Host/Onboarding/README.md)：readiness、draft、CAS、离线偏好、IME | [NativeSettingsDraft.swift](../app/macos/Sources/Host/Settings/NativeSettingsDraft.swift)、[NativeOnboardingSurface.swift](../app/macos/Sources/Host/Onboarding/NativeOnboardingSurface.swift)、[RuntimeSettingsReads.swift](../app/macos/Sources/Core/RuntimeSettingsReads.swift) | e2e；本树无 Go-backed Settings flow；demo 数据不认证保存 |
| `native-motion` | [动效](../design/motion.md)：普通时序、可见性/取消、Reduce Transparency、主线程与呈现边界 | [NativeOverviewCloudRenderer.swift](../app/macos/Sources/Shared/PluginUI/Design/NativeOverviewCloudRenderer.swift)、[NativeReadingPanelTransition.swift](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelTransition.swift) | e2e / benchmark；生产回调、GPU submission 或 display tick 不等于物理 FPS |
| `external-ux` | [外部 benchmark](../tools/benchmarks/README.md)、[reading](../tools/benchmarks/reading/README.md)：公开 fixture、输入、像素与资源口径 | [benchmark.py](../tools/benchmarks/benchmark.py)、[reading](../tools/benchmarks/reading/) | benchmark；native hitch 不可用，descendant/exit accounting 不完整，无统计回归 gate |
| `hosted-measurement` | [Release CI 比较](../tools/verification/overview-ci-performance/README.md)：固定双 SHA、共享 harness、时钟、队列、AB/BA | [overview-performance.yml](../.github/workflows/overview-performance.yml)、[run.py](../tools/verification/overview-ci-performance/run.py)、[main.go](../tools/verification/overview-ci-performance/runtime/main.go) | 显式 dispatch 测量有效性；绿色不代表候选更快，也不替代 e2e |
| `business-evidence` | [业务证据](../internal/README.md#business-evidence)、[启动与退出](../app/macos/build/README.md#development-and-watching-main)：业务历史、事件、回执、usage 与一次性启动回执 | [transcript.go](../internal/services/moku/transcript.go)、[telemetry.go](../internal/services/moku/telemetry.go)、[launch.go](../internal/tooling/devtool/launch.go)、[NativeProcessExit.swift](../app/macos/Sources/App/NativeProcessExit.swift) | e2e / Moku runtime PBT；私有日志不作为观测通道；启动回执/退出时序及 usage 持久性没有本树动态认证 |
| `build-scope` | [CI](../scripts/ci/README.md)、[打包](../app/macos/build/README.md)、[本地检查](../.agents/linting.md) | [Makefile](../Makefile)、[ci.yml](../.github/workflows/ci.yml)、[scope.py](../scripts/ci/scope.py)、[devtool](../internal/tooling/devtool/) | 非行为检查；Markdown 并非全部命中文档快速路径；实际远程门禁需独立读取 |

## 基建记录规则

每个实际属性、场景或性能判据在其所属基建入口保留一条映射：

`事实文档路径#位置 → 属性/场景/指标及判据 → 实现边界 → 固定提交与制品/seed/轨迹/样本 → 有效性与判定`

这里定义的是本项目的记录流程，不声明尚不存在的 runner 已实现。
属性记录生成域、不变量、seed/缩减反例；e2e 记录真实交互入口、前置条件、
可观察结果与环境；benchmark 记录工作负载、单位、预算/比较规则、采集能力、
源/制品/采集器身份和原始样本。只有文档中的当前实现约束能作为断言依据。
发现文档/实现不一致先查证，不能以 bug 的输出追认正确性；没有依据时不编造阈值。
实测值不是默认性能预算。已有测量工具没有实现的能力不能通过写索引补成通过。

完成流程见 [AGENTS.md](../AGENTS.md#文档驱动)：固定提交，独立对抗性审查文档、实现、
证据和真实缺口，处置发现并复核；指定 GLM-5.3 审查由协调者安排，
未完成的审查保持待审。
