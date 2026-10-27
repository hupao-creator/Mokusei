# Moku Context host

Context 专指向 Moku 提供附加上下文的独立插件类别，不向普通任务或后台 Agent 注入内容。插件实现 `ContextPlugin`，通过 `ContextManifest` 声明贡献 ID，使用只有 `MokuContext` 方法的 `ContextRegistry` 注册定义。Application 契约不再声明或注册上下文贡献。

`contexthost` 独立校验 manifest、owner 前缀、重复身份、注入时机、超时及失败策略。插件只接收绑定模型目录，可以自行读取和缓存数据，不获得 Application records、domain commands、界面或后台 Agent 能力。注册阶段不启动采集；禁用的插件不创建服务。

`Start` 创建当前代服务。`CollectMokuContexts` 按贡献 ID 收集并按 slot 稳定合并，支持 `session-start` 与 `before-send`；Collect 与可选 Fallback 分别使用注册超时，服务必须遵守调用 context。单贡献最多 128 KiB，总共最多 256 KiB，包含同 slot 合并时插入的分隔符。OnFailure 决定忽略贡献或拒绝本次发送。调用方取消及宿主关闭总会取消采集，不触发回退。`Stop` 撤销准入、取消当前代、等待创建完成、调用每个服务的 `Close` 并排空采集；`Close` 必须幂等且排空服务拥有的 acquisition。清历史也停止并重建 Context 宿主，但不应用等待进程重启的开关变更。

Artificial Analysis 的 ID 保持 `artificial-analysis`，贡献仍是 `artificial-analysis.evaluation`，在 `before-send` 向 `evaluation` 槽注入，保留 21 秒超时、缓存回退与 `abort-send`。没有缓存时仍提供明确的评测未知文本。设置中的身份为 `context:artificial-analysis`，不迁移旧 extension 配置。原生 Harness 和核心会话上下文继续由各自所有者提供。

[host.go](host.go) owns registration and generations; [collect.go](collect.go) owns collection, bounds and failure handling. [Artificial Analysis](../../plugins/contexts/artificialanalysis/README.md) is the registered implementation.

Verification: `./scripts/go.sh run -race ./tools/verification/artificialanalysis/lifecycle` from the repository root.
