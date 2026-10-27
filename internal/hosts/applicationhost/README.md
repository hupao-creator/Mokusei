# Application host

模块实现：

```go
type Application interface {
    Manifest() plugin.ApplicationManifest
    Register(plugin.Registry) error
}
```

Manifest 声明 collections、settings、queries、commands、threadTypes 和 backgroundAgents。每个贡献 ID 使用 `<plugin-id>.` 前缀。宿主在启动前检查实际注册和 manifest 完全一致、贡献 ID 不重复、collection 和 settings 归属正确。

Register 只注册纯定义。创建网络客户端、原生 Handle、定时器或后台进程应放到 participant 的生命周期中。宿主仍注册禁用模块的声明以保留 settings schema，但固定的启动期 Enabled 决策控制调用、catalog 和后台 agent。保存启停偏好后重启生效。

每次注册会复制声明中的可变数据（schema、默认值、能力清单）；manifest 的输入和查询结果也独立持有贡献清单。Register 返回后立即关闭该 Registry，保留的引用不能再改变已验证的定义或增加能力。

启动时，宿主按当前注册的 settings 声明补充默认配置，并移除已不再注册的配置项，避免已删除插件的残留项阻断整份设置保存。仍已注册但被禁用的模块保留用户配置；保存请求仍严格拒绝未知配置项。

相同清理也覆盖 Moku 已应用配置快照，但不改变其应用版本或补入尚未应用的新默认值。已移除应用或后台 agent 的命令回执在启动事务中清除；已注册应用、agent 及其目录实例的回执继续保留，包含禁用模块。

组合层的 [plugin_preferences.go](../../core/composition/plugin_preferences.go) 同时对照当前完整插件目录清理当前设置及 Moku 快照里的过期启停偏好，避免移除 Provider、Context、Harness 或 Sidecard 后被旧偏好阻断启动。

### 记录与事务

CollectionDefinition 包含 ID、OwnerPluginID、Retention（history/settings）和 ValueContract。ValueContract 同时验证输入和输出，必须返回独立且有效的 JSON；SchemaVersion 是公开版本，不依赖某一验证库。

CommandDefinition 分成 Plan 和 Reduce：

1. 宿主验证 input、调用者 audience 和后台 batch fence。
2. Plan 在一次已提交 snapshot 上读取记录，并返回 `Records.Scope` 或 snapshot capability 发出的 MutationScope。空 record ID 表示整 collection，覆盖插入/删除导致的 membership 变化。
3. 宿主验证每个 scope token 确实由本次 planner 发出，且全部已读取依赖都被声明。
4. Reduce 在同一 SQLite 写入事务内运行，使用限定到这些 scope 的 RecordsWriter。任何未规划的读取或写入被拒绝。Reduce 不执行 I/O、不读取当前时钟、不生成随机数；使用固定 `CommittedAt` 与 `AllocateID(localKey)`。
5. 输出验证、record writes、顺序、collection revision、entity lifecycle facts 和 receipt 一次提交；错误整体回滚。

`Put` 的 ExpectedRevision 为 nil 表示必须不存在，非 nil 表示精确 CAS；TouchUpdatedAt=false 保留业务时间。宿主独立增加 record revision。业务命令不得直接改写 conversation session；只能由 Core 使用 Conversation 扩展嵌入已授权会话。

`Records.List` 保留 collection 的持久顺序；未列入顺序的记录按 key 排序追加，已不存在的记录跳过。枚举以一次 membership set 合并顺序与现存记录，避免 collection 增长时反复线性查找；返回值仍由同一 snapshot 解码。

查询、Plan 与 Reduce 的 context 携带宿主复制的 `Owner`（BackgroundAgentRef）；用户调用为零值。后台 DomainClient 的 owner 不来自 input。scope 型应用使用该身份约束自己的记录读写；任务 snapshot 的 `Scope` 由 Runtime 解析，应用不自行访问文件系统来决定归属。

后台命令的 options 带 `RequestID` 和 `BatchWriteContext{ConsumerID,BatchID,InvocationID}`。宿主检查 agent namespace 和当前活动 batch，按该 batch 的 invocation 保留原子结果。相同调用重放得到同一结果；复用身份但改变参数失败。不同 batch 不共享幂等身份。

### 查询、投影和线程扩展

QueryDefinition.Read 是纯 snapshot 查询。ExternalQueryDefinition.Read 在事务外执行按需 I/O，接收固定 Snapshot 和明确声明的 runtime 能力。大 HTML、diff 和文件内容属于 query，不能放进 catalog。

ThreadTypeDefinition 通过 Project 返回 title/view 和可选的稳定 Scope；宿主附加身份、版本、时间及以下可选扩展：

| 扩展 | 职责 |
|---|---|
| Tags | 投影标签、声明来源、在同一 tag 事务内变换快照 |
| Classification | 提供稳定 evidence revision 和有界分类内容 |
| Archive | 更改归档状态并声明受影响的最新执行引用 |
| Overview | 声明可见性、directory filter 和覆盖的 execution |
| Conversation | 读取、初始化配置和嵌回宿主授权的 Harness session |

`Host.CatalogSnapshot` 支持整个 runtime aggregate 使用同一 store snapshot。Conversation catalog 由宿主的 ProjectSession 回调进行 Harness overview 投影，不能直接泄露持久会话全文。

### 后台能力与生命周期

能力 key 包含 ID、APIVersion 和 Phase。宿主只发放定义的 Requires 清单中的能力；snapshot 能力只在纯查询/事务中使用。现有 keys 覆盖 lifecycle、background configuration/sessions/environment、ordinary tasks read/snapshot、classification、semantic tags read/write/snapshot、overview control 和受控 process。

BackgroundAgentDefinition 必须显式声明 Global 或 PerDirectoryScope。Runtime 的 DirectoryScopes 只提供持久目录身份与名称；Host 根据注册定义派生稳定实例 ID。目录在 task 生命周期事务中记录，来源删除或事件类型不会影响恢复。

每个实例携带显式 ScopeBinding：Global 与 Directory 不同，Inbox 是有效 Directory，零值和非法绑定被拒绝。生命周期订阅、历史（包括显式事件 ID）和普通任务读取自动与绑定取交集；冲突的事件 scope 匹配空集合。观察私有 session 也必须属于同一实例。Global 仍受 Requires 和普通来源校验约束；分类证据能力暂不支持 Directory 绑定。实例划分不决定 lazy/idle 会话资源策略。

BackgroundAgentDefinition.Create 接收独立 owner、DomainClient、SettingsReader 和 capability access。私有 session 按 owner/sessionKey 隔离。Lifecycle consumer 的 local ID 由宿主加 owner namespace；durable work 保留 event IDs、attempts、retry time、execution identity 和 receipts。普通任务、Moku、其他 agent 的私有会话不能因为注册订阅而混为一个可见集合。

Host.Start 在全部定义冻结后创建一代 participants。Stop 先撤销工作并取消 generation，然后等待创建中的工作、participants 和领域操作排空；清历史只在成功停止后执行，保留 settings-retention collections，再创建新一代。

共享后台 runner 的 native Handle 清理失败会保留失败状态；重复 Stop 不能把未确认关闭的资源报告为已排空，也不能允许启动下一代。

共享 runner 的批次错误诊断包含阶段、已记录的尝试次数和本次处理耗时。
原生终态只记录失败/中断/等待交互状态及是否存在原生错误，不输出错误原文、
工具参数、会话内容或工作目录。关闭导致的批次取消使用 `cancelled` 信息事件，
不再先记 `failed`；独立超时和真实失败仍按原有次数上限与退避重试。
取消不吞掉原生 Handle 的清理失败，也不额外结算或增加关闭中的批次尝试。

后台批次与工具读取 lifecycle 历史时，每一页开始前检查调用取消。已进入的单页读取仍由无 context 的 snapshot 能力完成；取消后不再继续读取后续页。

## Composition and implementations

[registry.go](registry.go) validates declarations; [operations.go](operations.go) owns command planning and reduction; [records.go](records.go) restricts record access; [lifecycle.go](lifecycle.go) owns participant generations. The [composition root](../../core/composition/bootstrap.go) supplies Report, Tag and built-in Git explicitly.

- [Report](../../plugins/applications/report/README.md) maintains documents within a directory scope.
- [Tag](../../plugins/applications/tag/README.md) maintains a separate tag pool in each scope.
- [Git](../../plugins/applications/git/README.md) stores observations for ordinary thread card extensions. It declares no Git thread type and is excluded from user enablement controls.

Verification from the repository root: `./scripts/go.sh run -race ./tools/verification/applicationhost`, `./scripts/go.sh test -race ./internal/hosts/applicationhost`, and `./scripts/go.sh run -race ./tools/verification/runtime`.

## Isolated Swift query fixture

The application-host runner uses actual Report schemas, Plan/Reduce, queries and SQLite with a controlled background participant. The runtime runner additionally exercises the production scoped Report runner. To retain a Report for an actual Swift client query:

```sh
mokusei_report_profile="$(mktemp -d /tmp/mokusei-report-probe.XXXXXX)"
./scripts/go.sh run -race ./tools/verification/applicationhost \
  --seed-profile "$mokusei_report_profile"
xcrun swift run --package-path app/macos MokuseiProbe \
  --data-dir "$mokusei_report_profile" \
  --runtime "$PWD/.build/go/mokusei-runtime" \
  --query-plugin report --query-operation report.html \
  --query-input '{"reportId":"ID_FROM_FIXTURE_OUTPUT"}' \
  --duration 0.5 --stop-service
```

Build the runtime with `make runtime` first and replace the sample Report ID with the runner's output. Seeding requires an empty absolute directory and rejects a symlink profile. `applicationhost-fixture.json` records the actual query and generated identity. The probe uses production discovery/HTTP/JSON decoding; it does not evaluate report-writing quality or native rendered layout. Remove the isolated profile only after its service has stopped.
