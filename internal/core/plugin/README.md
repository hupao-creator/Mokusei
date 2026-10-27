# Harness contracts

[Harness definitions](harness.go) describe the execution boundary; concrete implementations are composed in [bootstrap.go](../composition/bootstrap.go). Plugins receive scoped capabilities and do not import Runtime or the database implementation.

`plugin.Harness` 必须提供 Descriptor、DefaultSettings、Detect、Settings、SessionState、Metadata 和 Open。可选功能使用独立接口，包括 Installer、Forker、PromptCompleter、AvailabilityProbe、ModelCatalogSource、WorkspaceDiscoverer、Extension、DiscussionPreparer、VoiceCapability 和 NativeVoiceCapability；未实现的能力不能以空成功响应冒充支持。

`OpenContext` 将会话限定到一个 Thread：

- `ReadThread` 返回会话快照。
- `SessionState.Read/Commit` 是原生状态的唯一发布入口。Commit 在返回前完成宿主定义的投影与持久化边界。
- `ExecutionAdmission.Accept` 为插件主动产生的执行分配身份并先完成工作目录和状态准入。
- `MetadataStore` 使用独立 revision 的 CAS，不与流式 session revision 混用。
- `PublishActivity` 提供有序、短暂的前台活动；它不取代持久化状态。
- `Injection` 携带 instructions、context、seed 和 tool bindings。ToolBinding 通过 `Execute(ctx, ToolCall)` 返回 JSON；取消必须沿 context 传播。

Handle.Send 接收 `SendRequest`。存在 `Admitted` 回调时，适配器在本次输入持久保留后调用一次；新执行在 native dispatch 前准入，follow-up 可等待原生接受后确认，避免把被拒绝的 steering 标记为已送达；旧输入的流式更新不能为新 steering 输入代办准入。Interrupt 和 Close 必须撤销接纳并排空本 Handle 的 native 工作和子进程。

共享 `GeneratedThreadMetadata{}` 与 `WithGeneratedThreadMetadata` 提供真实的模型命名策略：保留已接受输入、异步请求 title/emoji、45 秒超时、CAS、防止旧结果覆盖新输入，以及中断和恢复。命名失败不把已经接受的用户发送改成失败。包装器保留底层 Voice、NativeVoice 和 CompletedReply 能力。

语音通过 `VoiceSession` 表达 start、poll、heartbeat、input fencing、speech、delegation、event 和 stop 的生命周期。过期 poll cursor 可以返回错误。私有 discussion 只提供 Ask/Close，以及可选 native voice，不允许推进原始任务。

模型服务、账号和凭据由各 Harness 的原生配置管理。Core 不注册模型服务插件，不发现或注入跨 Harness 凭据；Thread 只保存 Harness 自己的 settings。

模型和 thinking/effort 能力以原生 CLI 的明确声明为准，不以是否属于原生订阅账户作为准入条件。账户归因检查仍用于订阅额度、模型身份来源和原生语音权限；普通会话不额外探测账户来覆盖原生模型目录。

## Generated metadata

[metadata.go](metadata.go) and [metadata_completion.go](metadata_completion.go) own the optional generated title/emoji policy. Successful input admission updates bounded initial/recent intent even if later native dispatch fails or the caller releases its request context. Rejected admission does not update metadata, and metadata persistence failures do not reject accepted input. Existing metadata stays visible until a replacement succeeds. Completion can steer to newer accepted input; results are fenced by metadata revision. Transient failures retry after 2, 5 and 15 seconds; exhausted or invalid results remain pending for another input or reopen. Interrupt and Close cancel and drain completion and backoff. An admission racing with Interrupt remains pending in admission order without resuming naming.

## Other plugin categories

- [Application host](../../hosts/applicationhost/README.md): records, transactions, projections and background participants, declared in [application.go](application.go) and [capabilities.go](capabilities.go).
- [Context host](../../hosts/contexthost/README.md): Moku-only context collection, declared in [context.go](context.go).
- [Native Plugin API](../../../app/macos/Sources/Shared/PluginAPI/README.md): Swift presentation and Sidecard contracts.

Verification from the repository root: `./scripts/go.sh run -race ./tools/verification/thread-metadata` and the affected [Harness replay](../../../tools/verification/README.md).
