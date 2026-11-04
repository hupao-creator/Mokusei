# Agent 阅读页滚动：观察范围优化

2026-11-04，基线 `8d0a252`。用户报告普通长回复滚动卡顿，之后要求先提交已有
修复、暂时停止继续排查。本次仅合入本地 main，不推送，不将局部优化视为完整验收。

## 已确认与已修改

`HarnessMessageTimeline` 原先每次滚动写入 `@State geometry`，同一个 body 又在
构造阅读控件 descriptor 时读取它。精确偏移变化因此触发整个 timeline 的四层
SwiftUI 视图构造；`visibleRows` 还在文档与 descriptor 中重复求值。

把 geometry 放进 timeline 自有的 `TimelineViewport`，仅由独立的
`TimelineInteractionRegistration` 子视图在构造时读取。父视图的 follow、定位、
追加前位置保持、相对滚动回调按执行时读取最新值。控件 schema、输入边界校验、
滚动范围 clamp 和旧 handle 拒绝规则保留；没有节流或丢弃精确位置。
可见行在每次父 body 构造时只计算一次。

## 已有证据

目标 Mac：Apple M1 Pro，macOS 26.5.1。临时原生 probe 链接当前 Debug 生产模块，
使用真实 `HarnessMessageTimeline` → `ThreadDetailTurn` → `ThreadMessage` →
`NativeMarkdownView`，一个已完成执行包含 32 节静态双语长文。窗口 1000×720，
文档高度 12674pt；一次遍历辅助功能树后，程序通过真实 NSScrollView 做 300 步
往返滚动，间隔请求为 16ms。计时中不截图、不查询 AX、不强制 layout。

现有 `MOKUSEI_TIMELINE_PROFILE` 的阶段计数显示：

| 滚动窗口内计数 | 修改前 | 修改后 |
| --- | ---: | ---: |
| 几何更新 | 298 | 298 |
| timeline body 构造 | 298 | 0 |
| ScrollViewReader / GeometryReader / content 构造（各自） | 298 | 0 |
| 新的 TextKit 排版 | 0 | 0 |

因此证实消除了不必要的视图构造，不能据此声称正文原先每帧重新解析或重建原生文本控件。

关闭性能日志的各一轮观察：进程 CPU 时间 1754ms → 1612ms；循环 wall time
5310ms → 5529ms；p95 步间隔 18.54ms → 19.53ms。CPU 仅小幅下降，步间隔没有
改善；样本不足以承诺滚动更流畅，更不能把计数或定时器间隔换算成屏幕 FPS。
这些是程序滚动，未完成物理触控板或光学帧率验收。

实际开发版上的原生 Scroll Up/Down 操作与采样也已执行。通用 CUA wheel 接口
报 `noWindowsAvailable`，应用仍在运行且没有新崩溃；不能将工具错误归为产品崩溃。
原始 probe、采样、构建日志和前后测量保存在本机 `/tmp/mokusei-scroll-20261104/`。

## 提交时的验证范围

- 修改后的 `Mokusei` Debug 产品构建成功，前后 probe 均完成 300 步、150 个不同
  实际偏移，文档宽度保持不变；未修改用户内容或发送任务。
- 静态审查覆盖 descriptor 字段、边界校验、最新 geometry 读取和视图所有权。
- 按用户要求停止后续性能排查，不新增或继续运行测试/回放；完整滚动语义回放、
  全套 Swift、托管 CI 和最终运行应用的体验验收未完成。运行中的用户应用未替换。
- 远端 required check 仍为 strict `Complete coverage`；PR 列表已查询，run 查询
  返回网络 EOF。本次的本地提交不代表远端门禁通过。
