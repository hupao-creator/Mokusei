# 自动取景下点击空白后画布放大

调查日期：2026-11-14。源码基线：`e84816f087703cd199e285729e3c905582b68150`。
初次调查只记录旧行为。用户随后确认自动 focus 的预期并要求修复；
后续修复见文末，未新增仓库测试或推送。

## 结论

点击前仍处于自动 focus；不能将此次现象解释为退出手动模式。
基线自动模式另有一个保留阅读位置的目标 `readingFit`：没有新增卡片、
存量卡片没有网格位移的局部尺寸变化，可以保留旧缩放。
空白点击调用 `returnToAuto()`，会清掉这个目标，再按完整集合重新取景。
因此，同为 `manual == false` 的两个状态，可以分别停在 0.85 和 1.0。

录屏、同一时段的本地布局日志及直接编译当前生产相机源码的诊断，
共同支持这条因果路径。此次点击后的可见变化是整体镜头变换，
没有看到必须由点击才出现的新卡片或新的任务正文。
这不能证明所有数据更新都不存在问题，但不足以认定此次存在
Runtime 通知丢失、SwiftUI 观察失效或 AppKit 需要手动重绘的问题。

基线 Overview 契约要求自动模式下的删除和局部 footprint 变化尽量保留阅读位置，
并将显式恢复自动取景作为恢复普通全景拟合的操作。
该策略造成了“仍然自动，却点击后再次放大”的体验。用户确认这属于自动 focus
行为缺陷后，已调整 [Overview 契约](../app/macos/Sources/Host/Overview/README.md#layout-motion-and-input)：
集合收缩允许更大合适缩放时自行重新取景，不再无限保留旧的小比例。

## 录屏事实

输入为用户指定附件 `录屏2026-11-14 18.16.51.mov`，位于附件目录
`9f186f1e-e3cd-4b40-8ea8-bcbdffd6a3c8`。SHA-256：
`b53fdd7b764062aaca01601dd592c6fe532ff0e234ac81df3ec7bb1eaf44ba84`。
AVFoundation 读得时长 5.2167 秒、画面 2906×2036，轨道标称帧率约 41.53。
按 0.25 秒取帧，实际查看全片联系表及 0、2.5、3、5 秒大图。
沙箱内解码返回 `AVFoundationError -11821 / OSStatus -12911`；
在允许访问系统解码服务的环境中重跑同一提帧脚本成功，并非文件损坏的证据。

| 录屏时间 | 可见状态 |
| --- | --- |
| 0–1.5 秒 | Overview 选中 Mokusei；五个卡片外框，左侧集合显示 7/11；右侧为两个已完成的 Agent 卡片，底部一个带 Git 扩展的宽卡片 |
| 约 1.75–2 秒 | 左侧集合滑到 8/11，从“关联线程标题与表情显示修复”切换为“Moku 输入框展开：CA 试验已撤销”；其余卡片位置、大小未变 |
| 2.5 秒 | 已显示第 8 篇，画布仍为较小取景；鼠标在卡片右侧空白处 |
| 约 2.75–3 秒 | 五个卡片一起放大、重新居中；筛选栏和 Moku 的固定座位不随画布一起缩放 |
| 3–5 秒 | 新取景稳定；卡片身份、任务正文和 Git 数值保持一致 |

录屏不包含原始鼠标 down/up 事件。点击位置和时机来自用户说明及画面对应关系，
不是从视频恢复出的输入事件记录。左侧集合的切页发生在整体放大之前；
[NativeReportCollection](../app/macos/Sources/Plugins/Applications/Report/NativeReportCollection.swift)
本身有八秒驻留后切页的任务，选中项由组件的 `@State` 驱动。
这一画面与自动轮播吻合，但短片不包含完整八秒驻留，不能单凭它认证计时起点。

## 同一会话的布局证据

实际诊断目录为 `layout-91724-F0643164-E293-4D88-9455-C84CB97C5D63`；
筛选标准为日志 session PID 91724、2026-11-14 18:12:53 和 18:16:54
（Asia/Shanghai）。原始来源位于应用的 `Mokusei Native Dev/diagnostics/layout`，
涉及 `events-7.jsonl`、`events-8.jsonl`；日志可轮转。

18:12:53.187683 的 `overview.relayout` transaction
`r-84DFACC4-101E-4AFC-90E8-65545836F098` 记录 viewport 为 1341×906。
planned 阶段（18:12:53.191570）保持五个身份及全部网格坐标：

| 日志卡片 index | column,row | 变化前 columns×rows | planned columns×rows |
| --- | --- | --- | --- |
| 0 | 1,0 | 1×2 | 1×2 |
| 1 | 3,1 | 2×1 | 1×1 |
| 2 | 2,0 | 1×2 | 1×2 |
| 3 | 1,2 | 2×1 | 2×1 |
| 4 | 3,0 | 2×1 | 1×1 |

transaction 采用 `ordered`，18:12:53.460499 完成；后续两个相同几何事务采用
`reuse`，也已完成。不是一个直到点击仍没有结束的布局事务。
日志没有保存使这两个 footprint 变窄的完整业务输入，不能断言是哪个 Git
提交或状态事件引发；源码允许 Git 扩展消失后卡片变窄，但这是上游候选原因。

左侧集合对应的稳定组件 `s-43DDF5A4-5A3F-4626-A616-C5927F7893CD`：

| 本地日志时间 | frame，单位 points | bounds |
| --- | --- | --- |
| 18:12:53.989047 | [64.1, 151, 306, 387.6] | [0, 0, 360, 456] |
| 18:16:54.447451 的 before | [64.1, 151, 306, 387.6] | [0, 0, 360, 456] |
| 18:16:54.775060 的 after | [114.499831, 99.000175, 359.999819, 455.999771] | [0, 0, 360, 456] |
| 同次变换最终值 | [114.5, 99, 360, 456] | [0, 0, 360, 456] |

另外四个相同组件身份也各有连续的几何变化；逻辑 bounds 不变。
306/360 = 0.85，360/360 = 1；对应录屏约 612→720 像素的卡片宽度。
五个卡片一起经过约 0.36 秒的连续变换，与生产镜头动画时长相符。
几何日志记录的是 SwiftUI 布局观察，不等于 WindowServer 每一光学帧。
日志没有历史 `manual` / `readingFit` 快照；前者由用户确认，后者的形成由
上述 footprint 事务、源码分支和下述定向复现共同支持，不能称为直接读取到了私有状态。
日志未提供可认证的源码提交身份，不能据此保证录屏运行的二进制就是本次源码基线。

## 数据、通知和显示路径

普通卡片的任务数据沿以下生产路径更新，空白点击没有接入重拉入口：

1. [RuntimeClient.acceptMutation](../app/macos/Sources/Core/RuntimeClient.swift)
   验证 revision、应用 mutation，再发出 `.mutation`。
2. [NativeWorkspaceModel.installPrepared](../app/macos/Sources/Host/Shell/NativeWorkspaceModel.swift)
   先安装准备好的 catalog，再调用 `onCatalogChange`；
   [NativeWorkspacePresentation.start](../app/macos/Sources/Host/Shell/NativeWorkspaceView.swift)
   将事件交给 Overview 的 `receive`。
3. [NativeOverviewWorkspaceModel](../app/macos/Sources/Host/Overview/NativeOverviewWorkspaceModel.swift)
   重新投影 changed card，比较结构身份，内容更新写入
   [NativeOverviewContentStore](../app/macos/Sources/Host/Overview/NativeOverviewContentStore.swift)
   的独立可观察 slot；结构变化还记录 FIFO 布局 revision。
4. Git 是另一条数据入口：
   [NativeGitWorkspaceModel](../app/macos/Sources/Host/Git/NativeGitWorkspaceModel.swift)
   每五秒查询元数据，完整安装后通知 `refreshCardExtensions()`。
   [Codex Overview](../app/macos/Sources/Plugins/Harnesses/Codex/CodexOverview.swift)
   将任务和 Git 输入交给共享 card composer，生成公开 footprint。
5. [NativeOverviewCanvas](../app/macos/Sources/Host/Overview/NativeOverviewCanvas.swift)
   消费几何事务。没有 entrants、没有 survivor 网格位移、viewport 不变时，
   `requestRefit(... preserveReadingPosition: true)` 进入相机的阅读位置保留分支。

[NativeOverviewCamera](../app/macos/Sources/Host/Overview/NativeOverviewCamera.swift)
把该分支的目标存在 `readingFit`，`fit()` 优先返回它。
旧缩放仍可容纳完整集合时，不必回到普通全景的最大自然缩放；
`updateAuto()` 允许 `manual == false` 的镜头稳定停在这个阅读目标，
同几何的后续 refit 也不会清掉它。

Canvas 的空白 `.onTapGesture` 通过 `allowsBackgroundAutoFocus()` 后调用
`camera.returnToAuto()`。这个方法无条件清掉 `readingFit` 和保留 framing，
置 `manual = false`、`pendingAutoFit = true`，再拟合当前 bounds。
它不会调用 catalog refresh、Runtime query 或 `needsDisplay`。
`@Observable` 相机发布 transform；Canvas 的 `OverviewCameraPlane` 观察它，
在既有 SwiftUI/AppKit 视图上动画变换，卡片内容和身份继续保留。
本次连续几何变化与这条显示路径一致。

## 基线定向复现与边界

临时诊断程序直接编译本 worktree 的 `NativeOverviewLayout.swift`、
`NativeOverviewStageCoordinator.swift`、`NativeOverviewCamera.swift`，没有复制相机实现。
输入来自日志的 viewport 和前后 footprint 边界：
viewport 1341×906，toolbar 64.2、Dock 保留 80；旧 content
`left=376, top=0, width=1488, height=692`，收缩后 width=1112。
这些 viewport 附加参数取自当前源码，历史构建的子点级舍入不保证一致。

诊断使用 Reduce Motion 直接结算目标，不挂载 UI，不声明验证了原生点击或动画：

```text
cutTo(old)                         scale=0.85 x=-281.5 y=151.0 manual=false
requestRefit(compact, preserve)     scale=0.85 x=-255.6 y=151.0 manual=false pending=false
requestRefit(compact)               scale=0.85 x=-255.6 y=151.0 manual=false pending=false
returnToAuto()                     scale=1.00 x=-261.5 y=99.1  manual=false pending=false
```

两次 refit 后都等待 250ms，显式返回后等待 10ms。
这复现了核心状态路径及缩放，坐标与日志存在约 0.1pt 差异，不能声称逐点复现了历史二进制。
首次编译因沙箱不允许启动 Swift Observation macro 插件而失败；
在允许该编译插件的环境中重跑同一生产源码成功，程序退出 0。
提帧、关键帧、局部原始布局日志及诊断源码/输出保留在本 worktree 忽略的
`.scratch/overview-click-refresh/`，不作为新增仓库测试或长期托管验证结果。

实际 UI 的复现条件是：自动取景处于较大的集合所需的 0.85 缩放，
同 viewport 下两个卡片从两列缩成一列，所有卡片仍在原网格座位，且无新增卡片。
当前策略保留该缩放；随后点画布空白处，才回到普通拟合得到的 1.0。
这是有生产相机执行结果支持的复现路径；本轮未人为改动用户任务或 Git 状态做端到端重放。

按 sprint 范围未新增测试，未运行单元测试、UI 回放、全量构建、`make check`、
提交 hooks 或托管 CI；旧提交的绿色 CI 不认证本提交。
只核查调查文档 diff、链接、源码调用链及上述临时诊断。
验证前只读查询 main：传统 protection 接口返回 Branch not protected；
有效 ruleset 返回 pull_request 规则，无 required status check。
查询时既有 PR #290 及最近列出的 CI 均不属于此次调查提交。
`scripts/ci/scope.py` 的文档快速通道不包含 `design/*.md` 和模块 README，
故未来提交到远程时仍会选择完整验证；本轮未推送，也未触发这套验证。

## 自动 focus 修复

用户随后确认：自动模式下集合收缩应自行计算合适取景，不依赖空白点击。
修复仅调整 `NativeOverviewCameraGeometry.preservingReadingPosition`：
先计算普通全景目标；如果它允许比旧阅读比例更大的缩放，直接采用该目标。
旧比例无法容纳完整集合时，也采用普通目标；其余同缩放的变化仍保留阅读位置，
必要时只做最小平移。缩放比较沿用相机的 1e-6 精度，避免浮点差异引发重取景。

不引入新计时器、轮询或强制刷新；`readingFit` 保存的是修正后的目标。
Canvas 仍等卡片的退出/收缩/移动/进入阶段结束后才请求 refit；
相机复用现有最小 160ms 延迟、600ms 节流、360ms 镜头动画和共享 FIFO 空间 stage。
相同几何更新不重启已接纳的镜头工作；排队时读取最新 bounds，
播放中有新几何则在结束后收敛到最新目标。
自动收缩不会抢占交互暂停或隐藏页面；暂停解除后继续。
手动模式绕过阅读目标计算，新的 pan/zoom 取消待执行及播放中的自动镜头工作。
没有更改 filter 的显式保留取景策略、Runtime 数据流或卡片组件生命周期。

### 修复后的定向验证

临时诊断 `.scratch/overview-click-refresh/fix/verify.swift` 直接编译上述三个生产文件；
未添加仓库测试、测试 target、实现副本或 UI fixture。编译与程序均退出 0。
程序检查以下生产状态与调度结果，输出保留在 `fix/verify.log`：

- 原录屏几何的自动收缩：普通动画和 Reduce Motion 两种模式都自行从 0.85 到 1.0，
  不调用 `returnToAuto()`；25 次同几何刷新不阻止完成。普通模式只提交一次 360ms 镜头动画。
- 收敛后再调用空白点击对应方法：目标和缩放不再变化，也没有追加镜头动画。
- 交互暂停和隐藏分别阻止收缩镜头；恢复后自行收敛到当前普通目标。
- 原本已手动取景，以及自动动画中被手动接管：后续收缩与等待均不覆盖手动 transform。
- 相机等待布局 stage 时不会抢先播放；排队中替换 bounds 后采用最新目标。
- 自动镜头已经播放时再次变更 footprint：最终收敛到最新目标，而非旧动画终点。
- 普通取景比例仍为 1.0 的进一步收缩：保留阅读位置，不产生额外镜头动画。
- 交互开始打断已播放的自动 refit；暂停期间位置稳定，解除后完成剩余取景。

这些是直接运行生产相机及 stage 的定向诊断，不是挂载 Canvas 的端到端证据。
尚需 GUI 核验：实际 Git 扩展消失及归档触发的 footprint 事务、卡片收缩与镜头的
视觉衔接、不同窗口/缩放下文字清晰度、真实输入暂停与焦点归属，以及辅助功能系统设置。
录屏只证明修复前现象，不能作为修复后 GUI 验收。

产品构建 `make build` 退出 0，总耗时 251.84 秒：构建 Go runtime，
Release `Mokusei` 编译/链接 237.62 秒、`MokuseiEmbedding` 4.87 秒；
构建输入稳定性检查通过。日志为 `fix/build.log`，未安装、签名打包或启动应用。
构建后核对三份生产诊断输入的 SHA-256，未在诊断/构建之间改动产品源码。
本次仅相机源码、Overview README 和此调查文档改变；diff 和两份文档的
43 个本地链接目标检查通过。未新增仓库测试，未运行单元测试、GUI 回放、
全量回归、提交 hooks 或 CI，也未推送。
