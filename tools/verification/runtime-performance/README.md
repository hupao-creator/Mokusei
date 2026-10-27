# Runtime 性能复现

本目录使用生产 Store、Runtime 和 Application host 的公开边界，在独立临时 SQLite 数据库上测量；不读取用户 profile、不调用真实模型。语义回归仍由 storage-workspaces、runtime、applicationhost、moku、codex 的可执行回放负责。

```sh
./scripts/go.sh build -trimpath -o .build/runtime-performance/after ./tools/verification/runtime-performance
.build/runtime-performance/after -scenario store-lifecycle-append -records 10000 -iterations 100 -samples 5
```

| 场景 | 一次 operation | records |
| --- | --- | --- |
| `store-noop` | 已准入 FIFO writer 的 `Flush` | 已有 lifecycle event 数 |
| `store-lifecycle-append` | 一个真实 durable event 追加事务 | 初始 event 数 |
| `store-work-read` | 一个事务内读取同一 active work 32 次 | 已有 event 数 |
| `runtime-list` | 通过 Runtime 读取 Thread 列表 | Thread 数 |
| `runtime-notify` | 真实 durable 更新 Thread 并同步通知订阅者 | 单 Thread 的 240 字节历史条目数 |
| `application-list` | 公开 application query → Records.List → 返回 ID | collection record 数 |

每个 sample 重建等规模初态；同步 setup、默认一次 warmup、GC 和 cleanup 不计入墙时。追加场景会在每个 sample 内增加 `warmup + iterations` 个事件，前后必须使用相同参数。每次 operation 的计时包含实际生产调用及结果断言。报告原始 samples，不以单次最优值代表结果。

JSON 记录可执行文件 SHA-256、Go 构建信息、平台、GOMAXPROCS、规模、每个 sample 的总墙时、用户/系统 CPU、吞吐、延迟中位数/p95、分配次数/字节、GC 后存活 heap 差值及进程 RSS 高水位。CPU/内存是当前进程整体指标，Runtime 后台任务包含在内；RSS 是进程自启动以来的高水位，包含 setup，不能当作单次 operation 的净内存。GC 后 heap 差值也不是资源泄漏证明。

`runtime-notify` 等待 SQLite 提交和同步 committed listener，不等待 50ms 异步 publisher 排空。后台发布只在恰好重叠时进入该样本，可能增加方差；该场景不能代表完整 publication 成本或前端收到更新的延迟。

两个 Runtime 场景都保留正常后台服务。初始化的 Store 订阅也会安排发布，未提供其完成屏障；短 warmup 后它仍可能与测量重叠。因此 `runtime-list` 是运行中 Runtime 的列表调用测量，进程 CPU/分配不能解读为单独 `readThreads` 的成本，也不能据此断言该函数的分配改善或回归。

剖析使用独立运行，不把插桩样本与普通样本比较：

```sh
.build/runtime-performance/after -scenario store-lifecycle-append -records 10000 -iterations 300 -samples 1 -cpuprofile /tmp/runtime.cpu
./scripts/go.sh tool pprof -top .build/runtime-performance/after /tmp/runtime.cpu
```

`-memprofile` 保存测量结束后、cleanup 前的存活 heap profile；CPU profile 只覆盖预热后的测量区间。`-label` 用于标注来源，但可执行文件 SHA 才是实际二进制身份。使用 `go build -overlay` 将改动的生产 Go 文件映射为基线 `git show <commit>:<path>` 内容，可在当前 detached worktree 用同一份 fixture 构建前后版本，无需修改其他树或 refs。新增 fixture 不应依赖新生产 API。

```sh
python3 tools/verification/runtime-performance/prepare_baseline.py c17a3fcb .build/runtime-performance/baseline
./scripts/go.sh build -trimpath -overlay=.build/runtime-performance/baseline/overlay.json -o .build/runtime-performance/before ./tools/verification/runtime-performance
./scripts/go.sh build -trimpath -o .build/runtime-performance/after ./tools/verification/runtime-performance
```

同一 overlay 也可用于 Moku `-performance` 和 Codex `-stream-performance` 的可执行回放。基线不能运行依赖新 API 的完整新增回归；性能 fixture 使用原公开 API。先单独编译，再在没有编译/其他采样的窗口顺序运行两个二进制。

运行前协调独占 CPU 时段；不要并行构建、回放、GUI 或截图。这些是本地边界微基准，不能据此宣称真实模型端到端延迟或 GUI 帧率收益。具体规模、原始结果、环境、验证和未测边界见 [本次审计报告](AUDIT.md)。
