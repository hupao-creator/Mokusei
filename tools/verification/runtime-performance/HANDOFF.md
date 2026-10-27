# 跨专项交接与后续测量项

以下定位以 `c17a3fcb270b8d862bbd9cc03ae18c45c4c133fd` 为准。这里的“确认”仅指调用路径、重复工作或阻塞机制可由源码证明，不代表已测得用户可感延迟、OOM、原生进程泄漏。表内项未在本专项修改；其他专项可能已分别处理，请父协调以其提交和独立 review 确认归属及整合状态。

## 已由 runtime 性能专项编辑，避免重复修改

- `internal/plugins/harness/codex/adapter.go`、`native.go`、README 及 `tools/verification/codex`：reasoning chunk 后重复 status 绕过批处理；未读取的文本累计。
- `internal/hosts/applicationhost/records.go`、README 及 `tools/verification/applicationhost`：List 对 order 重复线性查找。
- `internal/services/moku`、`internal/core/{runtime,store}` 及相应 verification：本专项其他修复，见审计报告。未修改 Overview/Swift/GUI。

## 建议 plugin 设计专项接手

| 路径/机制 | 受控复现与修复约束 |
| --- | --- |
| OpenCode `thread.go:506–617` 持 `t.mu` 自动应答 permission、获取 usage；`usage.go:23–44` HTTP 使用 `t.life`，`runtime.go:211,318` 无独立超时。Interrupt/Close 在取消前等同锁 | localhost HTTP gate 卡住 permission/message 响应，保持 SSE 活跃，再 interrupt/close。锁外 I/O 必须带 execution/generation fence，不能遗漏已准入工具或错误 |
| Pi `session.go:168–217` 无界事件队列，`protocol.go:454–485` 每项含累计全文；OpenCode `thread.go:385–389` recovery 把有界队列转入无界 buffered | gate Commit/export 并输入定量 delta，记录 retained heap/队列数据量。不能简单堵 Pi RPC reader，consumer 可能同步调用 RPC；不能丢语义事件 |
| Codex `transport.go:278,318–332`、Claude `transport.go:452–476` 同步 pipe 写完才观察取消；native 不读 stdin 时 Send 持锁可阻止 Interrupt/Close 到达 cancel | fake peer 完成初始化后停止读 stdin，发送超管道容量输入再取消；必须 join owned process，不能仅提前返回隐藏仍在进行的写 |
| Codex `publicFinals`/`retiredTurns`，Claude `parsers`/`nativeIDs` 在长寿命 Handle 内持续积累 | 连续本地执行和 CompletedReply 读取，验证正确退休边界。当前仅为长期内存候选，未测净增长，不直接套 LRU 丢弃仍可读执行 |

## 建议全项目正确性审计接手

| 路径/机制 | 受控复现与修复约束 |
| --- | --- |
| `threadvoice/manager.go:267–305` stopOnce 将 transcript 保存失败永久缓存，media 已成功停止也不移除 calls | 用普通文件替换临时 history 目录制造 ENOTDIR，恢复目录后重试 stop/prepare。区分可重试持久化错误与尚未确认的 native teardown；不能吞存储错误 |
| 同文件 `RevokeDevice:356–362` 先删 retired，stop 成功又写回 retired | 多个新 device prepare→revoke，检查已关闭对象是否仍保留。这里只确认引用保留，不是进程泄漏 |
| `attachments/repository.go:568` CollectOrphans 无生产调用；删除/清历史/启动只 ReleaseOwner/RetainOwners | 真实临时 Runtime 上传→发送→删除最后 owner→重启，检查 payload/manifest。Swift 持久化草稿仍保留 staged IDs，回收前必须建立草稿生命周期保护，不能直接删除全部无 owner 文件 |
| `threadsearch/manager.go:164–229` 已取消 Status 把 cache 返回空文档当缺失，再提取历史 | 完整已索引来源 + LoadContent 计数，以已取消 ctx 查询；不得返回 nil 成功并继续不必要工作。与 Overview 专项协调文件归属 |

## runtime 后续设计/测量项

以下未混入本批小修；需要独立数据与规格，不能宣称本次已解决。

- **Receipt 持久化**：`transport/receipts.go:178–269` 每条 mutation 的 admission/completion 各在全局锁内整档排序、序列化、原子写和双 fsync。上限 24h/5000 条/32MiB，受控测 0/1000/4000 历史及并发 Lookup；若改为 SQLite/journal，必须保留 uncertain receipt 和 restart 幂等保证。
- **内容订阅常驻预算**：`transport/content.go:150,231` 每客户端 32 个完整 decoded baseline，最多 32 客户端；worker 字节预算只限制正在计算的 raw。应测同一大 target 的 1/4/16/32 subscriptions 和释放后的 heap，设计共享不可变 baseline 或全局字节预算。没有进行 OOM 式实测。
- **Lifecycle 真正变更的查询**：`store/lifecycle.go:278,315` Pending/History 仍全历史解码排序，History 还扫描全部 outcomes；runtime History 在按少量 EventIDs 筛选前翻完全部页；Tag replay=new 每目录保存全局历史 ID，D×E 内存。此次 revision 提前跳过只减少无关提交的触发频率。
- **Projection 与长会话**：Runtime publisher 仍全目录整理、解码 private sessions、逐对象 JSON 比较；Moku transcript 更新扫描完整历史。四 Harness 仍整段历史 Encode/Project，Codex 批内逐 delta clone 当前 turn，Claude/Pi/OpenCode 累计文本也有前缀复制。需要固定总输出与变化 chunk/历史规模的剖析，不能仅删校验或终态数据。
- **Workspaces**：`manager.go:419–462` 全局锁跨多次 Git inspect，普通 checkout 一轮约 14 个 Git 子进程。用现有 Git gate 卡住一个 repo，观察另一个 repo 的请求与取消。拆锁必须保留 owner/HEAD/TOCTOU 验证和注册原子性。
- **附件 I/O**：Stage/Preview 全局锁覆盖完整 I/O；RetainInput 纯文本也先取同锁。Stage/StageStream 还会重写未改的全 owners JSON。用 CheckFile barrier 与不同 owner 数复现；共享 owner、上传失败回滚和完整性验证不可削弱。
- **搜索/Embedding**：DeleteOwner 解码全索引和向量；自动 status→build 重复准备 pending 文档。校验失败不缓存，缺 engine 可导致状态轮询重复 hash 309,855,456 字节模型；健康路径仅 Stat。安装取消在已暂存阶段仍等活跃 inference 的 runMu。使用合成资产/held-inference fixture，失败缓存需有文件身份失效，不能永久缓存坏状态。
- **语音历史/目录分页**：每条完成 transcript 整段 JSON 重写与 fsync；每页目录先 ReadDir(-1)+sort 再取 200 项。固定消息/目录规模测量后再定存储/分页设计，不能丢历史或降低持久性。

未发现确定常态泄漏的范围：daemon profile/进程 ownership drain、Runtime command-lock/cancellation-gate 引用回收、Context host 超时/取消/关闭、search scheduler waiter 与 stale-result fence、健康 embedding 校验缓存与 helper poison、voice discussion joined cleanup、附件有界上传及失败清理。此结论来自静态覆盖，不能替代多小时 soak 或真实账号/网络验证。
