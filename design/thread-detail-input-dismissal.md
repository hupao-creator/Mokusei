# Thread detail 输入模式的退出路由

本次只交付 detached worktree 中的独立提交，供调用方本地整合。
按本次 sprint 约束，没有新增或运行测试、CI、hooks，没有推送、建 PR 或合并。

## 已确认的断路与修复

Thread detail 复用 `NativeMokuDock`，但使用独立的 Thread draft。
`NativeMokuComposerInput` 将原生文本事件交给共享 `NativeComposerEditor`：
marked text 先交给 AppKit，目录候选先处理按键，最后才调用 Dock 的 `onEscape`。
这条编辑器仍持有焦点且可编辑的路径原本就能收起输入；本次基线组件手工操作也观察到这一点。
用户反馈没有包含当时的 Thread 可执行状态、first responder 或弹窗状态，不能宣称所有场景由一个原因导致。

代码中确认的缺口：

1. Thread 进入输入模式后，可能因归档、能力或连接状态变为不可执行。
   `navigationDisabled` 同时禁止外部点击退出；不可编辑的文本框又不进入自定义按键处理。
   关闭输入展示不应要求发送权限，因此退出独立于 execution availability。
2. `onEscape` 只挂在文本编辑器。焦点离开编辑器后，原生阅读区域的 Escape
   只能执行自己的返回/关闭；Dock 控件也没有输入模式的兜底。
   Scene 现在向原生阅读 Escape 提供可消费一次事件的输入取消回调，
   Dock 使用相同的原生 fallback，避免依赖多个监视器的注册顺序决定输入/阅读谁先退出。
3. Dock 在 mouse-down 观察外部点击而不吞事件，阅读卡片在 mouse-up 关闭。
   同一按压可能同时折叠输入和关闭卡片。Scene 现在记录本次按压已折叠输入，
   Shell 的面板外部关闭回调据此保留阅读卡片；下一次按压清除标记，仍能关闭卡片。
4. 原来的原生菜单、sheet、modal 和 child-window 点击保护只用于 landing 输入。
   现在所有打开的 Dock 输入都保留这些交互；额外记住 NSPopover 关闭所转发的同一按压，
   防止 child window 已消失后继续折叠输入。目录候选发布的点击区域也明确算作内部。

没有修改 Thread detail padding、Close 按钮、缓存、发送/中断协议或 voice client。
显式 Close 按钮仍执行显式关闭。没有新增透明点击覆盖层、焦点抢占或自动清空草稿。

## 取消顺序

- 原生编辑、IME marked text、WebKit、原生菜单/弹窗及控件自己的取消处理优先。
- 编辑器中的目录候选先关闭，随后一次 Escape 才折叠输入。
- 可由阅读区域处理的 Escape 先折叠仍打开的 resident input；输入已经关闭时，
  阅读历史、Sidecard 和 Thread 原有的取消/返回路由继续运行。
- 输入外部点击仍传给原目标控件；点空白处折叠输入的同一按压不再顺带关闭阅读卡片。
- Landing 的外部点击仍保持输入；Escape 仍可折叠。其他 app/window 的输入退出策略未扩展。
- 折叠复用现有 `setInputOpen(false)`，继续保存 draft、附件、目录和编辑选择，
  不调用语音启动、停止或媒体接口。

## 本次实际验证

2026-11-03，Apple Silicon / macOS 26，Swift 6.3.2。

- 构建 `xcrun swift build --package-path app/macos --disable-sandbox --product Mokusei`。
  没有 `--build-tests`，没有执行 Swift/Go tests 或自动回放。
- 使用 `NativeReplay.compile` 将当前生产模块链接成临时手工窗口；仅编译、打开，
  没有调用 replay runner。窗口使用 `NativeMokuScene`、`NativeMokuDock`、
  `NativeReadingPageStack`、`nativeReadingEscape` 和原生编辑器，内存 draft，
  没有 Runtime、模型调用或用户会话数据。手工控制只设置不可执行状态、移动焦点和重新打开面板。
- 已手工观察：编辑器 Escape 折叠输入且保留 draft/阅读卡片，下一次 Escape 关闭阅读卡片；
  通过快捷键将 first responder 移到 window 后，Escape 仍先折叠输入。
- 已手工观察：输入打开后变为不可执行，Escape 仍退出；点击卡片外空白处第一次只折叠输入，
  第二次才关闭卡片，draft 保留。
- 已手工观察：点击编辑区域保持输入；输入 ` @` 打开目录候选，第一次 Escape 只关闭候选，
  第二次折叠输入；重新打开后点击 Design 候选，目录加入 draft 且输入保持。
- 已手工观察：点击附件控件打开原生文件选择 sheet；Escape 只取消 sheet，
  原输入、文本、目录与阅读卡片保留。原生文本右键菜单的 Escape 和外部点击也只关闭菜单。
- 对最终 diff 做本地审查及 `git diff --check`。构建日志和临时手工源码保留于
  `/tmp/moku-input-build-delivery.log`、`/tmp/moku-input-manual.swift`。
  交付前构建通过（15.93s）；以该构建重新链接组件，复核了候选点击、失焦 Escape、
  不可执行时的外部点击、draft/目录保留和输入关闭后的 Thread Escape。

限制：这不是完整安装包或四种 Harness 的端到端验收。没有真实 IME composing 输入法操作、
独立 NSPopover 转发按压、实时语音/麦克风/播放、真实 VoiceOver 操作或物理手势验证。
这些边界的优先级来自现有生产 guard 和调用路径审查，不能写成实机通过。
没有查询或触发托管 CI，也不把本地构建当作合并门禁通过。

## 独立审查后的追加修复：Sidecard 焦点与 marked-text 按压

上一提交只给原生阅读 fallback 注入了输入取消优先级。
`NativeAgentThreadWorkspace` 外层与单张卡片、`ConversationExecutionPane` 以及
`ThreadHistoryDocument` 仍存在直接调用关闭/返回的 SwiftUI `onExitCommand` 路由。
执行卡片不主动聚焦 Moku，用户也能通过键盘进入卡片控件；输入展开与卡片焦点共存可达。
因此不能依赖 Dock 的原生 monitor 总能在 SwiftUI 子树取消前处理 Escape。

这些面板退出入口现在使用 `nativeReadingExitCommand`：继续沿 SwiftUI 聚焦子树传递，
不新增全窗口监听，不把显式 Close、地址编辑/批注取消或所有 `nativeOnExitCommand`
一概替换。只有面板级 Escape 先询问 resident input，再执行对应面板原来的返回动作。
原生 fallback 和 SwiftUI 入口共用原生编辑器/marked text、sheet/modal/child window、
WebKit 和控件弹层取消的归属判断。编辑器内的 Escape 不提升为折叠输入或关闭面板；
disabled/被遮盖卡片不取得退出所有权，历史的 SwiftUI 入口也遵守原有 reading-active 门禁。
非 Escape 的现有 exit command 路由保留。

此前外部点击只保护菜单/弹窗，没有检查 `NSTextInputClient.hasMarkedText()`。
点击前若仍有组合状态，现在保留原事件并让 AppKit/input method 处理，
不在 mouse-down 提前禁用、折叠或销毁编辑器，不强制 unmark/discard，也不延迟补一次折叠。
该按压同时标记为输入优先，阻止阅读背景在 mouse-up 连带关闭面板。
检查先于 transient-window 判断，避免输入法候选窗口在事件转发时消失造成漏判。
组合结束后的下一次操作继续普通退出策略。

追加修复的实际验证（同样没有新增或运行测试、CI、hooks）：

- 最终 `Mokusei` 产品构建通过，命令同上；日志
  `/tmp/moku-sidecard-followup-delivery-build.log`，该次构建 16.63s。
- 临时手工窗口链接该构建的生产 `NativeMokuScene`、`NativeMokuDock`、
  `NativeAgentThreadWorkspace`、`ConversationExecutionPane` 和 `NativeReadingPageStack`。
  注入固定的运行执行/历史索引及焦点控件、回应 TextField；不启动 Runtime、不发送任务。
  主 Harness 未注册，主阅读区显示 unavailable 属于该 fixture 的已知限制，
  不能声称完整 Harness reader 或端到端使用通过。
- 已观察到输入 open、执行卡片 open 且键盘焦点位于执行卡片普通按钮。
  首次 Escape 只使输入 closed；第二次只使卡片 closed，Thread 保持 open。
- 已观察到焦点进入回应 TextField 后，Escape 保留字段文字、输入及卡片。
  原生文本右键菜单先消费 Escape，未折叠输入或关闭卡片；目录候选也先消费 Escape。
- 已通过临时手工控件调用生产 NSTextView 的 `setMarkedText` API，并观察
  `ComposerTextView marked=true`。在真实阅读背景空白处点击后，marked=true、
  文字 `marked-ni`、输入、执行卡片和 Thread 均保留。点击回应字段时，事件仍正常交给
  原生焦点切换；回到原文本菜单时仍观察到 marked=true。随后普通折叠/重新打开保留草稿。
- 这里的 API 构造组合状态不是实际输入法会话。用当前已配置输入源逐键输入 `ni`
  并尝试系统切换快捷键后，未观察到真实输入法组合候选，不能认证真实 IME。
  API 合成 mark 的 Escape 只能说明输入未被面板取消路由折叠，不能认证真实输入法的
  提交/取消文字语义；该合成情况下曾观察到 Escape 控制字符替换 mark，不能当作真实 IME 通过。
- 最终手工源为 `/tmp/moku-sidecard-manual.swift`，隔离窗口为
  `/private/tmp/mokusei-native-replay-sidecard-input-delivery/MokuSidecardDelivery.app`。
  手工编译只调用 `NativeReplay.compile`，没有调用 runner 或添加断言。

仍未实机验证真实 IME 候选窗口的转发/提交/取消语义、独立 NSPopover、实时语音或 VoiceOver。
这些限制保留；没有用 API 合成组合状态替代真实输入法验收，也没有把未运行的检查记为通过。

## 复审追加：可聚焦历史目录与指定基线整合

`ThreadConversation.readingLayout` 的 HStack 曾用 `onKeyPress(.escape)`
直接调用 `closeHistory()`。历史正文的 native monitor 不涵盖兄弟目录，
Host 的主阅读 fallback 又在内部历史拥有返回动作时退出，不能依赖它们保证该焦点路径的顺序。
现在 HStack 使用现有 `nativeReadingExitCommand`，仅在 `readingPage` 时安装原
`closeHistory()` 动作；输入取消、编辑器/marked text、菜单/弹层归属由同一个共享边界判断。
未改变目录的 Arrow/Return 导航、历史动画、历史完成后的目录焦点恢复或显式返回动作。

本轮只在此 detached worktree 合入指定 `9a65b0f031f8debce0155c5dda0ba5fd573aa9c4`，
未移动共享 main 引用。三个冲突的处理：

- `ConversationExecutionPane.swift` 采用 main 的共享左上 Close 和 viewport，
  保留 `presentation.context.suppressed ? nil : presentation.context.close` 的
  `nativeReadingExitCommand`。相对指定基线，该文件只有这一取消入口不同。
- 两个 README 保留双方的取消契约与 main 的阅读布局/动画说明。
- `NativeAgentThreadWorkspace` 保留 main 的 balanced vertical viewport、
  `NativeSidecardFold` paint/hit aperture 和原 Close 回调，同时保留本分支的共享取消入口。
  `NativeSidecardFold.swift` 与 `NativeReadingPanelViewport.swift` 对指定基线没有差异。
  缓存、内容保留和 native paint/hit aperture 的实现来自该指定提交，没有重新实现。

实际构建与手工观察：

- 首轮 Swift 构建失败：直接把 `closeHistory` 方法引用放进可选回调表达式时，Swift
  对 `readingLayout` 报 `failed to produce diagnostic for expression`。
  改为显式 `{ closeHistory() }` 后，同一产品构建通过（42.37s）。失败及成功日志分别是
  `/tmp/moku-history-sidebar-build.log`、`/tmp/moku-history-sidebar-build-fixed.log`。
- 临时窗口链接最终生产模块，复用 `ThreadConversation`、真实 `ThreadHistorySidebar`、
  `ThreadDetailFrame`、Moku Scene/Dock 和三个固定执行行。Dock 在组件底部的 150pt 席位内，
  避免全窗口 Dock fallback 掩盖目录自身的 SwiftUI 退出路径。无 Runtime、无模型调用。
- 已观察到：输入 open，释放编辑焦点后 Tab 聚焦 Close，再 Tab 聚焦真实目录，
  ↑/Return 进入上一轮历史；输入仍 open，导航为 Back to current conversation。
  第一次 Escape 只使输入 closed，历史和 Thread 保留；第二次 Escape 完成原历史返回，
  显示 CURRENT DOCUMENT，导航恢复 Close thread，Thread 仍 open。
- 已观察到：重新进入历史并打开输入，以键盘 Tab 聚焦历史正文的回应 TextField；
  Escape 保留 `response stays`、展开输入和历史导航，没有提升成面板退出。
- 已另外用整合后生产 `NativeAgentThreadWorkspace` 与 `ConversationExecutionPane`
  复核：左上共享 Close 可见且只收起对应卡片；卡片普通控件持有焦点时，连续两次 Escape
  依次收起输入、收起卡片，Thread 保留。源复用 `/tmp/moku-sidecard-manual.swift`；
  窗口为 `/private/tmp/mokusei-native-replay-history-integration/MokuHistoryIntegration.app`。
- 手工源与隔离窗口位于 `/tmp/moku-history-sidebar-manual.swift` 和
  `/private/tmp/mokusei-native-replay-history-sidebar/MokuHistorySidebarManual.app`。
  只调用组件编译辅助程序，没有调用测试或 replay runner。

真实 IME/输入法候选、独立弹层和动画中间帧本轮没有重新实机验证；前述限制继续有效。
本轮未运行或新增测试、CI、hooks；未运行 Go 检查或完整打包，也不把指定基线原有验证结果
当作本轮执行结果。构建结果仅指合并后当前源码的 Swift `Mokusei` 产品构建。
