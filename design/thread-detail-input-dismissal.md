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
