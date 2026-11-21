# 如何新增 Harness plugin

接入一个新的 coding agent，需要为同一个 Harness ID 提供两份实现。Go 适配器驱动用户安装的原生 CLI，Swift 插件把该适配器的投影呈现在 macOS 上。两者都随 Chief 编译，通过源码静态注册。设置里的“发现”检查外部引擎及其配置。仓库没有扫描工作区 `plugins/` 或读取第三方 Harness manifest 的加载器。[Go 组装入口](../../core/composition/bootstrap.go) · [macOS 组装入口](../../../app/macos/Sources/Composition/NativePlugins.swift)

## 1. 选定 ID 和参照实现

选一个唯一、稳定的 ID。沿用同一个值作为 Go 注册键、Go descriptor 的 `ID`、Swift descriptor 的 `id`、设置键和 Thread 的 `harnessId`。按新引擎的原生协议选一个参照，先从它的 `Open` 跟到第一条输入和终态，再看 Swift 如何读取同一条执行。

| 原生引擎 | 适合参考的路径 |
| --- | --- |
| Pi Agent | RPC 子进程、仅独占工具注入、外部安装说明。可沿 [Go 适配器](pi/adapter.go) → [Thread](pi/thread.go) → [Swift 插件](../../../app/macos/Sources/Plugins/Harnesses/Pi/PiHarnessPlugin.swift) 走完整条路径。 |
| Codex | app-server JSON-RPC、分页模型目录，以及只能送给活动执行的追加输入。[适配器说明](codex/README.md) |
| Claude Code | stream-json 会话、原生权限交互和注入工具的 MCP 桥。[适配器说明](claude/README.md) |
| OpenCode | 原生服务的 HTTP/SSE、事件重连、原生历史与已提交输入的核对。[适配器说明](opencode/README.md) |

## 2. 实现 Go 适配器

在 `internal/plugins/harness/<id>/` 建包，用 `New(host plugin.HostContext)` 构造实例。参照 Pi 的 `var _ plugin.Harness = (*Adapter)(nil)` 在编译期检查接口。用宿主提供的环境、可执行文件解析器和目录启动引擎。账号、凭据、模型及其配置归原生引擎管理。Runtime 持有工作区准入、执行身份和持久化权限。适配器通过 `OpenContext` 使用当前 Thread 的授权，无需导入 Runtime 或打开宿主数据库。[接口定义](../../core/plugin/harness.go) · [Go 模块边界](../../README.md)

| `plugin.Harness` 必需入口 | 实现要点 |
| --- | --- |
| `Descriptor`、`Detect(ctx, cwd)` | 返回身份、显示名和实际具备的能力。检测用户安装的 CLI，参照现有适配器返回 `installed` 和可执行路径，或 `missing`。区分缺失、探测失败和调用取消。[Pi 检测](pi/adapter.go) |
| `DefaultSettings`、`Settings` | 提供能被 `Normalize` 接受的默认 JSON。`DefaultThread` 从 Harness 配置提取 Thread 默认值，`ResolveThread` 收到的 `Merged` 已是该默认值。`SnapshotExecution` 固定执行配置，`Describe` 给出创建选项，`Presentation` 给设置页数据。实现 `HasThreadContent`、`ApplyThreadUpdate` 和 `PromptSettings`，覆盖有内容的会话更新及独立 prompt 所需的配置。[Pi 设置实现](pi/settings.go) |
| `SessionState` | 从插件自己的状态实现 `Project`（公开执行与交互）、`ProjectRenderer`（按 scope 取显示数据）、`ReadContext`、`ResolveExecution`（按精确 ID 查找）和 `Settle`（指定执行失败或中断）。读投影可跨 Thread 并发。保持 `overview` 有界，正文由 `thread`、`turn`、`execution` 按需读取。[公开观察类型](../../core/model/observation.go) · [Pi 状态投影](pi/state.go) |
| `Metadata` | 实现 `Initialize`、`Project`、`Fork`。需要模型生成标题和 emoji 时，可配对复用 `GeneratedThreadMetadata{}` 和 `WithGeneratedThreadMetadata`。元数据用独立 revision 的 CAS 提交。[元数据契约](../../core/plugin/README.md#generated-metadata) |
| `Open(ctx, OpenContext)` | 用 `ReadThread` 和 `SessionState.Read()` 打开这个 Thread，返回实现 `Send`、`Interrupt`、`Respond`、`Read`、`Close` 的 `plugin.Handle`。`Read` 回答针对会话历史的问题。需要恢复的原生状态通过 `SessionState.Commit` 发布，瞬时活动走 `PublishActivity`。[Runtime 打开和持久化路径](../../core/runtime/threads.go) |

`Send` 使用这次请求的 `ExecutionID`。持久保留本次输入后，如提供了 `Admitted`，恰好调用一次。新执行先准入再发给引擎，追加输入可等原生接受后确认。引擎自主发起新执行时，用 `ExecutionAdmission.Accept` 分配身份并投影 running 状态。只有原执行已有持久化终态、本次输入尚未保留或分派时，才可原样返回 `plugin.ErrExecutionEnded` 让 Runtime 重新预留一次。结果不明时保留错误，避免重复分派。[发送契约](../../core/plugin/harness.go) · [准入属性](../../../tools/verification/pbt/runtime/send_property_test.go)

把回答绑定到待处理的交互。`Respond` 只有在该回答尚未开始原生 I/O 时才能返回 `InteractionResponseNotSentError`，以便 Core 释放回答权。中断要取消当前执行和它的工具调用。`Close` 可重复调用，返回前等待进行中的工作结束并回收所属子进程。适配器级探测、缓存等资源可通过可选的 `plugin.Closer` 随 composition 关闭。[Handle 与生命周期契约](../../core/plugin/README.md)

## 3. 声明可用角色和能力

**要让它担任 Chief 的协调者**，Go 的 `CanHostMoku()` 要求 `Instructions`、`ThreadContext`、`SendContext` 均为真，且 `ToolModes` 包含 `exclusive`。Runtime 还检查启用状态、原生可用性和执行配置。普通任务作为派发目标另走模型目录检查。[Go 判定](../../core/plugin/harness.go) · [协调者选择](../../services/moku/coordinator.go) · [Swift 判定](../../../app/macos/Sources/Shared/PluginAPI/HarnessPlugin.swift)

| Go `ThreadCapabilities` | 开启时引擎必须能做到什么 |
| --- | --- |
| `Instructions` | 会话接收宿主的 `OpenContext.Injection.Instructions`，作为执行指令生效。 |
| `ThreadContext` | 会话打开时能带入 `Injection.ContextEntries`。如有 `Seed`，保留其历史数据语义。[Pi 注入实现](pi/bridge.go) |
| `SendContext` | 每次发送都能带入当次 `SendRequest.ContextEntries`，包括已打开会话的后续输入。 |
| `ToolModes` | 独占模式只允许宿主注入的工具，追加模式保留可用的原生工具。通过 `ToolBinding.Execute(ctx, ToolCall)` 分派调用并传播取消。Codex 和 OpenCode 在 Go 声明 `extend`，Claude 声明 `additive`，Swift 将追加模式写为 `.extend`。Pi 仅支持 `exclusive`。按实际引擎验证隔离行为。[Claude Go](claude/harness.go) · [Claude Swift](../../../app/macos/Sources/Plugins/Harnesses/Claude/ClaudeHarnessPlugin.swift) · [OpenCode 工具桥](opencode/bridge.go) |
| `FollowUpOnly` | Go 端对活动执行的保证。即使目标恰好在分派时结束，追加输入也不能启动下一次执行。遇到已结束的目标，在保留或发送前返回 `plugin.ErrFollowUpUnavailable`。目前只有 Codex 声明这项能力。其他插件仍能接收普通输入，延迟通知随下一次独立输入投递。[投递判定](../../services/moku/delivery.go) |

**要让 Chief 向它派发任务**，为 `create_thread` 返回该 Harness 的创建 schema。协调器对每个选中目标调用可选的 `MokuTargetDiscoverer.DiscoverMokuTarget`，缺省调用 `Settings().Describe`，两者均带 `RoutingCatalog: true`。任一目标返回空或不完整的目录，都会阻止本次准备。[目标发现](../../services/moku/context.go)

完成所有原生分页后用 `plugin.ModelCatalogSchema` 绑定创建选项、非空模型清单、配置身份和来源依据。清单保留尚无可执行选项的模型，创建分支只列可用组合。远端来源是否完整有独立的 `source.complete`，未知可以如实保留。路由允许复用同配置的完整缓存，实际创建仍须在目标工作目录校验模型和 thinking 等选项。[schema 构造器](../../core/plugin/model_catalog.go) · [目录准入与缓存](../../services/moku/catalog-evidence.md)

**按需实现其他接口。** `AvailabilityProbe` 可检查给定配置和工具模式是否可运行，宿主选择在缺省时回退到 `Detect`。`Forker` 提供原生分叉，`PromptCompleter` 提供独立补全，`Extension` 实现专属命令，`WorkspaceDiscoverer` 提供已知工作目录。按需给状态适配器实现 `SearchPassageAdapter`，只交付已完成执行的公开文本及其执行 ID。对于不支持的能力，省略可选接口，让宿主处理缺失。[可选接口](../../core/plugin/harness.go) · [检索契约](../../core/plugin/search.go)

## 4. 注册 runtime 并检查配置

1. 在 `bootstrap.go` 导入新包，在 `Bootstrap.open` 的 `constructors` 增加 ID 对应的构造函数，**同时把 ID 加入 `ids`**。启动循环按这份列表创建适配器和每个引擎的 telemetry ledger，将适配器传入 `core.Config.Harnesses`。活动插件目录中的键为 `harness:<id>`，默认启用。composition 在启动时读取 `settings.pluginEnabled`，保存偏好不会改变当前实例的启用状态。[bootstrap.go](../../core/composition/bootstrap.go) · [启用状态](../../core/runtime/README.md#settings)
2. 在架构检查器的 `allowed` 为新包声明实际导入的内部包，并在校验 `bootstrap.go` 构造调用的 ID 列表加入新包。检查器识别包的 `New` / `NewWithOptions` 调用。Pi 和 OpenCode 嵌入的四份 JS 是供外部引擎加载的单独白名单资源。[架构检查器](../../tooling/architecture/check.go)
3. 如需向 Chief 贡献原生账号或使用情况等上下文，可实现 `MokuContextContributor`。如需向 Context 插件提供参考模型目录，实现 `ModelCatalogSource` 并在 `CollectContext` 的显式 ID 列表接入。可选 `CachedModelCatalogSource` 提供快速只读快照。此处的消费者是 Context 插件。协调器另行获取派发目标的目录。协调者和后台执行的自动排序都把额外注册的 ID 接在内建优先项之后。[Context 组装](../../core/composition/moku.go) · [后台执行选择](../../core/runtime/background.go)
4. 从新的隔离 profile 检查 `state:load`。在 `plugins` 找到 `harness:<id>`，在 `settings.harnesses[id]` 核对默认配置。`moku.hostHarnessPreference` 选择协调者，`moku.executionHarnesses` 保存其执行配置，`moku.targetHarnessIds` 选择可派发的目标。Runtime 仅在首次创建设置时写入各 Harness 默认值，保存时要求每个已注册 ID 均有设置。[初始化](../../core/runtime/runtime.go) · [设置校验](../../core/runtime/settings.go)

## 5. 接入 macOS

1. 在 `app/macos/Sources/Plugins/Harnesses/<Name>/` 实现 `HarnessPlugin`。用相同 ID 和对应能力建立 descriptor，提供 logo、三种 codec（Thread 设置更新、Harness 设置、settings presentation）、阅读视图、Overview 投影与卡片、Thread 和 Harness 设置视图。可按引擎提供 `settingsPresentationIssue` 报告 CLI 或目录问题，支持协调者时参考 `projectMokuDock`。首次设置页的 **Install** 打开 descriptor 的可选 `installationGuide`。Runtime 的 `harness:install` 单独要求实现 Go `Installer`。[Swift 契约与默认实现](../../../app/macos/Sources/Shared/PluginAPI/HarnessPlugin.swift) · [Pi 插件](../../../app/macos/Sources/Plugins/Harnesses/Pi/PiHarnessPlugin.swift)
2. 在 SwiftPM 增加 `ChiefHarness<Name>` target，按需依赖 `ChiefCore`、`ChiefPluginAPI`、`ChiefPluginUI`，加入 `ChiefComposition` 的 dependencies。然后在 `NativePlugins.swift` 导入模块，把具体插件用 `AnyHarnessPlugin` 包装后加入 `NativePlugins.make()` 的 `harnesses` 数组。[Package.swift](../../../app/macos/Package.swift) · [NativePlugins.swift](../../../app/macos/Sources/Composition/NativePlugins.swift)
3. 让插件解码 Go 生成的私有 renderer 投影，按 execution ID 关联卡片、交互和正文。共享 Host 通过 `HarnessPluginRegistry` 按 ID 找插件，并通过已认证的 HTTP/NDJSON 获取状态、订阅内容和发命令。阅读视图使用 `HarnessThreadActions`，Overview 卡片只收到回答已有交互和打开 Thread 的回调。[注册表与渲染检查](../../../app/macos/Sources/Shared/PluginAPI/HarnessRegistry.swift) · [原生宿主](../../../app/macos/Sources/Host/HarnessHost/NativeHarnessHost.swift) · [传输与 scope](../../platform/transport/README.md)

## 6. 从发现走到一次真实执行

从仓库根目录运行 `make lint` 检查 Go 注册、依赖、格式及 vet，在 macOS 构建环境运行 `make typecheck` 编译 Go 和 Swift。改动触及 Runtime 准入时，可运行 `make pbt-go PBT_ARGS='--property PBT-RUNTIME-ADMISSION'`。该属性使用可控 Harness 驱动真实 Runtime 与 SQLite。现有 Codex 终态和目录属性只覆盖各自生成的输入域。[检查入口](../../../Makefile) · [属性清单](../../../tools/verification/pbt/README.md)

用本次构建和单独的 `--data-dir` 启动回放。服务就绪后，从仓库根目录执行下面的只读检查。将路径换成本次回放的 profile，将 `pi` 换成新插件 ID，即可分别观察静态注册与 CLI 检测结果。[隔离启动与 UI 操作](../../../tools/native-interaction/README.md) · [公共 HTTP 客户端示例](../../../tools/benchmarks/adapter.py)

```sh
python3 - /absolute/path/to/test-profile pi <<'PYTHON'
from pathlib import Path
import sys
from tools.benchmarks.adapter import Runtime

profile, harness_id = sys.argv[1:]
runtime = Runtime(Path(profile))
catalog = runtime.state()["plugins"]
print([entry for entry in catalog if entry["key"] == "harness:" + harness_id])
print(runtime.invoke("harness:detect-installation", [harness_id]))
PYTHON
```

| 操作与预期 | 未达到时先查 |
| --- | --- |
| 首次设置列出新引擎，单项检测返回 `installed`。 | Runtime 报 `unknown harness` 时对照构造表和 ID 列表。原生端报 `Harness is not registered` 时对照 SwiftPM 依赖、注册数组及 ID。检测报 `missing` 时核对 Runtime 看到的可执行路径和环境。`harness:detect-installation` 接收单个 ID，`harness:detect-installations` 刷新环境再检测全部。[发现命令](../../core/runtime/commands.go) · [环境解析](../../platform/environment/resolver.go) |
| 设置页能加载、保存该引擎的配置，重新打开仍显示所选值。声明支持协调时能选择它担任 Chief。 | 已安装但首次设置仍未就绪时，检查 `harness:settings-presentation` 的 `value`、Swift codec 和 `settingsPresentationIssue`。核对两侧的协调者能力以及 Go `Probe` 的结果。[首次设置判定](../../../app/macos/Sources/Host/Onboarding/NativeOnboardingState.swift) |
| 选择新引擎为派发目标，让 Chief 在测试目录创建任务。观察 `create_thread` 选中该 ID，卡片出现，阅读页能从运行中更新至终态。 | 准备阶段失败时先检查每个选中目标的目录。已准入但卡片或正文为空时，对照同一 Thread、execution ID 下的 `Project`、对应 scope 的 `ProjectRenderer` 和 Swift 解码。工具返回成功只说明任务已获准启动。[创建工具](../../services/moku/tool_schema.go) · [Runtime 投影](../../core/runtime/README.md#threads-and-content) |
| 在隔离会话送入后续指令并中断一次运行。按声明的能力回放独占工具、回答原生交互或分叉，再打开历史检查结果。 | 对齐输入回执、原生接受事件和持久终态。遇到重复输入或停止影响后继执行，先检查 `Admitted` 的调用点、工具取消及执行身份。[生命周期契约](../../core/plugin/README.md) |

产品 e2e 的现有桌面场景使用 Codex 和确定性模型 peer。新增引擎的安装、真实认证及交互需要该引擎自己的证据。在新包的 README 写明原生协议、配置、能力限制和验证入口。将新的交互场景或有独立判据的属性登记到对应清单，记录提交 SHA、CLI 版本、配置、命令、可观察结果与未覆盖项。体验时延用性能 benchmark 衡量。用户可见的安装、选择或会话操作有变化时，同步更新英文产品指南。[e2e 清单](../../../tools/e2e/README.md) · [验证策略](../../../scripts/ci/verification-policy.md) · [产品指南](../../../docs/README.md)
