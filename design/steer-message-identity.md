# Steer 消息身份修正

修复基于 `d0794e701162449ef0e320259d65cdc1cc9a434b`，保持原生消息的「文本 + 时间」设计。
问题来源是用户提供的独立静态审查摘要，引用 Thread
`576f5737-977f-4139-aab3-4f30b60ae73f` / execution
`5bc35645-0032-4be3-8f3b-4dd59f2c1028`；本次没有通过工具读取该审查线程全文。

## Codex：已证实未准入的旧输入

[native.go](../internal/plugins/harness/codex/native.go) 将「已证实未准入」与
「目标终止且已完成 settlement 等待」分开。前者包括发送前没有目标/取消，以及
原生精确的 `-32600 / no active turn to steer` 拒绝。该拒绝后的 settlement 等待
超时或取消仍携带未准入事实，但不因此允许 Runtime 重发。

[adapter.go](../internal/plugins/harness/codex/adapter.go) 捕获本次 `messageID`。
失败时先生成原有审计错误；只有已证实未准入才从同一个已复制的 execution 中删除
该 ID 的 follow-up 消息和对应 user-message 时间线引用，然后一起提交。
不会按正文、时间或「最近一条」查找，不会删除相同文本的其他输入，也不改终止结果。
原 execution 中的错误记录仍可读，search/Overview/reader 不再把已删除输入当作旧轮补充。

只有原有 settlement 门禁满足，且审计/删除提交成功，才向 Core 返回原有的
`ErrExecutionEnded`，由其决定一次 successor 重发。一般传输错误没有未准入证明，
保留原输入与审计错误，不自动搬到下一 execution。

## OpenCode：HTTP 丢包后的归属恢复

[State.SteerInputs](../internal/plugins/harness/opencode/state.go) 是私有的持久关联表，
以提交的消息 ID 为 key，绑定 native session、execution、输入文本、presentation、
创建时间和批注。[Send](../internal/plugins/harness/opencode/thread.go) 在 native I/O
之前提交这份关联，但不把它加入 `Messages`，不调用 `Admitted`，也不投影给 UI。

下列原生证据使用同一个 `observeUserMessage` 路径：

| 证据 | 处理 |
| --- | --- |
| HTTP prompt 成功回包 | 消费关联并保存一条消息；已有 inbox/history 记录则复用。 |
| `session.inbox.enqueued` | 按 inbox/message ID + native session 匹配关联，恢复原 execution 和 FollowUp。 |
| 历史 user-message | 按同一身份匹配；不使用已经切到 successor 的 `NativeExecutions[session]` 覆盖原归属。 |
| 清理期间迟到的匹配 inbox 事件 | 仅保存这一条输入事实，不处理其他执行状态，也不越过被忽略的事件推进 replay cursor。 |
| 清理读取到的匹配原生 inbox 项 | 先持久化输入，再删除 native 队列项；身份冲突或持久化失败则保留队列项并报告错误。 |

关联被消费后，canonical message 保留 FollowUp 和 execution；后续事件/历史/HTTP
结果按身份复用它，保留已有 canonical ID。不同 session、不同 execution 或不同角色的
冲突不能覆盖已有消息。没有原生证据的关联始终是私有提交意图，不显示为 Steer。
未知关联保留以供后续对账；fork 创建自己的新状态，不继承尚未确认的关联。

命令层的成功语义没有扩大：`Admitted` 仍只在本次 HTTP 成功路径上调用。
HTTP 丢包仍可能走既有失败/清理流程；即使 UI 已按独立原生证据恢复消息，也不会自动
把命令改成成功或重发输入。界面没有增加已接收、处理中或失败标签。

## 与 main 的关系

只读对照 `ae7a40cdeab822947ea33bbd3ec8ba9b6e4b450f`，共同基线为 `10d4811`。
该 main 不包含本 worktree 的 steer 展示提交；本次修复依赖 `d0794e7` 的 FollowUp 数据
及原生展示，不能仅摘取修复而遗漏前置实现。相关 Codex/OpenCode 状态、发送与 Runtime
准入路径在 main 上无独立冲突修改。Codex 的 main 差异是 `voice.go` 的语音准入上下文，
本次不涉及该文件或它的契约。没有合并 main、修改共享 refs 或操作其他 worktree。

## 验证与局限

本地静态 review 覆盖：精确拒绝与未知错误的区别、相同文本不同 ID、旧 execution
终止后的提交、事件早于/晚于 HTTP、重启后的持久关联、successor 后迟到历史、重复事件、
跨 session 冲突，以及清理/持久化失败。这是代码推演，不是已执行的场景测试。

- `./scripts/go.sh build ./internal/plugins/harness/codex ./internal/plugins/harness/opencode` 通过。
  最终修订的 `./scripts/go.sh build -o .build/steer-messages/mokusei-runtime ./cmd/mokusei-runtime`
  通过；只生成二进制，没有启动 Runtime。
- 最终 `make lint` 通过（架构、gofmt、`go vet ./...`）；`git diff --check` 和文档链接检查通过。
- 原生 SwiftUI 与前端 schema 没有改动；`steerInputs` 不进入 renderer 白名单。本次不重新
  执行原生构建/截图，不引用先前提交的原生结果作为本次端到端验证。
- 没有新增或运行测试、回归或 CI；没有 PR、推送、安装、真实 profile 数据修改或 main 合并。
- 已有历史错误记录若没有消息级拒绝关联，不按文本猜测删除；旧 OpenCode 消息若没有
  保存本次新增的提交关联，也不靠时间/顺序补造 FollowUp。没有做历史数据迁移。
- 如果 HTTP、事件、历史及原生 inbox 都没有可匹配的证据，结果继续未知；私有关联会保留，
  不把超时或后续输出当作成功。崩溃/磁盘失败不能获得未落盘的证明，仍须原有对账流程。
