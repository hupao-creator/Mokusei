# Thread 导航与输入展开停顿

2026-11-04。基线为本地 `e17c87e`；用户提供 `录屏2026-11-04 13.49.18.mov`，
并授权在目标 Mac 操作与诊断。本次按用户确认仅合入本地 main，不推送已有的 98 个本地提交。

## 问题与规格

用户观察到 Agent Thread 打开/关闭后迟迟不开始 transition，以及阅读页的 Moku
切换到输入框时停顿。验收是及时响应与连续展开，同时保留当前三阶段顺序：主面板
和标题/emoji 到位 → 正文 reveal → 输入框与 Sidecard。取消、输入法、焦点、草稿、
当前返回目标与辅助功能子控件均保留原来的所有权。

## 定位

录屏通过 AVFoundation 解码，时长 23.563 秒。它显示了两次打开、输入展开和关闭；
没有同步鼠标事件或主线程栈，不能单凭视频给每段延迟归因。

在相同源码的 Debug 签名包中，临时数值探针区分导航接受、标题 anchor、identity
rasterization、CA travel 提交、Overview projection/prepare 和原生 editor 创建。
目标场景为同一个已完成 Thread、23 张 Overview 卡片，不发送任务或更改会话内容。
主线程 `sample` 显示，关闭时的大块时间落在
`AccessibilityViewGraph.needsUpdate` → `AccessibilityGestureModifier.initialAttachment`
→ accessibility visibility/attachment 复制，并非后台请求或布局 solver。
一次 projection 约 1–10ms，原生 editor 创建约 0.5–1ms，两个标题 glyph 的
rasterization 约 2–3ms，不能解释秒级停顿。

原有卡片没有在点击手势前建立 accessibility 容器，打开动作重复附加到标题、摘要、
统计等所有后代。画布的 pinch 手势也位于容器分组之前。导航和 Moku 输入切换改变
Overview 的可见/禁用状态时，保留在后台的树仍会重算这些手势 attachment。
实际 AX 树证实，同一卡片原先有多个重复“打开会话”动作。

## 修复

- 把画布已有的 `.contain` 分组放到 pinch 手势之前。
- 在 Agent 卡片手势前建立有标题的 `.contain` 容器，打开动作属于卡片本身。
- 子内容和独立按钮仍在树中，不采用 `.ignore`、删除可访问性或禁用辅助功能。

[Apple 的 contain 契约](https://developer.apple.com/documentation/swiftui/accessibilitychildbehavior/contain)
说明该行为将原有子元素保留为新容器的子元素。修复后的实际 AX 树与此一致。

没有修改动画曲线、420ms 面板时长、48ms 标题稳定等待、内容 reveal、输入焦点延迟、
Overview 返回准备或数据缓存。最初怀疑的重复 projection/prepare 并非主要热点，
因此不引入新的布局缓存或放宽取消/返回正确性门禁。

## 目标 Mac 观察

[不含会话正文的数值记录](thread-transition-latency/observations.json) 保留构建 input hash、
阶段和逐次时长。以下为同场景的探索性观察范围，包含 AX/键盘操作及诊断采样，
不是统计基准、硬件帧率或响应上限承诺：

| 导航接受 → CA travel 提交 | 基线 | 分组修复 |
| --- | --- | --- |
| 打开 | 1,306–1,589ms | 362–589ms |
| 关闭 | 581–1,431ms | 180–204ms |

原输入展开的一次 `swiftui.geometry` 回调出现 404ms 间隔；分组后的三次输入展开，
前 650ms 内各有 47 次 capsule geometry 回调，最大间隔约 60–63ms。
恢复已选 Thread 的启动路径原本也可流畅，不纳入此比较。布局回调不是 WindowServer
帧率；这些记录只证明原有长时间主线程/布局停顿得到缓解，不将其换算为 FPS。

原始采样、诊断构建日志及视频联系表保留在本机 `/tmp/mokusei-latency-20261104/`。
诊断探针不进入交付代码；最终构建移除探针，并补充卡片容器标题与去除重复外层分组。

## 验证

- `make lint` 通过；最终源码的签名 Debug 开发包构建和包验证通过。
- `thread-panel-transition --production --verify` 通过：正式 compositor、身份
  交接、完成/运行正文、关闭和打开中断。
- `reading-presentation --overview-mounting` 的 11 项测试通过。
- 默认 `reading-presentation` 的 14 项测试通过，包括实际返回、准备取消、窗口
  失活/resize、中断打开与历史替换。
- `reading-presentation --moku-landing`：9 项通过，1 项因原生 face 身份的两条
  断言失败。用未修改的 `e17c87e` 重新构建并执行，得到相同两处失败（463/496 行）。
  `8f47dc7` 已让 Agent Detail 的 Harness logo 替换 face 分支，旧断言仍要求同一个
  原生 face 留在树中；本次没有修改该行为或放宽断言。两组完整日志分别保留在
  `/tmp/mokusei-latency-20261104/landing-failure-final/` 与 `landing-failure-baseline/`。
- 通用 `overview-input` 首轮在 repeated reading return 超时。基线通过，临时
  带事件诊断的修复版本（包括 10 次往返）也通过；不以通过的重跑将原失败判为误报。
  源码审查发现旧回放仅等待 `detail == false`，下一次打开可能先于 SwiftUI 提交
  旧视图移除。补充真实 front 的挂载/卸载观测，等待条件同时要求 route 关闭和
  旧 reader 卸载；保持原 400ms 打开中点击、真实窗口事件与所有几何/身份断言。
  去掉诊断代码后的完整回放通过。原始失败目录为
  `/private/tmp/mokusei-overview-fm_whgda/`，最终通过为
  `/private/tmp/mokusei-overview-rqgjc8g4/`。首轮没有采集失败帧；不宣称已经从像素
  或失败事件追踪唯一确定原超时原因。
- 最终无探针签名开发包 `generation-2642239477` 在目标 Mac 启动（PID 67769），
  确认鼠标打开/关闭、输入焦点、临时草稿跨关闭/重开恢复。临时文字已清除，未发送
  任务；退出阅读页后恢复最初的 Mokusei 目录筛选，修复版保持运行。
- 诊断阶段的细分探针构建曾缺少 `MokuseiCore` import；补全后构建成功，最终已
  移除全部临时探针。该失败不涉及交付代码的运行结果。
- 不新增单元测试、不重复本地全量 `make check`。远端规则已查询，要求 PR 和 strict
  `Complete coverage`；本次仅本地合入，未触发/声称托管 CI 通过。
