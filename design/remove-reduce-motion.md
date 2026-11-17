# 移除系统减少动态效果感知

基线：本地 main 与 detached HEAD 均为 `8966c3c847f73910ba3a9394fefcc0df3dbd383b`，开始时工作区干净。
本次仅提交独立变更，等待独立 review 后由调用方协调集成；不修改 main、不推送、不启用新应用包。

## 当前契约与边界

应用自有动效不读取或观察 macOS Reduce Motion，也不传递该偏好或提供其测试覆盖入口。
所有原有正常动效使用原来的时间、曲线与完成边界。保留窗口隐藏/失焦、离屏、拖动、resize、显式暂停和性能门控。
减少透明度、增加对比度、AX 语义、键盘导航和焦点归属继续由原有组件负责。

- 阅读 stack 保留 Close 准备、native completion、取消、route generation 和 identity ink 就绪门槛；仅删除偏好触发的立即收束。
- 时间线 Jump Latest 仍以 `.removed` completion 恢复底部锚点，并通过 UUID、隐藏/手动滚动边界隔离迟到完成。
- 执行交接保留 fold completion 与正文 readiness 两个门槛、handoff UUID、retained reader、关闭/替换与 resize/inactive 收束。
- Report 的 `finish()` 继续用于终帧快照缓存、正常播放后停留、已完成网格 cover 的重挂载；原先兼用的 `.reduced` 改为与偏好无关的 `.finished` 初始姿态。它不读取系统偏好。WebView 暂停、拆卸、replay generation 与异步初始化隔离保留。
- Moku 保留可见性时钟、reasoning retirement、composer generation 和自动聚焦延时；删除静态 Reduce Motion 专用 pose 输入。
- 原生 AppKit/SwiftUI/WebKit 自身或第三方依赖可能应用系统默认策略；本次不覆盖、swizzle 或伪造系统偏好。任意外部 Report HTML/CSS（包括作者自己的 media query）不改写。未修改任何 vendored 依赖或锁定版本。
- Go 嵌入资源、Swift/WebKit 注入脚本及 HTML/CSS 全仓检索未发现自有 `prefers-reduced-motion` 适配。Report 生成指导中的偏好约定已移除，未改已有 Report 内容。
- 局部 transaction 禁动画的预览仍可作为视觉对照，命名明确为 transitionsDisabled/no-animation，不代表系统偏好注入。

## 检索方式

基线文件用 `git show 8966c3c8:<path>` 提取到独立临时目录，再由 `rg` 逐行索引；下表行号固定指向基线，避免删改后行号漂移。
主检索（含隐藏文件，不含 Git 元数据和生成依赖）：

```sh
rg -n -i --hidden -g '!.git' -g '!**/.build/**' \
  'reduce.?motion|reduced.?motion|减少动态|减弱动态|prefers-reduced-motion|motionReduced|reduceCaretMotion|\.reduced\b' .
```

另查 `accessibilityDisplayOptionsDidChangeNotification`、全部 `accessibilityDisplay*` / `accessibilityReduce*`、`matchMedia`、`still` 及 `.reduced` 的传递调用。
余留的 DisplayOptions observer 读取减少透明度，不属于本次删除范围。
`NativeMokuRunningGeometry` / `MokuRunningStory` 的 `still` 参数和两个普通调用者已同步删除；`NativeReportCoverPlayback` 的 enum case、CI native owner 方法名和 benchmark receipt 消费端同步更新。

代码类文件（Swift/Go/Python/workflow/JS/CSS/HTML/嵌入 txt）的目标关键词最终为零命中。
剩余命中仅在本审计、明确说明新策略的共享 UI README、标注失效的设计历史以及原始测量/回放证据。
这些历史命中不计作当前行为或本次验证通过。普通英文 `reduced trace` / Markdown parser 局部变量等与偏好无关，未修改。

## 验证与限制

本次自审覆盖所有改动、普通动画时序、完成/取消与 WebView 生命周期。没有放宽普通动画断言、增加 skip 或新增实现镜像测试。

| 验证 | 本次结果 |
| --- | --- |
| `xcrun swift build --package-path app/macos --build-tests --force-resolved-versions --disable-index-store -Xswiftc -warnings-as-errors -j 2` | 成功，最终稳定源码构建 126.10 秒；包含应用与完整测试目标 |
| 当前二进制 `swift test list --skip-build` 与 native ownership registry | 21 个 native owner 方法全部存在；重命名 cover 用例同步注册。此项是清单校验，不代表图形回放已执行 |
| 精确选择 31 个 Swift Testing 方法，`MOKUSEI_TEST_HEADLESS=1 swift test --skip-build --filter ...` | 28 通过、3 失败、零跳过，完整 summary，进程退出 1，执行 15.046 秒 |
| 从原始 SHA 提取到 `/tmp/remove-motion-baseline-verify` 的独立源码副本，运行相同 Overview 几何 suite | 同样 3 失败、相同 9 issues、零跳过；构建 189.56 秒，执行 8.107 秒，进程退出 1。未操作其他 Git worktree |
| `GOCACHE=/tmp/remove-motion-gocache ./scripts/go.sh test ./internal/plugins/applications/report` | 通过，包测试 0.730 秒 |
| `python3 tools/benchmarks/benchmark.py conformance` | 115 项实际契约/对抗回放通过，退出 0；没有认证 GUI/host capability |
| `python3 tools/verification/moku-appearance/run.py --skip-build` | 通过，退出 0；无窗口生产 Dock/history/主题、光标移动/呼吸及清理 |
| 改动演示/工具的 `swiftc -typecheck -warnings-as-errors` | 12 组中 10 组通过；两组基线接口错误如下。仅类型检查，没有运行/激活演示包 |
| 提交钩子 `make lint` | 架构、静态注册、no-Node 源码检查和 `go vet ./...` 通过 |
| Python AST、两份 workflow YAML、`git diff --check`、改动文档本地链接 | 通过；415 个本地链接存在 |

31 个定向方法来自 `CoverInitialPoseTests`、`NativeSettingsAnimationVisitTests`、`NativeOverviewCameraTests`、`NativeReadingPageHeadlessTests`、`NativeOverviewHeadlessGeometryTests`，以及 `NativeThreadSendFeedbackTests` 的六个无窗口方法（receipt 两种顺序、eligibility、前后继隔离、单 execution、入口精确性、handoff readiness）。发现清单与过滤表达式保留在 `/tmp/remove-motion-tests-selected.json`；实际 Swift Testing summary 为 31，未用 XCTest 的零用例 summary 冒充通过。

三项失败是 `mixedFootprintsResizeWithoutAWindow`、`narrowViewportHonorsToolbarAndDockReservation`、`sceneAndFilterResetConvergesOnTheLatestCollection`。前后版本均在相同初始状态失败：两项无法满足现有收敛判据；窄窗例观察到相同 `(-172, -220)` 起点、844pt 宽卡及可用视口边界冲突。没有通过更改动画、容差、预算或删除断言使其变绿；这组仍记为失败，基线复现不等同于认证所有新路径。

两项演示编译错误也用提取的原始演示源码复现：`demos/report-thread/Production.swift:36` 的 `subscribe` closure 少一个参数；`demos/settings-tabs/SettingsTabsView.swift` 向既有 `LandingSurface` 传递已不存在的 `glassWorld`。没有修复与本次动效契约无关的接口漂移。

最初沙箱内 SwiftPM manifest/Observation 宏插件报 `sandbox_apply: Operation not permitted`，便携回放的 loopback bind 报 `EPERM`；获准在沙箱外执行相同边界后，获得上述真实结果。实现迭代中的表达式/环境入口错误已修复；一次构建期间源文件变化的结果已弃用，最终以上述稳定源码构建为准。
日志保留在 `/tmp/remove-motion-build-final.log`、`/tmp/remove-motion-focused-tests.log`、`/tmp/remove-motion-baseline-geometry.log`、`/tmp/remove-motion-go-report.log`、`/tmp/remove-motion-benchmark.log`、`/tmp/remove-motion-moku-appearance.log`、`/tmp/remove-motion-demos-typecheck.log`、`/tmp/remove-motion-demos-baseline-typecheck.log`；受阻/失败构建记录也以 `remove-motion-*-sandbox.log` / `remove-motion-build-attempt*.log` 保留。

为保持现场应用状态，没有运行激活窗口的图形回放、签名生产包验收或性能实验，没有重启/终止现场应用或启用新包。没有运行全套 `make check`。Report 已知的 2 秒测试与 5 秒实现差异未修改，也没有声明图形 Report 播放回放通过。

验证前已读取实际远端门禁：传统 branch protection 返回 404；main ruleset 返回 PR/review 规则，未列 required status checks。查询到 3 个 open PR 及最近 CI runs；本地基线 SHA 的 check-runs 查询返回 422（远端不存在该提交）。本次未推送，因此没有当前新提交的 hosted `Complete coverage`；未把历史成功运行当成本次通过，未执行合并。

## 基线精确命中与处理

主检索共 639 个匹配行、166 个文件（同一行多个匹配计为一行）。

### 应用与测试

| 文件 | 基线行号 | 处理结果 |
| --- | --- | --- |
| `app/macos/Sources/App/Mokusei.swift` | 112 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/ApplicationHost/NativeApplicationHTMLSurface.swift` | 30, 51, 75, 107 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/MokuScene/NativeMokuCapsuleBlink.swift` | 8, 9 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/MokuScene/NativeMokuCharacterMotion.swift` | 17, 74, 131, 141, 144, 254 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/MokuScene/NativeMokuComposer.swift` | 114, 164 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/MokuScene/NativeMokuDock.swift` | 81, 197, 255, 398, 413, 540, 558, 578, 581, 758, 776, 849, 907 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/MokuScene/NativeMokuDockIdentity.swift` | 16, 33, 58, 117, 127 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/MokuScene/NativeMokuHorizontalTravel.swift` | 104 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/MokuScene/NativeMokuTimerBar.swift` | 50 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Onboarding/NativeOnboardingReportAnimation.swift` | 9, 23, 47 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Onboarding/NativeOnboardingSurface.swift` | 10, 22, 118, 250, 251, 255, 256, 257, 262, 263, 264 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Onboarding/NativeOnboardingTagAnimation.swift` | 18, 32, 50 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Overview/NativeOverviewCamera.swift` | 232, 449 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Overview/NativeOverviewCanvas.swift` | 185, 186, 188, 324, 325, 490, 609 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Overview/NativeOverviewChrome.swift` | 65, 137, 142, 223, 250, 264, 309, 316, 356, 358, 384, 385, 391, 501, 524, 745, 762, 827, 840, 885, 910, 940 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Overview/NativeOverviewWorkspaceView.swift` | 45, 128, 130 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Settings/NativeRoleConfigurationPanel.swift` | 43, 46, 47 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Settings/NativeSettingsPage.swift` | 63, 279 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Settings/NativeSettingsTransition.swift` | 12, 25, 29 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Sidecards/NativeAgentThreadWorkspace.swift` | 92, 102, 152, 157, 168, 171, 196, 283, 285 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Sidecards/NativeExecutionHandoffReader.swift` | 13, 29 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/Sidecards/NativeSidecardWorkspaceModel.swift` | 17, 139, 140, 237, 244, 246 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Host/WindowNavigation/NativeApplicationReadingPanel.swift` | 86, 163, 164 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Plugins/Applications/Report/NativeReportApplication.swift` | 110, 156, 177, 178, 179, 197, 287 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Plugins/Applications/Report/NativeReportCollection.swift` | 31, 72, 92, 93, 234, 370 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Plugins/Applications/Report/NativeReportCover.swift` | 60, 65, 256, 266, 269, 272, 286, 317, 333, 334 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Plugins/Applications/Report/NativeReportExecutionRow.swift` | 17, 96 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Cards/HarnessThreadCard.swift` | 18, 79, 212, 213, 219, 226, 282, 287 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Cards/ThreadCardExcerpt.swift` | 15, 16, 26, 37 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Cards/ThreadCardInitialResponse.swift` | 41, 47, 86, 105 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Cards/ThreadCardSections.swift` | 262, 266, 675, 678 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Cards/ThreadCardText.swift` | 12 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Composer/NativeComposerCaret.swift` | 18, 20, 53, 92 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Composer/NativeComposerEditor.swift` | 24, 123, 239 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Composer/NativeComposerTextInput.swift` | 81, 127 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Conversation/NativeCollectionPanel.swift` | 93, 105 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPageStack.swift` | 49, 130, 141, 142, 164, 212, 221, 334 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelCloseButton.swift` | 14, 51, 52, 53 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Conversation/NativeRelatedExecutionEntrance.swift` | 13, 26, 52, 55, 61, 85, 93, 101 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Conversation/NativeReportExecutionScroll.swift` | 13, 26 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Conversation/NativeThreadIdentityBridge.swift` | 299, 306, 326, 332 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Conversation/NativeThreadLoadingSkeleton.swift` | 20, 34, 40 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Conversation/ThreadExecutionGroups.swift` | 204, 209 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Conversation/ThreadHistorySidebar.swift` | 22, 168, 169 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Conversation/ThreadSteerMessage.swift` | 10, 55 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Conversation/ThreadTimeline.swift` | 198, 418, 472 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Design/NativeStatusSpinner.swift` | 10, 18 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Forms/NativeModelSelector.swift` | 216 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Sources/Shared/PluginUI/Reading/NativeStreamingPage.swift` | 514, 528, 540 | 移除偏好读取、传播或分支，保留普通动效/生命周期 |
| `app/macos/Tests/Integration/Host/NativeMokuExecutionLinkTests.swift` | 791, 792 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeOverviewCameraTests.swift` | 252, 255 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeOverviewCapacityTests.swift` | 36, 38 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeOverviewDecorationCaptureTests.swift` | 118 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeOverviewHeadlessGeometryTests.swift` | 99, 116, 131 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeOverviewMountingIntegrationTests.swift` | 492 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeOverviewReplaySupport.swift` | 22, 86 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeOverviewStatePropertyTests.swift` | 130 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeOverviewTagGlassTests.swift` | 432, 547, 600, 664, 682 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeOverviewTransitionTests.swift` | 48, 50 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeReadingPageHeadlessTests.swift` | 200, 244, 249, 263, 286 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeReportCoverTests.swift` | 74, 108, 174, 214 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeSettingsAnimationVisitTests.swift` | 12, 13, 14, 16, 18, 21, 22, 23, 26, 27, 30, 34, 35, 36, 38 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/NativeThreadSendFeedbackTests.swift` | 35, 37, 57, 83, 267, 476, 486, 530, 542, 544, 569, 597, 719 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/SwiftUIOverviewInteractionTests.swift` | 79, 108, 338, 339, 340, 342, 344, 347, 373, 385, 386, 497, 533, 561 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |
| `app/macos/Tests/Integration/Host/SwiftUIReplaySupport.swift` | 53 | 移除偏好专用用例/注入；保留普通动画、取消和竞态断言 |

### 演示、验证工具与 CI

| 文件 | 基线行号 | 处理结果 |
| --- | --- | --- |
| `.github/workflows/ci.yml` | 250 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `.github/workflows/overview-performance.yml` | 62 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/execution-handoff/Fixture.swift` | 39 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/execution-handoff/HandoffStage.swift` | 12, 91, 92, 93, 153, 271, 278 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/execution-handoff/main.swift` | 14, 15, 18, 62, 63, 66, 78, 129, 130, 142 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/landing-setup/SetupConfigurationPanel.swift` | 11, 17 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/landing-setup/SetupView.swift` | 7, 19, 107, 108, 111, 112, 113, 114, 149, 215 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/moku-gradient-material/MokuGradientDemo.swift` | 12, 176 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/moku-landing/main.swift` | 290, 292, 297, 299 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/moku-mention-transition/main.swift` | 25, 50 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/moku-panel-transition/main.swift` | 14, 45, 57, 131, 132, 174, 180 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/moku-thinking-orbit/main.swift` | 67, 68 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/report-thread/main.swift` | 23, 26, 33, 57 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/settings-tabs/SettingsTabsView.swift` | 41, 54, 60 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/settings-tabs/main.swift` | 30, 205, 206 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/thread-panel-transition/Sidecards.swift` | 21, 57, 60, 64, 145 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `demos/thread-panel-transition/main.swift` | 47, 52, 56, 69, 82, 97, 99, 131, 183, 597, 603 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `internal/plugins/applications/report/instructions.txt` | 53 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `scripts/ci/native-environment.swift` | 4, 7 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `scripts/ci/swift_ownership.py` | 14 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `tools/benchmarks/badge_comparison.py` | 23, 83 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `tools/benchmarks/conformance/replay.py` | 232, 235 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `tools/verification/moku-appearance/main.swift` | 49, 78, 84 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `tools/verification/moku-note/main.swift` | 680 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `tools/verification/moku-orbit/main.swift` | 14, 27, 33, 35, 41, 192, 196, 201, 208, 225 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `tools/verification/overview-ci-performance/Metrics.swift` | 402 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `tools/verification/overview-ci-performance/main.swift` | 530, 819 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `tools/verification/overview-ci-performance/run.py` | 264 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `tools/verification/overview-glass/environment.swift` | 17 | 移除偏好读取、配置或专用验证；同步正常路径 |
| `tools/verification/overview-glass/trial.swift` | 46 | 移除偏好读取、配置或专用验证；同步正常路径 |

### 文档与历史证据

| 文件 | 基线行号 | 处理结果 |
| --- | --- | --- |
| `app/macos/README.md` | 110, 151, 248 | 同步现行契约；历史证据明确保留 |
| `app/macos/Sources/Host/MokuScene/README.md` | 88, 119, 156, 189, 214, 237, 344, 354, 375, 446, 528, 538, 569, 577, 601, 728 | 同步现行契约；历史证据明确保留 |
| `app/macos/Sources/Host/Onboarding/README.md` | 81 | 同步现行契约；历史证据明确保留 |
| `app/macos/Sources/Host/Overview/README.md` | 207, 229, 287, 289, 330, 401, 406, 579, 600 | 同步现行契约；历史证据明确保留 |
| `app/macos/Sources/Host/Settings/README.md` | 51, 138, 141, 357 | 同步现行契约；历史证据明确保留 |
| `app/macos/Sources/Host/WindowNavigation/README.md` | 63, 173, 289, 311 | 同步现行契约；历史证据明确保留 |
| `app/macos/Sources/Plugins/Sidecards/README.md` | 86, 111, 291, 292 | 同步现行契约；历史证据明确保留 |
| `app/macos/Sources/Shared/PluginUI/README.md` | 38, 191, 217, 322, 445, 449, 510, 591, 664, 889, 977, 1017, 1035, 1039, 1074, 1091, 1097, 1151, 1160, 1316, 1492, 1595, 1615, 1616, 1635, 1712 | 同步现行契约；历史证据明确保留 |
| `app/macos/Tests/Support/README.md` | 84, 90 | 同步现行契约；历史证据明确保留 |
| `demos/README.md` | 10 | 同步现行契约；历史证据明确保留 |
| `demos/execution-handoff/README.md` | 5, 43, 46, 62, 87, 99 | 同步现行契约；历史证据明确保留 |
| `demos/execution-handoff/evidence/samples.json` | 9, 18, 27, 36, 45, 54, 63, 72, 81, 90, 99, 108, 117, 126, 135, 144, 153, 162, 170, 171 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `demos/execution-handoff/validation.md` | 16, 43 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `demos/landing-setup/README.md` | 26, 34, 36 | 同步现行契约；历史证据明确保留 |
| `demos/moku-gradient-material/README.md` | 20 | 同步现行契约；历史证据明确保留 |
| `demos/moku-history-theme/README.md` | 70 | 同步现行契约；历史证据明确保留 |
| `demos/moku-landing/README.md` | 15, 51 | 同步现行契约；历史证据明确保留 |
| `demos/moku-note-transition/README.md` | 18, 34, 35, 39 | 同步现行契约；历史证据明确保留 |
| `demos/moku-note-transition/evidence/observations.json` | 290, 572 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `demos/moku-panel-transition/README.md` | 39, 56 | 同步现行契约；历史证据明确保留 |
| `demos/moku-panel-transition/evidence/samples.json` | 21, 44, 67, 90, 113, 136, 159, 182, 205, 228, 251, 274, 297, 320, 343, 366, 389, 412, 435, 458, 481, 504, 527, 550, 573, 596, 619, 642, 665, 688, 711, 734, 757, 780, 803, 826 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `demos/moku-panel-transition/evidence/validation.md` | 43, 52 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `demos/moku-thinking-orbit/README.md` | 54 | 同步现行契约；历史证据明确保留 |
| `demos/settings-tabs/README.md` | 11, 35 | 同步现行契约；历史证据明确保留 |
| `demos/super-thread-carousel/README.md` | 11 | 同步现行契约；历史证据明确保留 |
| `demos/super-thread-carousel/collection-expansion-validation.md` | 64, 97 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `demos/super-thread-carousel/collection-panel-validation.md` | 44 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `design/agent-detail-entry-orbit.md` | 32 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/animation-main-thread.md` | 94 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/card-status-layout-shift.md` | 71, 72 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/detail-background-optimization.md` | 34 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/direct-send-transition.md` | 31, 55, 99 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/execution-handoff-production.md` | 6, 17, 56, 92 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/execution-route-slide.md` | 51, 66 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/history-author-title-transition.md` | 109 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/moku-talk-note-handoff.md` | 17, 96 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/moku-talk-note-transition.md` | 48, 64 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/note-read-awareness-implementation.md` | 68 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/note-read-awareness.md` | 51, 188 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/overview-click-refit-investigation.md` | 140, 193, 264 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/overview-fitall-layout.md` | 71 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/reader-8k-performance.md` | 134, 395 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/reading-entrance-choreography.md` | 13, 36, 37, 97, 103, 118, 136, 147 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/reading-placeholder-alignment.md` | 56 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/related-thread-fade.md` | 49, 61, 78 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/report-sidecard-admission.md` | 19, 93, 130, 175 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/report-sidecard-close.md` | 21 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/sidecard-fold-performance.md` | 55, 67, 119, 138 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/super-thread-animated-covers.md` | 33, 37, 75 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/thread-loading-performance-cache.md` | 128 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/thread-open-animation-investigation.md` | 195 | 保留历史正文；入口明确旧动效描述已失效 |
| `design/thread-overview-isolation.md` | 97 | 保留历史正文；入口明确旧动效描述已失效 |
| `internal/plugins/applications/report/README.md` | 365, 376 | 同步现行契约；历史证据明确保留 |
| `scripts/ci/README.md` | 11 | 同步现行契约；历史证据明确保留 |
| `scripts/ci/self-hosted.md` | 173 | 同步现行契约；历史证据明确保留 |
| `tools/benchmarks/baselines/2026-11-14-emoji-badge-glass.md` | 9 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `tools/verification/moku-appearance/README.md` | 32 | 同步现行契约；历史证据明确保留 |
| `tools/verification/moku-note-performance/README.md` | 188 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `tools/verification/moku-note/README.md` | 21 | 同步现行契约；历史证据明确保留 |
| `tools/verification/moku-orbit/README.md` | 15 | 同步现行契约；历史证据明确保留 |
| `tools/verification/overview-glass/evidence/host-environment.json` | 8 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `tools/verification/overview-input/evidence/glass-completion/README.md` | 31 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `tools/verification/overview-layout/RESULTS.md` | 34, 40 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `tools/verification/overview-performance/RESULTS.md` | 147 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `tools/verification/overview-performance/evidence/glass-run-3/metadata.json` | 30 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `tools/verification/reading-presentation/README.md` | 71, 159, 380, 550, 595, 778, 901 | 同步现行契约；历史证据明确保留 |
| `tools/verification/reading-presentation/evidence/subtag-ax-isolation/baseline-diagnostic.patch` | 8, 10, 46 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `tools/verification/reading-presentation/evidence/subtag-ax-isolation/diagnostic.patch` | 8, 10, 46 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `tools/verification/reading-presentation/evidence/subtag-transition-speed.md` | 13 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `tools/verification/reading-presentation/evidence/vertical-transition.md` | 51, 69, 80, 107 | 历史测量/验证/诊断证据，原样保留；不执行 |
| `tools/verification/swift-tests/README.md` | 278 | 同步现行契约；历史证据明确保留 |
