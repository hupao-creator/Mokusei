# PR 合成提交修复与第三轮测量

本文件记录推送前的实现与本地证据。最终 PR 合成提交的完整托管结果、
排队和作业耗时更新在 [PR #225](https://github.com/hupao-creator/Mokusei/pull/225)，
不以此前分支 dispatch 的成功替代 PR 必需检查。用户现已授权通过 review
和实际门禁后合并；失败的 PR 不合并。

## 原始失败与可修复边界

- PR 首轮 `41380935021`：incoming 最新帧从空白跳到 68.6% 墨迹，
  没有满足原 10–60% 且帧龄小于 50ms 的条件。
- PR 第二轮 `41383986692`：Overview 的相邻 x 采样为 740、459，
  间隔 67.186ms，跨过原 472–708 中点区间。该次实际会展开，
  但没有合格的中点观察，不能宣称生产动画没有问题。

两次都有真实不完整观察；没有证据将它们判为误报。此前未指定 sleep
tolerance，也未为独立 AppKit runner 请求延迟敏感活动。Swift 的
[ContinuousClock 契约](https://github.com/swiftlang/swift/blob/main/stdlib/public/Concurrency/ContinuousClock.swift)
允许未指定 tolerance 时选择唤醒合并策略；这不是上述全部延迟的已证明根因。
本轮修复这一可归因的观察器配置缺口：被动 geometry/title 的原 10ms
休眠指定零 tolerance，runner 使用 user-initiated priority 和进程生命周期内
的 latency-critical activity。没有扩大几何/墨迹区间、50ms 帧龄、三秒期限，
没有延长动画、重试输入、删除帧或增加 skip。OS/executor 抢占仍可能失败，
必须用新的实际采样和原断言验证。

## 有证据的关键路径尝试

此前成功固定源码运行 `41387058958` 的 macOS job 为 1811 秒，
构建 305、fixtures 159、ordinary suite 645、interop 162、native 428 秒。
Go 不在关键路径，恢复 Go 专用缓存不能解释整轮加速。

`NativeReplay` 过去为每个 launcher 创建全新的 SDK module cache。
本轮仅在同一 CI job 内通过 `MOKUSEI_NATIVE_MODULE_CACHE` 复用它，
每个 launcher 仍编译当前 staged sources、链接/签名新 app、启动独立进程，
没有编译对象/可执行程序或测试结果的复用。编译器负责标准依赖验证。
缓存不上传、不跨 runner，不引入额外 macOS runner；本地未设置该变量时
仍使用私有缓存。`launch.json` 新增 staging/compiler 时间以区分真实收益。

| 本地编译观察（秒） | 冷一 | 冷二 | 热一 | 热二 |
| --- | ---: | ---: | ---: | ---: |
| 同一源码 AppKit/SwiftUI/WebKit/ScreenCaptureKit import/typecheck | 5.689 | 4.971 | 0.275 | 0.283 |

[原始命令、源码、工具链及结果](compiler-module-cache-probe.json)保留了该探针。
它不是整轮 CI 收益。真实完整七项捕获 launcher 的两次本地观察为：

| SDK cache 状态 | 编译（秒） | 七项测试（秒） | 展开观察次数 | 最大展开采样间隔（ms） |
| --- | ---: | ---: | ---: | ---: |
| 首次 | 26.626 | 63.565 | 57 | 13.915 |
| 复用 | 18.334 | 64.010 | 58 | 12.137 |

两次均通过原 retained-return、标题帧以及全部另外五项测试。
测试时间没有被裁短。两次 staging 之间仅 launcher 注释改动，故实际 launcher
编译时间也不是逐字节相同输入的严格 A/B，更不是 hosted 速度保证。
[原始本地汇总](native-local-followup.json)保留限制；完整图片和日志在独立工作区
和临时证据目录中。没有修改原工作区或它的编译缓存。

## 当前验证与托管比较

已在独立工作区同步 main `4184b3b`；它新增的产品与测试必须纳入最终验证。
同产品源码 main 的实际运行 `41389128300` 是本轮优先对照，旧 `1593e63`
仅保留历史意义。比较须记录实际 merge SHA、image、恢复 cache key、
每个 step/job 墙钟、runner 总和、端到端、排队和 attempts。

本地当前源码 `swift build --build-tests`、warnings-as-errors runner 类型检查、
两次完整捕获回放、actionlint、CI controls、Python 语法和 diff 检查已通过。
本地复制的缓存含旧绝对路径，第一次重建因 PCM/Metal PCH 路径不匹配失败；
只删除了独立副本中的对应生成缓存后成功重建，没有把失败当作通过。
没有重复本地整套 `make check`。托管最终合成提交仍需完成完整普通 CI。
