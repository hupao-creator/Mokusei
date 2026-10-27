# Overview Thread 卡片 Liquid Glass 性能调查

日期：2026-10-27。产品源码基线：`e8df447ea32923cc4e7b63cfdb958154ebddb527`。
本研究只修改当前 worktree 的研究工具；运行时复制 `app/macos` 到 `.build/overview-glass/package` 注入实验开关，不写用户偏好、Runtime 数据，也不触碰正在运行的应用。

## 结论

**目前不能给出启用与完全不使用卡片 Liquid Glass 的可信性能百分比。**
旧协议与本次三条件五卡尝试都只完成了启动前门控，得到 0 个 GUI 区段。没有有效配对时，CPU、内存、GPU、帧时和能耗的收益均为“未测得”，不能把几何、定时唤醒或旧的仅外壳实验换算成百分比。

| 证据 | 已证实 | 不支持的推断 |
| --- | --- | --- |
| 生产源码与研究注入 diff | `glassWorld=false` 只移除外壳玻璃；徽标、Follow-up、plan 需另关 | 设置开关等于“全无 glass” |
| Release 研究 fixture 构建 | 生产组件和研究注入可编译 | 实际窗口已呈现或 GPU 已采样 |
| 无窗口生产几何 | 1/5 卡完整在 1800×1000pt 窗口边界内；12/30 卡自然溢出 | 12/30 卡被产品拒绝、或者玻璃成本更高 |
| 历史五卡门控归档 | 用户会话活动使该次实验无法启动 | glass 打开/关闭的性能差 |

## 实际玻璃范围与对照

产品 Canvas 在 [NativeOverviewCanvas.swift](../../../app/macos/Sources/Host/Overview/NativeOverviewCanvas.swift) 为每卡构建独立外壳 `GlassEffectContainer`，外壳使用 regular glass；语义卡片在另一个 plane/container。`glassWorld=false` 把外壳换成不透明 surface 与软边框。
[ThreadCardBrand.swift](../../../app/macos/Sources/Shared/PluginUI/Cards/ThreadCardBrand.swift) 的圆形语义徽标及 Follow-up 共用一个 glass surface；[ThreadCardSections.swift](../../../app/macos/Sources/Shared/PluginUI/Cards/ThreadCardSections.swift) 的进行中 plan 行也有 regular glass。终态徽标的 `.ultraThinMaterial` 属经典 Material，三条件保持相同。Chrome/Dock 不属于卡片对照，保持生产实现。

| 条件 | 外壳 | 徽标、Follow-up、plan | 解释 |
| --- | --- | --- | --- |
| `all-on` | regular glass | regular glass | 当前默认卡片外观 |
| `shell-off` | 生产 `glassWorld=false` 的不透明外壳 | 仍为 glass | 只评价现有设置开关 |
| `all-off` | 同 `shell-off` | 注入 `.identity` 与普通 surface | 卡片内全部已知 Liquid Glass 站点关闭 |

研究脚本扫描卡片边界的 `.glassEffect` 站点，新增站点或源码漂移即拒绝补丁。`all-off` 的空 `GlassEffectContainer` 与 `glassEffectID` 仍保留结构身份，实际效果设为 `.identity`。该对照同时改变不透明面的遮挡与合成关系，所以得到的是**替代实现整体差值**，不能纯归因于 glass shader。若应用启用 Reduce Transparency，实验拒绝采样，因为 on 侧可能走系统 fallback。

每卡单独 container 有生命周期原因：生产源码说明若跨卡合并，退出动画可能只淡出文字而遗留玻璃。没有证据支持直接合并 container 或默认关闭玻璃。

## 实验协议与测量边界

入口为 [run.py](run.py)、[trial.swift](trial.swift)、[analyze.py](analyze.py)，复现命令见 [README](README.md)。同一 Release 进程在六轮内跑三条件的全部六种顺序，场景顺序轮流反向。每条件 2 秒稳定、4 秒预热、12 秒采样；相邻三条件构成一个重复块，报告逐对差值及六轮范围。任何明显外源干扰使相应配对失效，原始区段保留，不重跑到“过关”。

先在 1800×1000pt、浅色、五张卡上完成 `baseline`：静止与固定 scale 的纯平移。平移按绝对 deadline 请求 60Hz 的相机 API 调用，只是工作负载脚本，不是显示刷新率。得到有效基线后，再分开运行 `extended`：含 scale 变化的缩放场景和 10Hz 单卡内容更新；最后扩展到 12/30 卡自然溢出。内容更新通过真实 Canvas 的 `presentationID` 和卡片标题，最终 revision 的 `onChange` 记录仅证明 SwiftUI 观察点接收了最终值，**不证明每一次更新都上屏**；未接收到也作为结果保留，不按污染删除。

五种卡片循环使用生产 Harness/Report 组件。研究 fixture 给 Codex、Claude、Pi、OpenCode 注入与生产卡片相同的 `threadCardCloudPalette`；running Cloud 因此真实存在。[ThreadCardCloud.swift](../../../app/macos/Sources/Shared/PluginUI/Cards/ThreadCardCloud.swift) 在没有 palette 时不会绘制 Cloud，旧 fixture 的“冻结 Cloud”描述不准确。自主 Cloud/Dock 动画在所有条件等量暂停，保留 Cloud 内容和相同的静态构图；它不测 Cloud 动画开启时与 glass 的交互成本。

| 指标 | 来源与意义 | 限制 |
| --- | --- | --- |
| 自身 CPU | `getrusage` user+system / 单调区间；100% 为一个逻辑核 | 不含 WindowServer、GPU、Runtime |
| RSS/physical footprint | 同 PID `TASK_VM_INFO`，约 4Hz 的中位/峰值 | 同 PID 存在缓存与分配器遗留，不是独立进程冷启动内存差 |
| 主线程定时唤醒 | 绝对 deadline 到 MainActor 恢复的 p95/max | 不是帧时、FPS、呈现 hitch |
| 动作执行/追赶 | 实际相机 API 调用次数、落后超过一周期的次数、调用吞吐 | 多次调用可在同一次呈现前追赶，动作数不是帧数 |
| 主机负载 | host CPU ticks 与 2 秒一次 `ps` | `ps` 的 WindowServer 滚动 CPU 是全会话共享，不能直接归因于本 fixture |
| GPU/真实帧/能耗 | 需有效 Instruments trace/能耗观测 | 本 counter runner 未采集；存在模板或 trace 文件并非有效证据 |

主机 busy >40%、唤醒迟到 >250ms 和热状态属于**结果**，不会自动删去；否则恰好会筛掉 glass 自身造成的过载。分析器标记已知外源进程、自身进程 CPU 足以解释全机 busy、或无法归因。自身 CPU 足够只是算术归因下界，WindowServer/GPU 仍未分离。启动前要求 120 秒无输入、30 秒无编译；窗口失焦、用户输入、外部构建及采集损坏才使协议无效。普通用户应用不会被停止，试验不会抢回焦点。

要声称 GPU 或呈现 hitch，须实际采到**本 fixture PID 与目标条件区段**，并核对 trace 的有效帧/事件。此前没有这样一份有效 trace，本报告不引用模板清单作 GPU 结论。

## 已有实测与归档

[环境证据](evidence/host-environment.json)记录 MacBookPro18,3 / M1 Pro（10 CPU、16 GPU 核，16 GiB）、macOS 26.5.1、AC，主屏 2560×1440pt，足以容纳固定窗口。宿主有 Aqua 会话；沙箱内空屏幕/空会话是可见性限制。屏幕录制与辅助功能未预授权；没有申请权限。开发者模式未启用，也没有据此断言 Instruments 必然不可用。

**旧协议正式五卡尝试：2026-10-27 14:51:31–14:54:37（北京时间）。** 启动前 180 次检查中，输入空闲最长 124.03 秒，同时满足 120 秒空闲且无编译的连续检查最多 4 次，未达 30 次。没有打开 GUI；正式区段 0/24、配对 0/12。原始数据在 [count-5-prelaunch.tar.gz](evidence/count-5-prelaunch.tar.gz)，紧凑状态在 [status.json](evidence/status.json)。这个归档属于旧的二条件静止/平移缩放/刷新协议，不能与新协议样本合并。

**本次三条件五卡基线尝试：2026-10-27 15:07:17–15:10:23（北京时间）。** 启动前 180 次检查中，输入空闲最长 101.34 秒，没有一次达到 120 秒，连续稳定检查最多 0 次。没有竞争编译/回放或监控错误，也没有打开 GUI；正式区段 0/36、逐对比较 0/36。分析器返回 `comparisonValid=false`、`no-mounted-fixture-metadata`，这是预期的无窗口结果。原始门控、构建身份、研究注入 diff 和测量源码在 [baseline-five-prelaunch.tar.gz](evidence/baseline-five-prelaunch.tar.gz)，紧凑结果在 [baseline-five-status.json](evidence/baseline-five-status.json)。没有停止用户活动，也没有因门控失败反复启动直到取得有利样本。

该归档保留了**尝试当时**的源码；门控失败后，本地 review 又修正了窗口准备阶段的主机负载/热状态筛选，以及刷新最终 revision 未及时观察时的样本筛选。最终源码另行完成 Release 构建，没有把未运行的最终构建写成一次 GUI 实测。

无窗口几何探针运行了生产布局、camera fit、card frame，输出见 [geometry.json](evidence/geometry.json)。它不创建窗口，不测渲染。窗口 1800×1000pt、readableCellBudget=16，plan 卡占 2×1 格，其余占 1×1：

| 卡片数 | 生产布局列×行 | 完整落在窗口几何边界内 | 与窗口相交 |
| ---: | ---: | ---: | ---: |
| 1 | 2×1 | 1 | 1 |
| 5 | 2×3 | 5 | 5 |
| 12 | 3×5 | 7 | 12 |
| 30 | 5×8 | 10 | 26 |

12/30 卡仍全部有布局 placement；相机维持可读比例，边缘/屏外自然溢出。“完整落在窗口内”也不等于未受 Chrome/Dock 遮挡的像素可见数。

[历史性能记录](../overview-performance/SUMMARY.md)与 [后续接续记录](../overview-input/evidence/glass-completion/README.md)里的旧实验仅切换外壳，且有失焦、主机忙、区段不完整等问题。即使局部 CPU 读数存在，也不能回答“全部卡片 Liquid Glass”的收益。

## 判断与下一步

大面积外壳、Cloud 与 glass 的交互、缩放时的 SwiftUI 提交，均只是待验证瓶颈假设。先完成五卡有效基线，再看扩展场景与大集合；若仍无法获得无干扰的图形会话，就保留未测得结论。建议只在真实 trace 指向具体路径后讨论优化，并复核退出玻璃残留、语义控制、对比度及内存缓存效应。

## 验证记录

本修订已执行 Release 研究 fixture 构建、Python 语法与分析器 36 区段/36 配对合成回放、无 metadata 的失败路径、Markdown 本地链接和 diff 检查；五卡 GUI 回放仅完成上述启动前门控。`make check ARGS=` 已通过，包括 Swift build 与 13 个目录标签用例。裸 `make check` 因外部环境传入 `ARGS=--fresh` 在性质测试处停止，该参数不是测试二进制支持的选项；清空参数后全部通过。未运行成功 GUI 呈现、像素核验、有效性能配对、Instruments 的目标 PID/区段 trace、GPU/真实帧/能耗测量。生产源码没有改动。

最终检查状态与限制在 [validation.json](evidence/validation.json)。历史构建和 `make check` 日志在 [validation.tar.gz](evidence/validation.tar.gz)；它们仅验证前一版协议的源码，不能代替本修订的验证。归档 SHA 见 [manifest.json](evidence/manifest.json)。
