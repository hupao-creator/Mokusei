# Agent Thread 打开动画调研与隔离优化

日期：2026-11-03。源码基线为本地 main `0a56037e8ac2fed114b7478bbda18bbe959c9f6c`；
只读 `ls-remote` 确认的远程 main 为 `8ca887b832aae6dd788781bb36df0b080533ba7f`。
工作树保持 detached；未操作 main 或共享 refs。本文的录屏定位和基线测量针对本地 main，
不能把当前运行的二进制认定为这个精确提交：安装目录 provenance 只声明 Debug 与输入哈希。

## 结论

**高置信度：原先的面板逐帧驱动与阅读挂载竞争主线程，是必须消除的耦合。**
420ms 面板动画原本由 MainActor Task 每次 sleep 8ms 后修改 SwiftUI progress；
同一时间开始挂载阅读 surface、申请内容、构造 Codex 投影、创建可选中文字及布局。
主线程迟到时，下一次按墙钟采样直接跳过中间姿态。录屏确有这种几何停顿与跳跃，
隔离生产组件也确有首次及重复打开的主线程长间隔。

**中等置信度：阅读首次挂载、原生文本初始化和重复的 Codex 投影构造是贡献者。**
它们能在真实负载快照下独立产生长间隔，但不足以解释录屏全部延迟。
完整 Overview、Sidecards、输入胶囊、Runtime/离线缓存往返和 WindowServer 的精确占比
没有在原录屏时同步采样，不能宣称已唯一定位某一个耗时函数。

**没有证据把本例归因为“渲染了大量 Markdown 消息”或“后台 cmark 在主线程解析”。**
默认只展示最终回复；普通 Markdown parser 和 RuntimeClient 本身是独立 actor，
不能把它们的等待时间等同于主线程 CPU 时间。

实现针对结构性耦合处理：原生合成器独立驱动面板，打开完成后再挂载 reader；
提前冻结 Overview 展示投影，Codex 阅读校验/解码离开主线程，隐藏执行过程不再构造其行。
正文仍可能稍后出现，这与动画是否能连续推进是两个指标。
本版选择在展开后才挂载阅读器，因此轻负载正文也有约 420ms 的动画等待下限；
没有声称首屏正文总延迟在所有条件下都下降。后续可在动画已提交后后台预读/解码，
进一步缩短正文等待，前提是保持原生合成驱动与有界、可取消的交付。

## 录屏的实际时间与阶段

原文件：用户提供的 `录屏2026-11-03 14.35.02.mov`。
SHA-256：`e90c393714121c5d2bbdd9cba704b94252d2337d38d2f441cc0e1202b7b2d261`。
AVFoundation 实际解码 426 帧，4096×2520，时长 11.936667s。
平均约 35.7 帧/s；425 个相邻 PTS 间隔中，16.67ms 有 152 个，33.33ms 有 264 个，
50ms 有 4 个，66.67ms 有 3 个，83.33ms 有 2 个。
因此录屏本身不能认证显示器达到 60/120Hz，也不能用 nominalFrameRate 计算应用掉帧。
但画面连续数帧维持同一面板尺寸，远长于录屏单帧间隔，是真实可见的停顿证据。

| 事件 | 第一次观察到的打开 | 同一 thread 的重复打开 |
| --- | --- | --- |
| 来源卡片正文消失 | 1.183s，帧 38 | 6.067s，帧 216 |
| 首次可见展开的面板 | 1.833s，帧 65 | 6.467s，帧 228 |
| 两者之间的可见等待 | 约 650ms | 约 400ms |
| 可见面板几何到达终点 | 1.967s，帧 71 | 6.767s，帧 241 |
| 正文与图片已出现 | 1.967s | 6.983s，帧 250 |

来源卡片变化是视觉阶段标记，**不是鼠标事件时间戳**；上述等待不能冒充精确点击延迟。
第一次只是录屏内第一次打开，不能认定该应用进程此前从未打开过 thread。

第二次的尺寸在 6.467–6.550s 停留约 83ms，随后突然扩大；
6.583–6.767s 又维持同一接近终点的尺寸约 183ms。
面板到达终点后仍只有标题，约 217ms 后正文出现。
第一次只录到四个展开几何位置；第二次也只有四个明显的几何位置。
关闭时同样存在停顿：约 4.233–4.467s、9.050–9.233s 的中间姿态维持不变。
关闭时正文早已存在，进一步说明首次加载不能解释全部几何卡顿。

几何量化把视频缩小到 1024×630，在 y=500 的空白纸面扫描连续白色区间。
阈值 248、250、252 的右边缘变化时间相同，最多相差 1px。
这只是画面边缘代理；有正文穿过或面板离开该扫描线时不能作为完整矩形检测。
[原始 PTS](thread-open-animation-profile/frame-timestamps.csv) 与
[扫描数据](thread-open-animation-profile/panel-geometry.csv) 保留了实际时间。
完整抽帧/联系表在本机 `/tmp/thread-open-profile/`，未复制用户的会话正文到仓库。

## 真实负载与代码路径

只读 SQLite 查询取得对应已完成 Codex thread 的快照；不连接其 Runtime、不触发订阅，
也未调用会更新文件 mtime 的生产离线缓存读取方法。快照时数据库共有 52 个 thread。
目标只有 1 轮执行、329 条时间线记录：241 activity、59 reasoning、11 assistant、
16 notice、1 user-message、1 diff。持久记录 609451 字节，这不等于发到阅读器的体积。

用生产 `codex.ProjectRenderer` 对该快照计算：thread manifest 为 4131 字节，
turn deferred projection 为 136695 字节，完整 execution projection 为 605715 字节。
默认收起执行过程后，最终回复只有 747 字节（412 个 Unicode 码点），
带一个会自动生成本地图片预览的文件链接：图片 1440×600、约 221KiB。
11 条 assistant 时间线不等于默认同时挂载 11 个 Markdown view。

关键路径：

1. [workspace open](../app/macos/Sources/Host/Shell/NativeWorkspaceView.swift)
   选择路由、保存选择偏好、更新输入胶囊/voice/presence。偏好写文件是同步路径，
   本轮没有它的延迟样本，不能认定它是瓶颈。
2. [reading stack](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPageStack.swift)
   原先把 panel aperture、位置和背景效果绑定到 MainActor progress。
   强调曲线在前 168ms 只行进约 20%，中心 84ms 完成约 60%；
   缺失中心几帧时感知尤其突兀，但改曲线不能解决主线程占用。
3. [Harness surface](../app/macos/Sources/Host/HarnessHost/NativeHarnessThreadSurface.swift)
   先申请 manifest，再由可见 row 申请 turn。关闭释放 surface、资源和原生阅读树；
   重复打开仍有挂载/校验/布局成本。离线数据与 Markdown parse cache 不等于保留 TextKit view。
4. [conversation](../app/macos/Sources/Shared/PluginUI/Conversation/ThreadConversation.swift)
   排除历史正文，只挂当前/指定轮。时间线外层窗口有限，但内部用 VStack，
   当前 execution 内的大段可见内容仍会集中布局；不是全历史无限懒加载。
5. [Markdown](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownView.swift)
   在 parser actor 解析，缓存有 48 项/4MiB 源文预算；回到主线程发布块、创建 attributed text、
   TextKit storage 与测量。图片在后台缩略解码，之后主线程安装并改变正文高度。
   [文本测量](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownText.swift)
   已按宽度和 scale 缓存；旧面板也先给正文固定目标宽度，不能无证据指称每帧都在重新折行。

## 隔离测量

全部使用当前生产模块和本地负载快照，独立 NSApplication、无 Runtime/网络服务、
不激活的 2048×1260 屏幕外窗口。边界提供 ready 内容，绕过实际订阅/磁盘/Go 排队。
每个条件一个新进程、连续三次打开/关闭；它们是有限观察，不是统计显著的基准。
记录 8ms 主 run-loop 计时器的最大回调间隔，**不是渲染帧时长或 FPS**。
机器上另有用户应用与预览进程，未清理或终止它们，也未控制温度/功耗。

基线结果（ms）：

| 条件 | 首次打开最大间隔 | 重复 1 | 重复 2 |
| --- | ---: | ---: | ---: |
| Debug 纯面板壳 | 15.69 | 10.20 | 11.88 |
| Release 真实最终回复与本地图片 | 135.08 | 22.50 | 23.63 |
| Release 真实 Codex manifest + deferred row | 164.05 | 43.39 | 36.58 |
| Debug 同上 | 201.00 | 62.27 | 53.54 |
| Debug 20 倍正文合成负载 | 143.19 | 108.27 | 103.08 |

20 倍只是约 15KiB 正文与重复本地图片链接，不代表 20 个真实 thread，也不是跨条件
“首次比重复更快”的因果证据。它说明更大的单页仍能在热打开时产生长主线程间隔。
没有覆盖超长代码/表格、数百轮历史、展开全部工具过程或活跃流式高负载。

生产 Go 投影加 JSON 序列化各观察 30 次：manifest p50/p95 为 0.017/0.022ms，
turn 为 0.417/0.772ms，execution 为 0.936/1.478ms。
只认证投影函数本身；不覆盖线程锁、Runtime 实时负载、存储或传输排队。

对独立进程做过一次 4s/1ms sample，冷打开最大间隔被放大到约 762ms。
栈里有 `MarkdownTextView.replaceContent → NSTextStorage → NSTextView WritingTools → dlopen`
及同步 dyld 调试通知等待。**这个数值不用于产品性能结论**；随后无采样重测采用上表。
栈也能见到字体注册、SwiftUI 布局、Codex 解码与 preference 合并，
但不能把 inclusive sample 计数相加或换算为某函数的无扰动耗时。
[摘录](thread-open-animation-profile/sampling-notes.txt) 与
[汇总](thread-open-animation-profile/measurements.json) 保留了工具扰动说明。

## 实现与接下来的优化边界

- [原生 panel viewport](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelTransition.swift)
  在独立原生承载层上一次提交 position、rounded mask path 和 closing opacity 动画。
  没有逐帧 MainActor tick；内容按目标宽度保持一个 hosting view。
  打开完成才挂载 front，取消/路由替换用 generation 阻止旧完成回调；反向采样呈现层。
- Overview 展示投影从打开开始即暂停，权威 catalog 仍接收更新。
  settled close 保留原来的刷新/布局准备，垂直历史与非 panel 导航保持原驱动。
- [Codex 阅读 admission](../app/macos/Sources/Plugins/Harnesses/Codex/CodexReadingState.swift)
  在每个 reader 的 actor 中串行校验、解码；取消的排队请求先检查取消，
  避免流式更新启动并行的旧解码。只把可信 Sendable DTO 发布给 UI。
- [Codex 行构造](../app/macos/Sources/Plugins/Harnesses/Codex/CodexTurnRows.swift)
  在执行过程收起时跳过其行构造和 activity 字典；显示过程后按原始内容重建。
  最终回复与显式错误沿用原来的共享过滤规则，不丢弃 canonical 数据。

没有修改 Go 投影契约、降低错误可见性、裁剪消息正文或改用户数据。
如果后续仍有正文延迟，应在克隆数据的完整 workspace 上分别记录 manifest/row ready、
主线程 admission、首次 Markdown apply、TextKit 首次 layout 与本地图片 apply 的时间。
再按证据决定是否缓存已验证的 typed DTO、缩小隐藏工作元数据或限制大页首批布局；
避免把所有逻辑简单搬到后台后引入无界并发或取消后的陈旧内容。

## 最终实现观察与交付范围

完整 `Mokusei` Release 生产构建与 Codex/UI Debug 生产构建已执行；
最后的关闭中几何写入保护与环境颜色解析也纳入最终完整应用增量构建；纯装饰承载层也不接管空白处的输入。较早的一次完整构建因编辑中的输入文件发生变化被编译器拒绝；停止修改生产
源码后重新构建完成。没有把先前产物的构建结果认证最终源码。

最终同负载、无采样、相同屏幕外 2048×1260 窗口观察（ms）：

| 最终生产模块 | 首次运动期间最大间隔 | 重复 1 | 重复 2 | 首次包含正文挂载的最大间隔 |
| --- | ---: | ---: | ---: | ---: |
| Debug | 10.21 | 10.85 | 10.06 | 212.03 |
| Release | 9.53 | 11.99 | 8.82 | 110.71 |

计时条件依然只是主 run-loop 回调，不能转述为 90/120FPS。
Debug 重复打开包含正文的最大间隔为 21.75/23.69ms，Release 为 13.50/19.32ms。
首次剩余的超过 33ms 间隔全部发生在 `motion.active == false` 时；
row 资源在打开请求后约 441–622ms 才被申请，已经越过 420ms 面板运动。
这些有限同机观察支持结构隔离和重复打开成本下降；首次总成本未稳定下降，
不能认证复杂整机负载下的绝对值。

为避免把计时器当作画面证据，另用 ScreenCaptureKit 的 `currentProcess` 与
`desktopIndependentWindow`，只捕获独立分析进程自己的 960×620 窗口；不请求其他
窗口/音频或屏幕权限，窗口不激活并置于现有窗口后方，分析后退出。
在本进程主线程同步占用 **285.36ms** 的时段内，实际取得 **11 个 complete 合成帧**；
其中 10 个可见纸面姿态均不同，扫描右边缘从捕获图的 x=496 移至 x=895。
[窗口合成观察](thread-open-animation-profile/compositor-observation.json)
保留帧的显示 PTS 与回调相对时间、纸面边缘和白色像素数。
这直接支持“已提交的面板运动不等待主线程逐帧执行”，但不认证请求进入主线程前的
输入延迟、60FPS、所有桌面负载或完整 app。

屏幕外窗口的首次 ScreenCaptureKit 尝试没有输出图像；同进程在后台读取 presentation
layer 也会维持缓存姿态，不能证明渲染服务停止或继续运动。两者均未作为通过证据；
上述实际窗口合成帧才用于独立运动结论。最终阅读截图另外检查了面板位置、正文和本地
图片；其中发现并修正了 AppKit 原点 anchor 与普通 CALayer 中心 anchor 的差异。

另一个只操作生产公开状态的组件演示观察到：打开中反向关闭最终关闭；关闭中 resize
完成已接受的 Close；替换 identity 后旧完成没有关闭新路由；显式 cancellation 保留打开
路由，`finishingClose` 完成已接受的关闭；disabled presentation 直接 settle。
[状态记录](thread-open-animation-profile/lifecycle-observations.json) 没有测试断言或测试 hooks。
真实系统 Reduce Motion 切换、编辑器焦点/IME、复杂 Sidecards、WebKit、应用 zoom、
完整 workspace 与真实持续流式负载未做本轮手动认证；构建和结构审查不能替代这些观察。
关闭期间额外连续改变 10 次 reader 输入，承载层 model position 始终保持关闭目的地，
没有被内容更新重置，最终 route 关闭；[记录](thread-open-animation-profile/closing-updates.json)
保留了各次模型位置。原生纸面颜色显式从 SwiftUI 环境解析，避免依赖全局 AppKit 外观。

所有手动分析进程均自动退出，
未激活、重载、停止、替换或向用户运行中的应用发送命令；未修改用户配置/会话数据库。
未新增或运行测试、历史测试、CI、测试 hooks，也未推送、建 PR 或合并。
工作流的文档快速路径并不包含 design 下这些取证文件；本次还包含原生代码，
不能把没有运行的托管检查说成通过。
