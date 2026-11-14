# 运行中 Agent Thread 打开延迟：2026-11-14 录屏诊断

## 结论

录屏的两次打开都经历了「标题与纸面展开 → 正文淡入 → 主栏收窄、Execution
Sidecard 展开 → 输入胶囊横移并展开」。可以确认的等待来自这些入场阶段的串接，
正文出现后的再次折行也形成可见跳变。当前证据不支持把这一例归因于 8 KiB
Markdown 解析或长文本测量：两次相关 Markdown 都命中缓存，打开后 2.5s 内
记录到的全部 `text.layout` 分别累计 7.30ms、6.23ms，单次最多 0.51ms、0.42ms。

另有一个需要独立定位的异常：两次正文接管期间各出现 14 条 AttributeGraph
循环警告，stderr 字节都落在 `reading.parent.hide` 的调用边界内。
这把排查范围缩小到隐藏保留 Overview 的路径，但不是框架循环栈，不能据此
宣称已经找到主线程卡顿的唯一根因，也不能把阶段总时长当成 CPU 阻塞时间。

本次交付是录屏与既有日志的诊断、benchmark 覆盖说明，没有新的产品性能改动。

## 取证与时钟

原文件为 `录屏2026-11-14 11.05.28.mov`，2906×2036、10.711667s；
AVFoundation 解码得到 535 个视频帧。数值证据和原文件 SHA-256 见
[诊断数据](reader-opening-20261114.json)。录屏有 16.67/25ms 等多种相邻 PTS
间隔，最长 133.33ms；这不是应用 FPS 或独立的掉帧计数。

日志属于 PID 77076、performance session
`D9EBE933-9933-4E63-AD89-DCD383D69853` 和 layout session
`layout-77076-F3E29D01-9F65-4D5A-84FD-9C4A7EA8FC70`。
这是 development Debug 包，启用了 detailed performance 和 layout logging；
诊断自身的开销没有单独测量。安装包 provenance 与日志的 executable input
hash 一致，但不含源码提交，不能把它认定为当前 main 的精确构建。
源码路径解释以审查基线 `41f939f` 为准。

performance 使用单调时钟，layout 同时记录墙钟与单调时钟。
对齐采用录屏附近最近的 layout `(uptimeNs, time)` 配对；不能简单将进程启动
墙钟加上运行时长，本次那样计算会错位约 6.8s。表中的相对耗时来自单调时钟；
geometry 相对时间通过附近配对对齐。视频只按自己的 PTS 描述视觉先后，
文件创建时间没有被当作精确的鼠标点击时刻。

原始日志快照、抽帧与联系表保存在本机
`/Users/felixwang/Desktop/Mokusei/.scratch/reader-opening-20261114/`。
用户对话正文和截图没有提交到仓库。layout 旧分段已经轮转，活跃会话没有
session-end，因此报告只描述保留窗口，不把未见到的事件解释为不存在。

## 两次打开的阶段

以下零点是 `thread.open`，不是鼠标物理按下；两次分别记录于本地时间
11:05:29.397 和 11:05:34.458，context 为 269359、269826。

| 观测 | 第一次 | 第二次 |
| --- | ---: | ---: |
| 标题锚点与布局准备 span | 161.21ms | 125.88ms |
| 面板 transition span | 464.00ms | 445.93ms |
| 从 thread.open 到 transition 完成回调 | 656.34ms | 597.77ms |
| 主阅读外壳宽度从 1189pt 切换到 782pt | +889.41ms | +757.95ms |
| Execution Sidecard 五条已完成消息交付到 Markdown view | +1141ms 左右 | +932ms 左右 |
| 输入框最后一条目标位置 geometry 变化 | +1884.07ms | +1752.05ms |
| 2.5s 内 text.layout 次数 / 累计时长 | 41 / 7.30ms | 41 / 6.23ms |
| 相关 Markdown cache hit / miss | 6 / 0 | 6 / 0 |

transition 的名义动画是 420ms；span 包含提交与完成回调交付的时间，
不能把比 420ms 多出的部分全部算作可见停顿。准备 span 也包含异步等待。
输入框 geometry 的终点不是像素呈现完成或可交互性的认证。

第一次视频在 1.587s 仍主要是标题，1.678s 出现很淡的正文，1.770s 正文可读；
1.895s Sidecard 还是空壳，1.995s 已显示已完成消息。第二次分别能在 6.583s
看到无正文的标题、6.700s 看到正文、6.800s 看到尚未填入正文的 Sidecard，
6.883s 看到 Sidecard 消息。上述为检查过的采样帧，不冒充每个阶段的精确首帧。

主栏收窄时，正文视口从 1125pt 变为 718pt。日志体现的是一次目标宽度切换，
不是这次展开中每一帧都在改变 TextKit 的折行宽度。用户拖动分隔线时的实时
重排是另一条交互路径，本次录屏没有拖动动作。

`markdown.delivery` 在第二次主文档上记录了 48.42ms，但缓存已经命中，
该 span 跨越 actor 调用与回到 view 的交付，不能称为「Markdown 解析耗时」。
相关记录均为 `streaming: 0`。运行中的 execution 展示已完成的消息，
不展示未完成消息的逐 token 内容。

## 对应实现与异常边界

- [NativeReadingPanelTransition](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelTransition.swift)
  等待标题锚点和布局准备，随后由 Core Animation 驱动纸面；其开始回调允许
  主阅读器预加载，完成与标题交接后才放开后续入场。
- [NativeThreadPreparedReader](../app/macos/Sources/Shared/PluginUI/Conversation/NativeThreadIdentityBridge.swift)
  在内容就绪和布局提交后淡入正文，名义时长 200ms。
- [NativeAgentThreadWorkspace](../app/macos/Sources/Host/Sidecards/NativeAgentThreadWorkspace.swift)
  还会等待主文档与主入场就绪，才放开 Sidecard。主栏采用新的目标宽度，
  外壳单独做展开动画；Dock 横移与展开沿用
  [入场编排](reading-entrance-choreography.md) 的完成回调串接。
- [NativeReadingParentSurface](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingParentSurface.swift)
  在 representable 更新内同步设置 `hosting.isHidden = true`。两次捕获到的
  `reading.parent.hide` 字节包围区间分别为 10.90ms、10.44ms，均包含 14 条
  warning。这是具体的可复现候选边界；仅靠 warning 不能说明谁发出了循环，
  也不能量化随后 SwiftUI 重算的 CPU 占比。

因此，后续优化应先区分两个问题：缩短并减少入场阶段/正文宽度切换造成的
感知等待，以及用同场景主线程采样定位真实长任务。已有 TextKit 累计耗时很低，
继续只优化文本缓存缺乏本例的证据支持。没有从两次 Debug 观测推导 Release
提升比例，也没有声称 AttributeGraph 警告已修复。

## Benchmark 覆盖缺口

现有 [外部阅读 benchmark](../tools/benchmarks/reading/README.md) 的
`reading.first-open` / `reading.reopen` 打开一条已完成回复；
`reading.output-scroll` 会在计时前重新进入运行中的 Thread，并确认主栏与
Execution Sidecard 已挂载。因此，它们没有计量这段带活动 Sidecard 的入场。
「首批正文 checkpoint 可识别」也不等于 Sidecard 与输入框全部落定。

默认 capture 为 5Hz，且原生 hitch 能力明确不可用；既有报告不能证明这里没有
100ms 量级卡顿，更不能拿十秒 CPU 总量代替打开阶段的主线程分布。
下一轮应独立覆盖「一条 8 KiB 已完成主回复 + 已有已完成消息的运行中 Sidecard」
的系统点击打开，分别记录主正文、Sidecard 正文、几何稳定及输入就绪。
加载准备与该点击必须分开；不要把新消息完成后的变化混进纯打开指标。
这不是历史轮次或目录导航负载轴。

## 本轮验证与交付

已完成原视频解码、采样帧检查、单调/墙钟配对、两次事件与 geometry 复核，
并按 stderr 字节范围核对循环警告归属候选。检查了文档链接、JSON 与 diff。
没有运行新的 Release 外部 benchmark、原生构建、测试或 CI；本次内容是诊断
记录和覆盖说明，不能作为产品修复的验证。CI scope 的文档快速路径不包含
`design/` 或此模块 README，若以后推送会要求普通 workflow 范围判定。

按本次仅合入本地 main 的要求交付，没有远程推送。验证前只读查询显示 main
无 classic branch protection，effective rules 包含 PR/review-thread-resolution，
未返回 required-status-check；最近的 hosted runs 均属于其他提交，没有拿来
认证本次诊断。
