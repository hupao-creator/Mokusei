# Execution 完成交接 · 原生动画提案

这是独立 demo，不接入生产交接。采用两段顺序动画：先让 sidecard 收入
变宽的主面板，再让主 detail 从上一轮向下翻到最新结果。支持反复播放、
原生滚动与文本选择、慢速、长结果、深浅色和减弱动态效果。

## 启动

需要 macOS 26+、Xcode 的 Swift/Metal 工具链和可用的图形会话。
在仓库根目录执行：

```sh
python3 demos/execution-handoff/build.py --open
# 已编译当前 worktree 的 Mokusei 产品时：
python3 demos/execution-handoff/build.py --skip-build --open
```

构建器只执行 `swift build --product Mokusei` 和 demo 的 `swiftc`，
不编译或执行测试。受限环境无法启动嵌套 SwiftPM sandbox 时可添加
`--disable-sandbox`；Swift 宏、签名和启动仍需要环境允许对应进程。
首次构建需要下载 Package.resolved 固定的依赖。

app 路径写入 `.build/execution-handoff/app-path.txt`，可再次启动：

```sh
open -n "$(cat .build/execution-handoff/app-path.txt)"
```

app、资源及独立工作目录位于 `/private/tmp/mokusei-native-replay-execution-*`。
复用现有 `NativeReplay` 打包与隔离入口，不替换、退出或重启已安装的 Mokusei。
不读取用户 profile、连接 Runtime、执行真实任务、打开网页或麦克风。

## 使用

| 控件 | 行为 |
| --- | --- |
| 完成新 execution / 重播交接 | 从相同 fixture 重复展示；⌘Return。播放中也可以重启。 |
| 回到运行中 | 取消旧动画和延迟回调，恢复主 detail + 运行中 sidecard；⌘R。 |
| 右侧执行入口 | 播放交接；运动中点击则取消并恢复运行中。 |
| 主面板 Close | 恢复运行中，不关闭独立 demo。 |
| 慢速 3× | 下一段几何动画使用三倍时长，便于观察裁切和交接。 |
| 长结果 | 换用可滚动的长 Markdown fixture，并恢复运行中。 |
| 减弱动态效果 | 跳过收入、变宽、翻页与完成停顿；仍等待正文排版。 |
| 深色 / 窗口尺寸 | 对比生产配色及 960×680、1240×800 的双栏布局。 |

系统 Reduce Motion 始终优先：开启时无法用 demo 开关覆盖。系统设置变化
会被监听，运动中启用会停靠到已就绪的新结果。不会修改全局无障碍设置。
调整运动中的窗口会在正文就绪后直接停靠，旧动画不得继续覆盖新几何。
demo 最小内容尺寸为 960×620；不模拟生产的更窄堆叠布局。

## 调查与实现边界

检查基线：`5dda663a38fd91beb9a9229458217d76bd432d77`。

- 技术栈：SwiftUI + AppKit，SwiftPM 包声明 macOS 26；生产面板使用
  Core Animation，普通 history 采用纵向整页替换。
- `NativeAgentThreadWorkspace` 组合主 Harness reader、sidecard、分隔线与
  右侧 launcher。运行中的 execution 由 sidecard 独占，主 reader 排除该轮。
- `NativeSidecardWorkspaceModel` 检测同一 execution 终止后保留 source reader；
  现有 `handoffProgress` 使用 420ms 的共享 replacement 曲线把 sidecard
  扩展到主面板。旅行完成后才允许主 reader 接入该 execution，再等待内容
  readiness 后以 160ms 淡出 source。Reduce Motion 保留 readiness gate。
- 这说明现有路径以横向扩展 source 为主，并未把“主阅读页向下翻到下一轮”
  作为这一交接的主要视觉方向；这里只提出另一种编排，不宣称已诊断掉帧原因。

demo 复用 `ThreadConversation`、`HarnessMessageTimeline`、`ThreadDetailTurn`、
`NativeMarkdownView`、`ThreadTokenUsage`、面板 Close，以及生产字体、图标和配色。
两轮执行与 sidecard 状态由内存 fixture 提供；未连接完整插件会话和业务请求。
Browser / Voice 图标仅用于保持场景，不提供操作能力。

完成按钮保留正在阅读的上一轮 reader 及滚动位置，只更新 sidecard 的完成内容。
新结果在透明度门禁后准备，通过 `NativeMarkdownView.onDocumentApplied` 确认
各文档排版后，保留 220ms 完成状态，再执行：

1. 420ms：sidecard 保持原尺寸向左收入主面板后方，由正在变宽的主面板
   自然遮住。上一轮正文保持可读并居中平移；新结果尚不出现。不缩小、不渐出。
2. 第一段的宽度动画真实完成后，再执行 420ms 纵向翻页：旧页整页向上离开，
   新页从底部进入。此时主面板已经全宽，不再改变宽度或收入 sidecard。
3. 解除新阅读页的输入与辅助功能门禁，恢复滚动与选择；不请求焦点。

待进入 reader 先在透明度门禁后准备，AppKit 的 model viewport 在旅行期间
保留在可见区域，避免 TextKit 提前裁掉原生文字。Core Animation 单独移动呈现层，
离开的页面与 sidecard 保留动画终值直到完成回调将其隐藏。主正文与 sidecard
保持原字号；文本排版宽度在一次交接中保持不变，
只在用户调整窗口时重新排版。动画 completion、排版回调、取消与重播均由 visit identity 隔离。
两段动画由第一段的 completion 串联，不以计时器猜测第一段是否结束。
减弱动态效果移除几何动画，不以固定延时替代内容就绪。

这里的接管、宽度策略、时序、Close 行为均是 demo 提案。生产源码、业务状态机、
存储及导航未修改；不能把此展示当作真实 Harness/Runtime 交接的集成认证。

## 展示截图

```sh
python3 demos/execution-handoff/build.py --skip-build --capture
```

这是无断言、无测试运行器的展示序列，只截取自身窗口。覆盖普通/慢速交接、
取消、窄窗口深色长结果与 demo 减弱动态效果开关。
截图、观察时刻 `samples.json`、隔离收据及进程日志位于
`.build/execution-handoff/evidence/`。截图采集有额外开销，不能用于 FPS 结论。
共享图形会话锁用于避免与其他原生回放同时启动。

本次构建、观察结果与限制见 [验证记录](validation.md)。
