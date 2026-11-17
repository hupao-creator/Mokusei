# Runtime 边界测量报告

测量基线：`c17a3fcb270b8d862bbd9cc03ae18c45c4c133fd`。候选生产输入、二进制、命令和失败控制以同目录 manifest/sources/validation 为准；这些数值不认证当前构建。

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

## 测量限制

生命周期 revision 优化没有可靠的公开消费 barrier，未构造可能漏计后台扫描的伪微基准；其收益仅以静态少做工作及功能回归说明。两个 Runtime 场景保留正常后台服务，启动订阅引起的发布可能与短 warmup 后的测量重叠；进程级分配不能等同于单独列表/复制函数。`runtime-notify` 只等待 durable 更新与同步 callback，不等待异步 publisher 排空。没有测真实模型端到端延迟、GUI 帧率/GPU、硬件语音或多小时泄漏，不作对应改善声明。
