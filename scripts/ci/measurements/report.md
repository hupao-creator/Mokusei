# CI 优化记录（2026-11-02）

> 以下为原始交付时的历史记录。后续真实 Actions 对比、失败诊断和第二轮取舍见
> [托管验证报告](hosted-report.md)。

## 交付状态与目标

已完成最近 50 次远程运行的原始 job/step 采集、保护规则检查、缓存调查、
调度与缓存修改、本地连续构建及受影响验证。**优化后的托管 Actions 尚未运行，
因此没有可认证的托管前后加速比例，也没有完成基于候选 Actions 的第二轮优化。**

本轮由调用方管理 detached worktree；环境指令要求保持 detached HEAD、不创建或
切换分支、不操作共享 refs，并由调用方集成。提交直接基于核实的远程 main
`2972115af0094f875b9674fe7672c23302443925`，只包含本次 CI 修改；
起点中其他任务尚未合入 main 的两个提交未纳入交付。没有推送 main、创建远程分支、
修改保护规则、取消其他任务的运行或删除其他任务的缓存。

供调用方使用的专用分支名建议为 `ci/optimization-20261102`；该分支**尚未创建**。
提交 SHA 由最终回复提供。不能把本次本地通过作为远程必需检查通过。

## 基线与采集口径

使用 `hupao-creator` 的本机 `gh` 身份读取远程；初始认证/网络检查间歇性失败，
后续成功获取 50 次运行及全部 50 份 job 元数据，包含历史 attempt。
原始快照见 [baseline-jobs.json](baseline-jobs.json)，规则见
[baseline-rules.json](baseline-rules.json)，缓存清单见
[baseline-caches.json](baseline-caches.json)。离线重算：

```sh
python3 scripts/ci/profile.py --input scripts/ci/measurements/baseline-jobs.json --output /tmp/ci-baseline
```

50 次运行覆盖 2026-10-31 08:37:59 UTC 至 2026-11-02 02:39:43 UTC：

| Workflow | 成功 | 失败 | 取消 | 跳过 | 采集时运行中 |
| --- | ---: | ---: | ---: | ---: | ---: |
| CI | 7 | 24 | 3 | 0 | 3 |
| Overview performance | 0 | 6 | 0 | 3 | 0 |
| 三个临时诊断 workflow | 1 | 2 | 0 | 0 | 0 |
| `.github/workflows/ci.yml`（未正常建立 jobs） | 0 | 1 | 0 | 0 | 0 |

只有 7 次成功且完整执行的普通 CI 进入下表。保留其他失败、取消、跳过和运行中样本，
不把它们当作快速成功；失败后的复用 job 不算新的 runner 执行。p90 使用 nearest-rank，
样本仅 7 个，因此 p90 等于最大值。各列分别取中位数，不能直接相加。

| Job | n | 排队中位数 / p90（秒） | runner 执行中位数 / p90（秒） | 准备中位数 | 显式构建中位数 | 验证命令中位数 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Determine verification scope | 7 | 3 / 3 | 5 / 7 | 3 | 0 | 0 |
| Go / Linux | 7 | 3 / 3 | 91 / 115 | 13 | 15 | 44 |
| Integration / runtime | 7 | 3 / 13 | 184 / 194 | 12 | 0 | 169 |
| Integration / adapters | 7 | 3 / 5 | 280 / 288 | 14 | 0 | 261 |
| macOS / Native verification | 7 | 3 / 411 | 1681 / 1943 | 67 | 309 | 1384 |
| Complete coverage | 7 | 3 / 4 | 8 / 10 | 2 | 0 | 0 |

“准备”包含 checkout、setup、缓存及收尾；“验证命令”来自 Actions step 的墙钟时间，
包括命令内部编译与 fixture 生成，**不是纯测试 CPU 时间**。其他步骤和 step 之间的
runner 时间保留在分析 JSON 中。端到端中位数为 **1853 秒（30 分 53 秒）**；
各 job runner 执行时间总和的中位数为 **2251 秒（37 分 31 秒）**，不是计费估算。

主要瓶颈是 macOS：普通 Swift suite 617–645 秒、图形交互回放 342–456 秒、
显式构建 208–392 秒，fixture 生成 145–161 秒。Linux 并行 job 没有占据关键路径。
[41197580841](https://github.com/hupao-creator/Mokusei/actions/runs/41197580841)
的 macOS 排队为 411 秒，说明账号容量也会影响总时间。

可复核的最近 main 成功运行是
[41327617814](https://github.com/hupao-creator/Mokusei/actions/runs/41327617814)：
main `2972115`，macOS 1831 秒，其中 Swift 构建 342 秒、普通 suite 624 秒、
图形回放 414 秒；端到端 1853 秒。历史样本有不同产品提交和缓存状态，不能当作
同一代码的严格 A/B。最新失败
[41376267744](https://github.com/hupao-creator/Mokusei/actions/runs/41376267744)
发生于普通 Swift suite 和完整性审计；此前多个失败发生于图形回放。
本次没有重跑、修改这些产品断言或声称它们是误报。

## 修改与取舍

1. **只取消过期 PR。** PR 按 PR 号分组；push/dispatch 按 run ID 分组。
   main 每次提交均运行全部检查，包括文档提交。只把 `cancel-in-progress` 改成
   false 仍可能让 GitHub 替换 pending main，故 main 也必须使用独立 group。
2. **保留安全文档路径。** 只给 PR 启用既有保守路径/文件模式分类；不增加 workflow
   级 `paths-ignore`，不改变必需检查名。代码、未知路径、空 diff、可执行文件、
   symlink、运行时资源 README、混合修改和 dispatch 仍完整运行。
3. **统一 Go 缓存。** 所有 lane 使用 setup-go 内建缓存，删除 Go 主 job 的手工重复
   module/build cache 命名空间。没有增加 Node npm 缓存：协议回放不安装 npm 依赖，
   没有 lockfile。没有 Cargo manifest 或 Rust 源码，Rust 缓存不适用。
4. **限制 Swift 缓存增长。** 之前每个 PR/提交保存约 400 MB；改为仅 main 可以保存
   与工具链、依赖、显式 generation 对应的不可变种子。PR 只恢复、不保存。
   每次仍构建当前源码并重新发现、执行和审计全部方法，缓存不能提供测试结果。
   固定种子会随源码演进变旧，可能比最新提交快照多重编译；这是容量与构建时间的
   取舍，尚待托管对比，不宣称构建已加速。
5. **保存预算。** 种子未压缩大小上限 2 GiB，仓库用量加该大小须不超过 9 GiB，
   给并行 Go/CLI 写入留 1 GiB。用量读取失败或超限时只跳过保存。它是尽力预算，
   没有全局锁，不能保证其他并行写入不会越过 10 GiB。
6. **保留现有并行边界。** Go、runtime、adapters 已在 Ubuntu 独立执行；macOS
   专属的 AppKit、Swift、Darwin profile/clipboard 保持原生。图形回放依赖独占
   WindowServer 会话，继续串行；不为缩短数字重引入多 macOS runner、跨 runner
   构建传输或删减慢测试。没有实测依据支持新增分片。
7. **保留预编译工具。** Go 由 setup-go 提供，Swift/Metal 使用 runner/Xcode 工具链；
   扩展 CLI 已使用固定版本的平台预编译 npm 包，没有新增 cargo/go install。
8. **增加可复用分析。** `profile.py` 收集最近 50 次或指定 run 的全部 job/attempt 页，
   输出原始 JSON、统计 JSON 和 Markdown。按 full/documentation/extended scope
   分组，避免文档快路径混入完整 CI。`run-summary.py` 共用耗时分类。

缓存初次 usage 查询为 30 项、10,662,602,296 字节（9.93 GiB）；稍后的清单及再次
usage 查询均为 **31 项、11,073,207,109 字节（10.31 GiB）**。后一次清单中 Swift
缓存 24 项、9,872,442,413 字节；旧 native-go 4 项、756,428,802 字节；setup-go
2 项、247,305,832 字节；手工 Linux Go 1 项、197,030,062 字节。
这是不同时间的快照，不应误报为本次优化造成的增减。没有删除已有条目；当前预算
会拒绝额外 Swift 保存，历史项仍依赖 GitHub 过期/逐出策略。

第二次本地复核据此增加了仓库整体保存预算，并隔离文档耗时统计。这是本地审查
修正，**不是已完成的托管第二轮实验**。

## 本地连续构建与验证

产品源码均为 main `2972115`，附带本次 CI 脚本改动；Go 对象缓存使用 worktree
内全新的目录，module 下载缓存已有，因此第一次不是完全冷机/冷下载。

| 连续执行相同命令 | 第一次 | 第二次 | 结论 |
| --- | ---: | ---: | --- |
| `./scripts/go.sh build ./...`，Go 1.27.3 | 20.872 秒，exit 0 | 11.799 秒，exit 0 | 第二次少 43.5%；仅说明本机编译缓存有效 |
| Swift 全部 test targets，使用 CI 构建 flags 和隔离缓存路径 | 2.255 秒，exit 1 | 1.506 秒，exit 1 | 嵌套 `sandbox-exec` 被本机执行沙箱拒绝，无构建收益结论 |
| 同上，仅本地加 `--disable-sandbox` | 3.086 秒，exit 1 | 1.262 秒，exit 1 | 依赖仓库获取失败，无有效 Swift 缓存对比 |

额外一次 Go 热构建 `-x` 日志统计：**0 次 compile、0 次 cgo、45 次 link**。
`go build ./...` 没有保留多个命令的最终输出，剩余时间包含重新链接；不能据此说
对象缓存无效。未通过额外缓存几十个可执行文件扩大 10 GiB 压力。
Swift 失败日志与构建 receipt 见本目录的 `local-builds.json` 和 `swift-build-failure.log`。
未修改生产 Swift 构建参数来绕过这些本机限制。

已通过：

- `verify-ci-control.py`：真实临时 Git 历史覆盖 PR 文档/main 全量、混合修改、rename、
  symlink、资源 README、空 diff、dispatch；原生执行审计、deadline 和本地 owner
  CLI 控制全部通过。这些控制 fixture 不代表真实 Swift 渲染通过。
- 生产 `run-summary.py` 使用保留的真实 GitHub 元数据跑通，正确输出 342 秒构建、
  3 秒排队并排除未执行 lane；外部 `gh` 边界为受控替身。
- 实际 workflow 缓存预算 shell 覆盖可保存、种子过大、仓库满、API 不可用四种情形。
- YAML 解析、全部内嵌 Bash 的 `bash -n`、Python 编译、architecture/static registration
  边界检查，以及 diff/本地文档链接检查。

完整 Swift/native 测试、图形回放、托管 `Complete coverage` 没有运行；未执行等价的
本地全套 `make check`。actionlint 预编译包下载因网络失败而未能运行；YAML/Bash
检查不能替代 Actions 的表达式与 runner 验证。仓库 pre-commit lint 已通过，包含
architecture/static registration、gofmt 检查及 `go vet ./...`。

## 远程规则及待完成的真实对比

读取的实际 main ruleset `26004586` 要求 up-to-date PR、GitHub Actions 的
`Complete coverage`（integration 15368），并要求讨论已解决；必需批准数为 0。
传统 branch-protection 接口返回 404 不表示没有保护，规则实际来自 ruleset。
本次只读核实，没有改规则或旁路。文档 PR 仍产生 Go/汇总检查；原生 lane 的明确
scope 跳过不会留下缺失的 required check，scope 失败也不能产生成功汇总。

交付前核实远程 main 仍为 `2972115`；当时 #224、#222、#220 存在在途 CI。
不要取消这些任务；#220 的产品改动没有包含在本次提交中。

调用方将本提交推到专用分支并打开 PR 后，应针对该 PR 的**最终 SHA**采集候选 run：

```sh
python3 scripts/ci/profile.py --run CANDIDATE_RUN_ID --output /tmp/ci-candidate
```

需要记录相同 full scope 下的排队、准备/缓存、构建、每段测试命令、runner 总和与
端到端时间；成功后至少再观察一次同依赖热缓存运行，注明工具链/image、source SHA、
attempt、缓存命中及样本数。固定种子的首次发布若被预算拒绝也必须记录。
对照以上 7 次历史样本只能做趋势判断，严格 A/B 应固定产品代码和 runner/image。
根据候选数据再判断种子陈旧成本和后续可独立拆分的非图形工作。

| 托管对比指标 | 修改前成功样本中位数 | 修改后 |
| --- | ---: | --- |
| 全 run 端到端 | 1853 秒 | 未运行 |
| 全 run runner 执行总和 | 2251 秒 | 未运行 |
| macOS runner 执行 | 1681 秒 | 未运行 |
| Go / Linux runner 执行 | 91 秒 | 未运行 |
| 仓库缓存用量 | 最近快照 10.31 GiB | 未应用/未测量 |

若候选失败，先读取失败 job 的断言、进程状态、日志/截图与排队时间，再决定修复或
`gh run rerun RUN_ID --failed`。不能拿历史绿色、失败后缩短的耗时或本机 Go 的
43.5% 当作候选已通过或 CI 已加速。
