# Moku runtime 性能审计

基线：`c17a3fcb270b8d862bbd9cc03ae18c45c4c133fd`。当前 detached worktree 独立交付；不操作 main、其他工作树、push 或 deploy。接管保留原线程未提交改动与已完成的静态 review；新增变化另做定向独立 review。

## 范围与修复规格

真实入口为 `cmd/mokusei-runtime → daemon/profile → composition → Runtime`。composition 注入 Moku coordinator、四 Harness、Store、Application/Context host、workspace/attachment/search/voice 服务；HTTP/NDJSON 由 transport 暴露。原生 GUI 是消费者，Overview/glass-world 热点归其他专项，本次不改。

| 已覆盖边界 | 本批处理 |
| --- | --- |
| 调度、admission、执行生命周期、取消/恢复、voice gate | Moku 排队改为可取消获取；保留已经准入的工作、独占范围和 Stop 本地结算排空 |
| 流式事件、状态、序列化、工具派发 | Codex 重复 reasoning status 不再强制刷新批处理；去掉无人读取的全文累计；固定工具 schema 绑定生命周期内编译一次，动态 target schema 仍每次发现 |
| 状态/快照/通知、缓存失效、数据归属 | committed notification 独立复制 opaque bytes；Thread/Application 列表用集合整理顺序；生命周期订阅按准确变化标记跳过无关提交，private observation 仍独立失效 |
| SQLite 持久性、lifecycle/receipt、I/O | 空事务不复制快照；只验证生命周期改动及受影响引用，event 删除仍全量校验；Work 单键读不复制全库 |
| Moku context、completion outbox、订阅和释放 | 仅目录 tag 需要解析时读取全部 Thread；durable outbox 路径不再另排入随后丢弃的 terminal record |
| Harness transport/retry/process、host/plugin、workspaces、attachments、search/embedding、voice | 完成静态覆盖；需其他专项协调或独立设计的发现见交接清单 |

规格来自用户本次明确授权：只修可复现机制，保持协议、状态语义、事件顺序、取消/恢复与持久性。使用现有公开边界和本地 fixture；不做真实模型/付费调用、不删事件、不放宽校验、不以 debounce 降低 durable admission。新增缓存只有 binding 内编译结果和快照内两个 scalar revision，没有全局无限 map。

## 触发、根因和修复

1. **长历史下的 Store 写入**：每次 lifecycle 更新重复解码全部旧 event/work/outcome；Flush 也复制全部 maps。改为可信已提交快照上的增量引用验证，保留打开数据库和删除 event 的全量验证。outcome 新增会重新检查同 consumer 的既有 active work；子事务、回滚、异常和取消不发布 revision。
2. **流式提交带动无关扫描**：live/durable lifecycle 订阅每个 Store revision 都读历史。增加 EventRevision/LifecycleRevision，durable 另检查被观察私有会话的 RecordHash；同一快照构造通知，不把 channel 次数当事件数。
3. **大 Thread 的 committed 通知**：完整原生历史经 JSON marshal/unmarshal 往返只为复制给 listener。现在描述字段仍深复制，opaque bytes/Transcript 每个 listener 独立复制；不承诺 raw JSON 的空白字节规范化。列表的 order 成员检查由重复线性查找改为一次集合。
4. **Moku 每次发送/工具调用重复准备**：无目录 tag 或已有显式目录 mention 仍读所有 Thread；固定 tool schema 每次重编译。读取移到真正需要的分支；编译结果只活在固定 binding，错误仍进入既有 audit/caller-error 路径。production outbox 已拥有 terminal delivery，因此避免再保留冗余完整 record。
5. **取消等待**：旧 mutex 只能在前一个 native admission 结束后检查取消，保留 waiter/input claim。可取消 gate 允许 waiter 及时退出，获取 token 后再次检查取消；首次调用和运行中的 owner 语义不变。
6. **Codex reasoning 流**：native 每个 chunk 发 delta 后再发相同 status；status 触发 flush 再额外 commit，绕过 50ms 合并。保留首次/真正变化的 status，跳过已经提交的相同分析状态；完成、interrupt 和失败 flush 不变。
7. **媒体结束后的 relay 等待者**：尚未开始 target admission 的 relay worker 只等待 service context，关闭媒体后仍被慢 owner 阻塞。等待阶段关联媒体 lease，获取 admission 后继续使用原 service context；失效请求提前返回，不再读取完整当前会话。已经开始的 native admission 保持不变。

## 测量与验证状态

生产修复已分别提交为 `d9038e700`（Store/Runtime/Application host）、`7ac1437f4`（Codex）和 `1f8e4f51c`（Moku）。保留旧线程两组独立静态 review；接管后的排队见证与 relay 修复再由独立 Astra Max 审查，无剩余阻断项。

已通过 `make check ARGS=`，以及 `storage-workspaces`、`runtime`、`applicationhost`、`moku`、`codex` 五个完整 `go run -race` 回放。首次 Application host fixture 缺必需 settings 初态，补齐行为/测量两处 setup 后重跑通过；首次 make check 被环境继承的 `ARGS=--fresh` 阻断，显式清空后完整通过，没有将失败算作验证成功。命令和日志身份见 [validation.json](results/20261025/validation.json)。

排队取消先观察真实生产队列的阻塞栈，再发取消。旧 mutex 保留等待者；只加 `ctx.Err()` 前检的负控能通过 pre-cancel，却无法通过 queued-cancel；修复版两者均退出，owner 保留。Relay 回放先观察 8 个阻塞等待者和 1 个 owner，媒体停止后只剩 owner，释放后 owner 提交且旧请求均不入史。仅恢复旧 delegate 的单点负控仍留下 8 个等待者，修复版通过。语音 pre-cancel 的计时包含人为持有 teardown 的 100 ms，不能当作线上取消延迟。

2026-10-25 14:24–14:43（含等待其他专项检查的间隔）完成 60 个有效运行区段，每场景、每版本 6 个样本；另 4 个区段检测到并发检查，保留在 [excluded](results/20261025/excluded) 并排除。环境为 Apple M1 Pro / 10 核 / 16 GiB、macOS 26.5.1、Go 1.27.3，GOMAXPROCS=4。对照使用相同 fixture 和基线 Go overlay，先 before→after、再 after→before，每次 3 个样本；Runtime/Store 每个样本重建初态。同步 setup、warmup、GC、cleanup 不计时。

[manifest.json](results/20261025/manifest.json) 保存命令、二进制 SHA、时间、宿主负载与重叠检查；[sources.json](results/20261025/sources.json) 保存源码身份。恢复测量先等 30 秒无相关编译/测试/GUI fixture，运行中每 0.5 秒检查一次。这里的“有效”指未观察到此类重叠，**不代表机器完全空闲**；用户宿主和 WindowServer 一直运行。全部原始 samples 与 min/max 见 [summary.json](results/20261025/summary.json) 及同目录原始 JSON。

下表为每样本平均操作耗时的跨 6 样本中位数；不是最优单次延迟，也不是线上端到端收益。记录规模为 10,000；通知场景是一个 Thread 的 10,000 条、每条 240 字节历史。

| 生产边界 / 一次操作 | 基线 → 修复（ms） | 进程分配 / 操作，基线 → 修复 |
| --- | --- | --- |
| Store Flush | 0.3135 → 0.000739 | 437,249 → 264 B |
| durable lifecycle 追加 | 18.620 → 1.191 | 5.66 → 0.440 MB |
| 事务内 Work 读取 32 次 | 10.604 → 0.0369 | 14.45 → 0.0106 MB |
| Runtime Thread 列表 | 151.630 → 33.376 | 32.92 → 41.64 MB，含后台工作，不作独立函数分配结论 |
| SQLite 更新 + 同步 committed callback | 22.462 → 14.292 | 80.09 → 51.92 MB，未等待异步 publisher |
| Application collection 列表 | 136.127 → 12.789 | 10.43 → 7.68 MB |

Moku 的 64 Threads × 32 KiB 固定历史下，无目录选择发送为 3.661→0.204 ms、5.45→0.108 MB/操作，每 20 次发送的全 Thread 读取从 20 次变为 0；显式目录 mention 为 3.640→0.209 ms。需要解析 tag 的对照保持 20 次读取，耗时 3.669→3.672 ms，未见提升。固定 `talk` 有效调用为 0.200→0.180 ms、111.5→91.3 KB；其小幅耗时变化不宜外推，分配下降更稳定。动态 target schema 的新鲜度由行为回放验证。

Codex 512 个 32 字节 reasoning chunk（首 chunk 在计时外）为 155.916→30.402 ms；实际 Commit 从 **1,027→6**，提交总字节从 **26,388,354→301,780**，父进程分配从 138.80→41.01 MB。64 chunk 与纯文本对照也已保存；各规模/类型所有前后样本的规范化终态 SHA 一致。该 fixture 经过真实 JSONL、adapter 和投影，使用内存提交端口，排除了 SQLite，CPU 不包含子 peer，不能代替完整产品流式成本。

四类 Moku 取消场景各 6/6 修复样本在 owner 释放前返回，基线均为 0/6。最终 precheck-only 负控及命令身份见 [queue-controls.json](results/20261025/queue-controls.json)。基线被人为持有 250 ms 后才释放，这证明等待取消机制，不是线上延迟估计。

## 局限和交接

生命周期 revision 优化没有可靠的公开消费 barrier，未构造可能漏计后台扫描的伪微基准；其收益仅以静态少做工作及功能回归说明。两个 Runtime 场景保留正常后台服务，启动订阅引起的发布可能与短 warmup 后的测量重叠；进程级分配不能等同于单独列表/复制函数。`runtime-notify` 只等待 durable 更新与同步 callback，不等待异步 publisher 排空。没有测真实模型端到端延迟、GUI 帧率/GPU、硬件语音或多小时泄漏，不作对应改善声明。

其他已确认算法/阻塞机制及未实测候选、复现方法和文件归属见 [HANDOFF.md](HANDOFF.md)。这些项目没有被冒充为本批已修；待父协调分配给 plugin/全项目专项或后续独立性能批次。
