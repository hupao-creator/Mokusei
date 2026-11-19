# Overview glass 测量证据

制品源码基线：`e8df447ea32923cc4e7b63cfdb958154ebddb527`；测量日期 2026-10-27。
报告只描述 evidence 中的指定制品、注入条件与失败尝试，不定义当前产品材质或可执行入口。
当前工具能力见 [README](README.md)：run.py 不提供实时试验，analyze.py 可读保留证据。

## 记录条件

记录制品有 all-on / shell-off / all-off 三个研究条件；区别是普通卡片外壳和其内部
徽标/Follow-up/plan 玻璃站点。该条件定义属于制品 manifest，不是当前产品配置。
所有条件等量暂停 Cloud/Dock 自主动画，保留同样静态内容。替代不透明面同时改变遮挡与
合成，观测差值不能纯归因于 glass shader。Reduce Transparency fallback 会使该实验
不再是所声明条件。正式采样矩阵为每条件 2s 稳定、4s 预热、12s 采样，三条件六种顺序。
这些是归档协议参数；没有可运行的当前构建/启动命令。

## 失败与有效性证据

环境：[host-environment.json](evidence/host-environment.json) 记录
MacBookPro18,3 / M1 Pro（10 CPU、16 GPU 核，16GiB）、macOS 26.5.1、AC、
2560×1440pt 显示和 Aqua 会话。沙箱可见性与宿主能力分别记录；没有申请录屏/AX权限，
Developer mode disabled 不能单独解释 Instruments 的可用性。

| 尝试 | 启动前检查 | 最长输入空闲 | 稳定检查 | GUI / 配对结果 |
| --- | ---: | ---: | ---: | --- |
| 14:51:31–14:54:37 二条件制品 | 180 | 124.03s | 最多 4，未达 30 | 0/24 区段、0/12 配对 |
| 15:07:17–15:10:23 三条件制品 | 180 | 101.34s，未达 120s | 0 | 0/36 区段、0/36 配对 |

第一组证据：[status](evidence/status.json)、[raw/source](evidence/count-5-prelaunch.tar.gz)。
第二组证据：[status](evidence/baseline-five-status.json)、[raw/source](evidence/baseline-five-prelaunch.tar.gz)。
分析器给出 `comparisonValid=false`、`no-mounted-fixture-metadata`；这是没有 mounted fixture
的测量限制，不是产品性能通过。两个协议不能合并。没有重跑到获得有利样本。

## 几何数据与口径

归档 [geometry.json](evidence/geometry.json) 来自无窗口生产布局/camera/card frame。
窗口 1800×1000pt、记录制品的 readableCellBudget=16；含一个 2×1 plan 卡，其余 1×1。
这只证明指定制品的数学几何，不能认证当前布局 API、可见像素或渲染成本。

| 卡片数 | 生产布局列×行 | 完整落在窗口几何边界内 | 与窗口相交 |
| ---: | ---: | ---: | ---: |
| 1 | 2×1 | 1 | 1 |
| 5 | 2×3 | 5 | 5 |
| 12 | 3×5 | 7 | 12 |
| 30 | 5×8 | 10 | 26 |

CPU 来自同 PID getrusage，100% 是一个逻辑核；RSS/physical footprint 是约4Hz采样，
缓存/分配器残留不等于独立冷进程成本。MainActor 绝对 deadline 唤醒延迟不是帧时/FPS/hitch；
相机 API 调用/追赶次数不是呈现次数。WindowServer/全机 CPU 为共享成本，不能直接归因。
主机 busy、热状态和唤醒延迟作为结果保留；明确的输入、失焦、竞争构建或损坏才破坏协议。

## 判定边界

没有有效 GUI 配对，因此 CPU、内存、GPU、帧时和能耗收益均未测得。定时唤醒、几何结果、
存在 Instruments 模板或 trace 文件，都不能补成真实呈现证据。当前源码/制品没有由此报告
取得行为或性能认证。
[validation.json](evidence/validation.json)、[manifest.json](evidence/manifest.json) 与原始归档
保留源/制品、工具与失败身份，构建日志不作为产品运行通过凭证。
