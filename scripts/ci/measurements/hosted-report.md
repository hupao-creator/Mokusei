# 托管 CI 实测与第二轮（2026-11-02）

> 此处各轮按当时的 workflow 记录；后续审查按照当前仓库要求恢复了同一 main
> ref 的新提交取消旧运行，历史的 main 独立分组描述不代表最终方案。

用户授权仅推送 CI 专用分支。原提交 `74b6e26` 已保留，专用分支
`ci/optimization-20261102` 已推至指定远端，并创建
[PR #225](https://github.com/hupao-creator/Mokusei/pull/225)。没有推送或合并 main，
没有修改保护规则、取消其他任务或删除缓存。原工作区未被本任务修改。

## 对照与结果

除了[原始报告](report.md)的七次历史成功样本，本轮复用了同产品源码
`1593e6347457f8de4c5e2e517aa6ed498a5f7963` 的 main 成功运行
[41380174891](https://github.com/hupao-creator/Mokusei/actions/runs/41380174891)。
候选 `d7a4bd567967167a3f672be7974b5a7daf4fb335` 相对它只有 CI 文件差异。
这是独立 hosted VM 的近邻比较，不是同一机器、完全相同缓存的严格 A/B。
每个新对照仅一个样本，不能认证稳定加速比例。

| 指标（秒） | 历史成功中位数 n=7 | 同源码 main n=1 | 首轮候选 n=1 |
| --- | ---: | ---: | ---: |
| 端到端 | 1853 | 1578 | 1667（失败，不算成功加速样本） |
| runner 执行总和 | 2251 | 2135 | 2246（失败） |
| macOS runner | 1681 | 1553 | 1644（失败） |
| macOS 排队 | 3 | 3 | 3 |
| Swift 构建与发现 | 309 | 206 | 218 |
| Go / Linux runner | 91 | 91 | 139 |
| runtime runner | 184 | 187 | 181 |
| adapters runner | 280 | 290 | 269 |

原始 job/step/attempt 元数据见 [paired-baseline.json](paired-baseline.json)
和 [round1.json](round1.json)。用 `profile.py --input FILE --output DIR` 可重算。
失败运行没有进入成功样本聚合；上表的失败耗时仅用于诊断。
首轮 run 从 03:03:13 UTC 到 03:31:00 UTC；attempt=1，无重试。
job 排队各为 2–3 秒，不能把这一 attempt 的耗时当成重试总等待。

同源码 main 使用 macos-26-arm64 `20261026.0455.2`、macOS 26.6.2、Xcode 26.6。
其 Swift 恢复键为 `native-2972115af0094f875b9674fe7672c23302443925`，
压缩归档 407,693,778 字节。首轮 Go 主 job 使用 setup-go 精确键，
归档 101,491,451 字节；这比此前专用缓存更小，不代表其编译覆盖更完整。
候选使用相同 image 版本，Swift 恢复 `native-1593e6347457f8de4c5e2e517aa6ed498a5f7963`，
归档 410,960,763 字节；因此两次编译缓存并不相同。候选 PR 没有保存新的 Swift 归档。
候选完整日志和截图保留在
[attempt 1 artifact](https://github.com/hupao-creator/Mokusei/actions/runs/41380935021/artifacts/13113803960)。

## 首轮失败及证据

[41380935021](https://github.com/hupao-creator/Mokusei/actions/runs/41380935021)
的 Linux 三个 job、fixture、普通 Swift suite、interop 均成功。
原生 `tag-glass-captures` 进程退出 1，执行 72.025 秒；其余 native checks 成功。
最终审计及 `Complete coverage` 因此失败，未超时，未跳过失败断言。

具体失败是 `titleReversalAndVisibilityCancellationSettlePixels()` 的
`No qualifying current WindowServer frame during incoming`。
判据要求捕获到墨迹比例在 10%–60%、帧龄小于 50 ms 的实时帧。
保留的 [window-frames.json](round1-failure/window-frames.json) 显示每批只分析
最新帧：incoming 44/49/51/52 墨迹为零，57 为 96,937 / 141,325 ≈ 68.6%，
62 已完全显现。已查看 blank 41、incoming 55/56 截图；中间帧中存在部分显现。
该证据指向捕获/分析时序，尚未证明产品无回归或失败是误报。
完整断言日志和原生执行报告见 [失败目录](round1-failure/)。

不放宽 10%–60% 或 50 ms 判据，不删除中间帧，不增加 skip。
同源码 main 成功也不能替代候选失败。第二轮改动有独立缓存动机，
不是对首轮同提交碰运气重跑；如第二轮通过，仍保留这次未解决的时序失败记录。

## 第二轮取舍与验证

首轮统一 Go 缓存后，Go 主 job 为 139 秒，同源码 main 为 91 秒。
其中 `go vet` 为 19 秒、模块 race 为 33 秒；main 的模块 race 为 26 秒。
样本不足以完全隔离缓存和 VM 负载，但足以撤回未经证实的统一缓存收益：
第二轮恢复 Go 主 job 已有的专用缓存，其他 lane 继续使用 setup-go 缓存。
专用键只随依赖/工具链变化，不按提交增长；该 lane 关闭 setup-go 缓存，
避免同一 job 双重恢复/保存。第二轮托管结果将验证这一回退的实际成本。

保留 main 独立 concurrency、PR 过期取消、Swift main-only seed 与保存预算。
原生构建、普通 suite、图形回放和完整审计全部保留。没有增加 macOS runner。
基线 fixture 的 voice 回放约 109 秒，同时验证真实配置拒绝、清理和预热；
未将其简化成静态 JSON 导出。不能为了缩短数字删除这些覆盖。

本地 actionlint 1.7.12、实际 CI control verifier 和 diff 检查已通过。
未重复本地全套 `make check`，真实 Swift/native 由 hosted CI 执行。
最终分支的托管结果和第二轮数值将追加至 PR 说明；本文件记录第二轮推送前证据，
不声称尚未执行的第二轮通过。实验固定产品源码以便比较；期间 main 已继续前进，
本分支的实验结果不认证更新后的 main，也不用于绕过 up-to-date 合并门禁。

## 同产品源码的后续成功运行

[41387058958](https://github.com/hupao-creator/Mokusei/actions/runs/41387058958)
是第二轮候选 `f0db5ba` 的成功完整 dispatch；相对上述 main `1593e63`，
差异仅在 CI workflow、脚本和记录，没有产品源码变更。
两次都只有 attempt 1，均没有重试，也没有以失败或文档快路径替代完整执行。

| 指标（秒） | main 41380174891 | 候选 41387058958 |
| --- | ---: | ---: |
| 首次触发到结束 | 1578 | 1834 |
| 本 attempt runner 执行总和 | 2135 | 2402 |
| macOS 排队 / 执行 | 3 / 1553 | 3 / 1811 |
| macOS Swift 构建 | 206 | 305 |
| macOS 验证命令 | 1279 | 1422 |
| Go / Linux 执行 | 91 | 111 |

两台均为 `macos-26-arm64` image `20261026.0455.2`、macOS 26.6.2、
Xcode 26.6。两次恢复相同的 setup-go macOS 缓存，但 Swift 构建缓存不同：
main 恢复 `native-2972115`（407,693,778 字节），候选恢复
`native-9465c37`（417,478,728 字节）。恢复键是前缀匹配，不能把这两次
视为相同缓存、相同机器的严格 A/B；每边一个成功样本也不能单独归因差距。
此对比的实际结果是端到端增加 256 秒，不能宣称整体加速。它早于后续的
job 内模块缓存尝试，也不能认证更新后的 PR 合成提交。

原始候选 job/step/attempt 元数据见 [round2-success.json](round2-success.json)，
main 原始数据见 [paired-baseline.json](paired-baseline.json)。完整 macOS
作业日志保存在本地 `/private/tmp/mokusei-ci-performance-prior-comparison/`
并可从对应 run 获取；最终 PR 必须再与最新 main 比较实际缓存、排队和耗时。

2026-11-02 06:54:39 UTC 的 [仓库缓存用量快照](cache-usage-followup.json)
报告 28 项、11,070,791,376 字节（约 10.31 GiB），超过候选的 9 GiB
种子保存预算。若保存时的查询仍高于预算，workflow 会跳过新种子保存，
但仍执行构建与验证。GitHub 的用量接口约五分钟刷新一次；并行写入和逐出
也会改变实际用量，因此这不是实时数值，也不能归因于本 PR。

## `2a54a3b` 同树成功对照

[PR #239 run 41400177640](https://github.com/hupao-creator/Mokusei/actions/runs/41400177640)
的完整 CI 在 attempt 1 成功。其实际构建的合成提交 `61cdb6c` 与随后合入的
main `2a54a3b` 具有完全相同的 Git tree
`295ef433ee3bf4393a5374cdf739207e0bb81921`；构建清单也记录了合成提交。
[身份记录](baseline-2a54-identity.json)和[原始 job/step](baseline-2a54-success.json)
保留了可复核的数据。它是 PR 事件而非 main push；正常代码范围均为完整 CI，
但事件、缓存和独立 runner 不完全相同，不能当作同机严格 A/B。

| 指标（秒） | 成功对照 |
| --- | ---: |
| 首次触发到结束 | 1797 |
| 本 attempt runner 执行总和 | 2302 |
| macOS 排队 / 执行 | 4 / 1724 |
| macOS Swift 构建 / 验证命令 | 279 / 1370 |
| Go / Linux 执行 | 100 |

macOS image 为 `20261026.0455.2`，恢复的 Swift 缓存键以
`native-488b345` 结尾（428,600,923 字节）。#225 候选还改变了一个原生测试
的几何观察方式和 CI 缓存策略，最终比较应列出这些差异，不能把该成功 run
当作 #225 的 `Complete coverage` 或把耗时差全部归因于缓存。
