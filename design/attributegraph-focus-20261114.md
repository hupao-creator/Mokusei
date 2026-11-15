# 阅读父视图的 AttributeGraph 焦点循环

已复现并修复一条具体路径：阅读页收尾隐藏保留的 Overview 时，如果父
`NSHostingView` 内仍有键盘焦点，同步 `isHidden = true` 会让 AppKit 寻找
下一个 key view，重新读取正在执行 `updateNSView` 的 SwiftUI 布局图。
修复让这次原生隐藏在当前更新结束后提交，不屏蔽警告或关闭焦点系统。

## 既有真实证据

本轮检查的三个保留 Dev layout 会话共 696 条循环：

| PID | 保留的循环数 | 被 `reading.parent.hide` 字节区间包围 | 未归属 |
| --- | ---: | ---: | ---: |
| 77076 | 374 | 294（21 次，每次 14 条） | 80 |
| 68945 | 42 | 42（3 次，每次 14 条） | 0 |
| 36909 | 280 | 280（20 次，每次 14 条） | 0 |

字节包围只表示候选调用边界。另找到 11 月 7 日保存的真实采样栈，路径为：

```text
GraphHost.flushTransactions → PlatformViewChild.updateValue
→ NativeReadingParentSurface.updateNSView → NativeReadingParentView.update
→ NSView._setHidden → nextValidKeyView
→ NSWindow._findFirstKeyViewInDirection
→ NSHostingView._recursiveGatherAllKeyViewCandidates
→ FocusBridge / FocusNavigator → NSHostingView.responderNode
→ DynamicLayoutViewChildGeometry.updateValue → AG::Graph::print_cycle
```

原始采样是 `/private/tmp/mokusei-app-sample-load.txt`，完整祖先栈保存在
`/private/tmp/mokusei-attributegraph-diagnosis-20261111-7qd1v20v/historical-cycle-stack.txt`。
这是历史实例的框架栈，不是本轮日志记录器的 caller stack。原 PID 77076 已退出，
本轮没有成功附加该进程，也没有改动真实业务数据。

另一个旧工作区的候选提交 `661251c7` 只延后 `rootView` 发布，仍同步隐藏父 host；
本次未采用该补丁，也没有把其旧 28/0 对照作为当前验收。

## 当前实现的受控对照

最小窗口直接编译生产 `NativeReadingParentSurface.swift`，只将诊断包装器
替换为直接执行闭包。控件树使用合成文本，不接 Runtime 或用户 profile。
每轮先让父 host 内的原生 TextField 成为 first responder，再冻结、恢复。

| 同一焦点场景 | 打开次数 | 循环警告 |
| --- | ---: | ---: |
| 原实现 | 5 | 35（每次 7 条） |
| 仅延后原生 hide 的候选 | 5 | 0 |
| 包含取消、卸载与布局门禁的最终生产文件 | 5 | 0 |

每次都有 `FOCUS true`。同一控件树不先取得焦点时没有复现；先前完整 Workspace
回放在关闭或开启 Dev layout logging 时也均为 0，不能用这些无触发条件的通过
结果代替焦点反例。

本轮探针、编译记录和原始 stderr 位于
`/private/tmp/mokusei-attributegraph-20261114/`。`baseline-focus.log` SHA-256 是
`32676e382cf76b9bfaf2b68bbbc64c4ddd29b87a16b18151d20fc089f4ab6a0a`；
`final-focus.log` 是
`5dd24268c9ff982b8783e705747e4cf42fcbaa10301e921e45b3a984edc98fe7`。
生产文件对照前后 SHA-256 分别为
`fc63eac25cbec0c14869f096cda3286f77dc023dea250ab83db8df93f3357bf6` 和
`1af773c855c881909ed81b3fe2aa6850b2f0e29c7ae9aae70a1a8987fd5898a8`。

## 生命周期与验证边界

[父视图实现](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingParentSurface.swift)
立即关闭 hit testing、无障碍子节点和 viewport 更新；已经透明的父 host 只把
原生 hide 合并到下一次主队列执行。恢复与卸载会使旧 hide 失效，恢复时仍使用
原来的 host 和最新环境、内容、尺寸。没有延迟正文更新或返回准备。

[现有 Moku landing 回放](../app/macos/Tests/Integration/Host/NativeMokuLandingTests.swift)
的 `realWorkspaceWaitsForHydrationAndCentersItsEmptyComposer` 加入该真实生产
组件的焦点场景：三次冻结/恢复、检查本场景新增 stderr 无循环、输入控件身份与
内容保留、即时 pointer/AX 门禁，以及返回/卸载取消旧 hide。它沿用已有原生
launcher 与 CI 所有权，没有新增独立门禁或复制生产隐藏逻辑。

修改前完整原生回放 10/10 通过（26.334s），打开 Dev logger 的对照也 10/10
通过（25.539s）；这些是基线诊断结果，不能认证最终修改。整合后的最终 Moku
landing 原生回放 **10/10 通过，24.892s**，输出
`READING_PARENT_FOCUS_FREEZE_CONFIRMED`，原有标题交接、Close、返回、尺寸变化和
Moku 状态断言也通过。日志是 `/private/tmp/mkr-active-open-moku-landing-final.log`。
前一次整合回放的焦点场景已通过，但主任务的提前缩窄主栏方案产生标题交接
38pt 偏差，并出现一次 Close 未进入 motion 的失败；撤回该方案后完整通过，
没有放宽或删除断言。未据此把那次 Close 失败归因给 AttributeGraph 修复。

独立旧 Debug launcher 的反例未能执行：同步 main/重建期间取出的构建输入在
链接时缺少 `ThreadCardProviderStatus.init(...usesRegularGlass:)`，不能认证旧实现。
日志保存在
`/private/tmp/mokusei-attributegraph-20261114/moku-landing-regression-baseline-run.log`。
本报告的 35→0 反例来自前述独立编译的确切生产文件，不来自该链接失败。
直接 `swift test` 首次使用了不带 AppKit event loop 的入口，在 `NSApp` 未初始化
处退出；随后改用项目既有原生 launcher。最终构建及其他受影响套件由主任务记录。

尚未归属的 80 条警告集中在 11:05:08.435–08.622 的一次观察窗口，附近有 Moku
输入框展开与返回几何变化，但缺少该批次的框架栈，不能宣称已全部修复。
两个 Release 打开 benchmark 的修复前日志均为 0 条，因此本修复不能解释它们
的打开延迟，也没有从 35→0 推导帧率、CPU 或用户可见停顿的改善比例。

## 收尾验证与保留问题

按用户要求结束性能探索，已撤回全部阅读页预加载、提前缩栏和正文入场实验，
最终生产差异只保留上述父 host 焦点隐藏修复。新增 `reading.active-open`
benchmark 与被拒绝的性能实验记录保留，未增加比例预计算缓存。

恢复原阅读策略后，最终 MokuLanding 10/10 通过（26.181s），包含
`READING_PARENT_FOCUS_FREEZE_CONFIRMED`。验证前有一次既有 Sidecard 第二次
点击未恢复主栏宽度，3s 等待超时；之后增加输入诊断重跑通过，最后移除会
额外调用 hitTest 的诊断与临时点击日志（`MOKU_REPLAY_CLICK`），再次 10/10 通过。
未放宽断言、增加等待或跳过场景。失败那次没有输入状态证据，不能据后两次
通过就认定原失败为误报，也没有证明它由本次隐藏修复造成。

关键探针、benchmark 指标和录屏联系表另归档于本地主 checkout 的
`.scratch/reader-active-opening-20261114/`；原完整 benchmark 抓帧仍在前述
`/private/tmp` 目录。归档不包含 Runtime 认证文件或真实用户对话。

同一最终生产源码的阅读页回放另有 12/12 通过（17.654s）。Benchmark 协议验证
为 31 个 reading 控制与真实 HTTP source 生命周期、115 个共享对抗/契约回放
通过。未运行完整本地 make check 或托管 CI；本次仅合并本地 main，不推送。
