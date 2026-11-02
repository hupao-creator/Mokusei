# Detail 后台展示开销优化

## 范围与约束

基于 Astra 对 Thread 66724983-aed2-4d99-bc35-11b7db2f1922 的静态调研，
在基线 `63308c3` 重新核对实际代码。调研工作树仅供读取，不修改它。
本次独立工作树交付本地提交，不推送、不建 PR、不合并；main 由调用方顺序整合。

## 实现规格

- 仅在外层 reading stack 打开完成后暂停 Overview 展示投影及布局；打开、
  反向关闭及返回准备期间允许更新。初始恢复到 detail 的 stack 直接进入暂停态。
- workspace catalog 仍逐事件接收权威状态。Overview 的成员关系、筛选上下文、
  Moku 操作状态与选择合法性仍更新；隐藏期间只合并卡片筛选、排序、插件投影、
  content store 安装及布局的脏标记，不保存中间展示历史。
- 保留 mounted cards、快照、camera、输入草稿、操作和核心后台流程。
- 返回先以当前 catalog 补刷，等待 mounted Canvas 完成当前布局，然后获取返回
  frame。已删除或归档的来源卡不再提供返回目标。快速反向关闭无需等待隐藏恢复。
- 切换路由、关闭、失焦、断线恢复或卸载时，旧准备任务不得发起过期关闭；
  强制直接返回仍同步补刷，并由正常 Canvas 请求完成布局。
- 当前仅优化 Overview。Settings、Git 周期和 reader 的其他工作保留，避免扩大
  runtime、通知、Voice、缓存或配置发现的生命周期改动。

## 验证

复用 production model/catalog/content/canvas/reading stack 的集成测试，覆盖隐藏
更新、删除/归档、authority 替换、扩展变化、搜索取消/恢复、路由替换/取消和返回
准备。保留现有卡片身份/草稿、camera、返回中间帧等回放判据。
同机对照若执行，仅声明实测的模型工作量与耗时，不外推整机 CPU、GPU 或能耗。

### 本地结果（2026-11-03）

环境为同一台 arm64 Mac，macOS 26.5.1、Swift 6.3.2；原生测试显示为
2x backing scale，系统 Reduce Motion 关闭。未采集芯片/温度或进程 CPU。

- 最终 production sources 已通过 Swift build-tests，以及 11 项受影响集成测试：
  `NativeOverviewMembershipTests` 全部方法，加上 Search 的 paused response、
  scope/cancelled response 和 live revisions 三项。包含真实 mounted content store。
- `make lint` 通过（架构/静态注册/no-Node、gofmt、go vet）。
- 最终构建上的 `--overview-mounting` 原生回放 11 项通过，新增断言确认暂停
  期间没有新增布局求解，恢复后保留实际 TextField 实例、草稿和 mounted identity。
- 最终构建上的 `--moku-landing` 完整 workspace 回放 10 项通过，覆盖隐藏
  更新/归档、viewport 改变、手动 camera、最新返回 frame、隐藏 Moku 操作状态、
  切换线程、断线/新 authority 恢复、删除后的直接返回和打开中途反向关闭。
- 最终构建上的默认 reading 原生回放 14 项通过，包含 preparation 等待/旧任务
  取消、失焦时完成已接受的 Close、真实 AppKit 中途反向返回及原有几何判据。
  `OVERVIEW_RETAINED_RETURN_CONFIRMED` 已输出，原有中间帧保留。
- 共 46 项受影响测试/原生回放通过，无 skip。复现命令：

  ```sh
  xcrun swift test --package-path app/macos --force-resolved-versions --disable-index-store -j 2 \
    --filter 'NativeOverviewMembershipTests|NativeOverviewSearchTests/(pausedPresentationRejectsOldSearchResponseAndRestartsOnReturn|bodyQueriesKeepTagScopeAndRejectCancelledOrLateResponses|liveRevisionsAndRefreshesKeepCommittedSemanticCards)'
  MOKUSEI_SWIFT_SKIP_BUILD=1 python3 tools/verification/reading-presentation/run.py --overview-mounting
  MOKUSEI_SWIFT_SKIP_BUILD=1 python3 tools/verification/reading-presentation/run.py --moku-landing
  MOKUSEI_SWIFT_SKIP_BUILD=1 python3 tools/verification/reading-presentation/run.py
  ```

  三个 native 回放串行执行，复用上一步构建产物，遵守共享图形会话锁。
- 同机 Debug 对照使用同一构建、同样的 catalog 输入，以展示 gate 开/关模拟
  原来持续展示计算与暂停展示两条路径；顺序为开启、暂停、暂停、开启。
  不运行真实 agent，不读取用户数据。40 张卡片，80 次更新，每次只改变一张卡片。

| 路径 | 80 次更新中的展示输入遍历 | 事务总耗时 | 恢复时模型补刷 |
| --- | ---: | ---: | ---: |
| 持续展示，两轮 | 每轮 3200 次 | 82.26 / 81.14 ms | 已开启，无补刷 |
| 暂停展示，两轮 | 每轮 0 次 | 30.49 / 30.51 ms | 0.83 / 0.96 ms |

该指标计数的是进入卡片展示循环的输入（Git extension factory 调用），
不是实际 cache miss/plugin snapshot 构建次数。耗时包含真实 catalog 安装与
Overview 接收；恢复耗时只包含同步模型投影，不包含原生布局、绘制或返回动画。
没有采集全 app CPU、FPS、GPU 或能耗，不能据此给出这些指标的改善百分比。
权威成员关系/上下文等后台成本仍在；本次不声称消除 detail 的全部后台开销。

本地原始日志与回放证据保存在 `.scratch/detail-background-optimization/` 和
`.scratch/reading-presentation/`。首轮 Swift 构建发现测试 fixture 参数顺序错误，
已修正；首轮 native reading 回放在执行测试前因其它任务持有图形会话锁退出，
未干预对方进程，锁释放后使用同一构建重跑通过。

## 整合交集

主要交集是 Overview model/canvas、外层 workspace reading composition 和共享
reading stack；整合时保留主分支并行修改的路由、reading、Note/Voice 与状态接收
语义。最终合入版本仍需运行实际 required checks 及 Complete coverage。

只读查询时远程 main 为 `8ca887b832aae6dd788781bb36df0b080533ba7f`；
本地基线在它之后有 7 项尚未推送的顺序整合提交。未 fetch 或修改任何共享 ref。
传统 branch-protection 接口返回 404，但实际 rulesets 要求 strict
`Complete coverage`、PR 及 review-thread resolution；不能把 404 当作无门禁。
查询时 main CI run `41475926061` 的 Native verification/Complete coverage 失败，
PR #225 的旧提交检查成功，均不能认证本次本地提交。

本次未运行托管 CI、完整本地 `make check`、signed production package 回放，
未验证整合后的最终提交。调用方需保留最新 main 的并行修改、复核交集并对最终
整合提交执行 Complete coverage；本地结果不能替代该门禁。
