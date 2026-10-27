# Glass World 对照接续记录（2026-10-25）

**完整对照仍未完成，不能判断 on/off 优劣。** 新流程已修复连续污染仍继续采集、后台启动拿不到首次焦点、无效分析仍返回成功等可控问题。最新正式试验在第 6 段触发原有主机负载门槛后自动停止；没有重复补跑或降低门槛。当前没有采样进程占用窗口。

[有效性图](validity.svg) · [机器可读状态](status.json) · [归档校验清单](manifest.json) · [完整协议](../../PERFORMANCE.md)

## 三次试验的证据

| 试验 / 固定源码 | 测得 / 计划 | 有效 / 无效区段 | 有效配对 / 要求 | 结论 |
| --- | ---: | ---: | ---: | --- |
| run-3 / `8dac39dec` | 32 / 32 | 6 / 26 | 3 / 16 | 第 7 段开始连续失焦；旧数据仅用于诊断 |
| run-4 / `9eb0bfff8`，生产 `e7afacc21` | 0 / 32 | 0 / 0 | 0 / 16 | 后台 LaunchServices 启动没有取得初始焦点 |
| run-5 / `b8b2bc5c0`，生产 `e7afacc21` | 6 / 32 | 5 / 1 | 2 / 16 | 第 6 段全机 CPU busy 41.29%，超出 40% 门槛 |

各试验是不同固定构建，未合并样本或进行跨版本性能比较。上述“有效区段”仍不足以令整个试验有效。
最新分析器对三组证据均返回非零；[run-3](run-3/summary.json)、[run-4](run-4/summary.json)、[run-5](run-5/summary.json) 的完整排除结果可复核。

run-3 的前 6 段在 13:36:42–13:38:26 有效。13:38:32 起的后 26 段都失去 active/key 状态，其中 3 段还有指针移动、3 段主机负载超标。保留的进程监控未发现编译或回放重叠。旧版未记录失焦后的前台应用，不能将这 26 段归因于用户。旧驱动没有在失焦后停止，旧分析器也没有用退出码拒绝无效对照。

run-4 的 180 次 readiness 检查全部 inactive / non-key，前台保持日常 Mokusei。会话长时间没有输入；这是本次采用 `open -g` 造成的启动控制问题。后续改成输入空闲门控后的一次普通 LaunchServices 启动，移除额外 `NSApp.activate`，不反复抢回焦点。run-5 的全部 42 次 readiness 检查均 active/key，并取得连续 30 秒稳定区间，证实初始启动问题已解决。

run-5 的失败区间为 **16:13:22.541–16:13:34.544（Asia/Shanghai）**。静止 fixture 只用约 **0.49% 单核 CPU**，全机 busy 为 **41.29%**。该区间没有检测到会话输入、焦点丢失、指针移动或命名的编译／回放干扰；输入空闲年龄至少约 7,212 秒。区间内 `ps` 观察到 CodexBar 约 98–195%、日常 Mokusei 54–150%、Runtime 8–99%、WindowServer 54–76%。这些是 OS 滚动估计，不能精确分摊该 12 秒区间的 CPU，更不能当作 GPU 时间。

16:26–16:29 的[后续只读观察](validation/background-observation-1.jsonl)见到 CodexBar 从 0% 再升至约 100%；该观察也覆盖本线程检查和其他编译活动，**不是静默基线或性能试验**。短暂低负载不足以说明污染源已消失，因此没有启动 run-6。

## 保留的条件与测量边界

生产基线为已集成 Overview、Runtime 和子标签修复的 `e7afacc212aec9b30c280440b1c6ac48ea21fc4b`。工具提交为 `9eb0bfff8`、`b8b2bc5c0`、`22656ba95`；不含生产行为修改。所有本轮 bundle 都由干净 tracked 源码构建，具体源码／可执行文件 SHA、链接参数和环境在原始 `build.json` 中。

- MacBookPro18,3，Apple M1 Pro，10 核，16 GiB；macOS 26.5.1 (25F80)，Swift 6.3.2；Release `-O -enable-testing`；本轮为 AC 供电。
- 同一进程、同一套 5 张生产卡片与 Moku Dock；1200×760 pt，2× backing。系统 Reduce Motion / Transparency 均 false。名义 120 Hz 只描述显示模式。
- 计划明／暗 × 静止／平移缩放 × on/off × 4 次，邻接材质顺序 AB/BA/AB/BA，外观与场景在偶数轮反转。两种材质初始各预热 4 秒；每段 2 秒稳定、4 秒场景预热、相机复位、250 ms 稳定、12 秒正式采集。运动段有固定 720 次生产相机更新。
- 全部 32 段、16 对及预热、挂载／布局／相机等价、原生 recorder 健康、完整结束都必须通过。主机 busy ≤40%、热压力低于 serious、唤醒延迟等原门槛不变。低 CPU 的其他回放也会被监控识别。
- 当前只取得进程 CPU、任务记账内存、全机 CPU 和 MainActor 定时唤醒延迟。没有可归因的 GPU 时间、真实渲染帧耗时／FPS、呈现卡顿或能耗。
- fixture 固定 Cloud/Moku 自主动画以隔离 Thread 外壳材质，内层玻璃及完整控件保留，运动走生产相机路径；它不代表整个动态应用、真实手势识别、大量卡片或冷启动。未通过关闭生产动画实现优化。旧无窗口仪器探测未取得可用 trace；本机模板存在不代表指标已测得。

## 工具与回归验证

`make check ARGS=` 通过；保留真实失败数据及缺失／重复／顺序／动作不等／原生失败变体的分析回放通过。监控另用自有无 GUI 休眠进程验证低于 5% CPU 的回放身份不会被过滤。生产输入、明暗 × glass on/off 的四张截图与独立像素检查、6 项挂载回放通过。固定 Release bundle 构建通过，run-5 实际验证前台门控、计数采集和首次污染停止。

[验证日志及哈希](validation/sha256.json)和[历史像素检查结果](validation/capture-inspection.json)保留在源码中。四组历史截图的 8.85 MiB 归档已移至私有备份，不随源码发布；它不是构建、测试或重新采集所需的输入。manifest 保留私有归档及其成员的历史哈希，不把它们作为新采集结果的预期哈希。

从仓库根目录可用当前生产 fixture 重新生成明／暗 × glass on/off 四张截图及像素检查结果（需要 macOS 图形会话和屏幕录制权限）：

```sh
python3 tools/verification/overview-input/run.py --glass-world .build/glass-world
```

新工具尚未取得全 32 段成功路径的实际验证；不能用负例回放代替它。

## 接续条件与归档

需要父协调为 `a58dea80-1682-48a1-b022-6468028d5534`、`4bbc7bb0-2d47-4d0f-a520-b64eae13306b` 及其他开发线程安排约 15 分钟无编译／GUI／截图的时段，并使已观测到的后台任务进入持续低负载。跨线程消息 API 不可用，已通过父协调可见 commentary 提供时段和释放事实，未收到独立 ACK，不能声称获得强独占。

只要求编译静默、鼠标静止仍不足以消除 run-5 的后台负载。未暂停／终止日常 CodexBar、Mokusei、Runtime 或系统进程。用户／会话活动出现时停止自己的试验，不强制保持前台；没有环境改变时不重跑。

已准备但**尚未启动**的 `22656ba95` bundle 和执行命令入口见 [status.json](status.json)。若工具源码、可执行文件或签名发生变化，驱动会拒绝使用；先重新准备，再进入新静默时段。真正完成后应以新目录保留完整 32 段原始数据，严格分析通过后再报告同构建 on/off 的配对统计。

- [run-4 原始数据](run-4-raw.tar.gz)、[run-5 原始数据](run-5-raw.tar.gz)，脱敏后各成员的 SHA-256 记录在 manifest。
- [run-3 原始归档](../../../overview-performance/evidence/glass-run-3/raw.tar.gz) 的测量内容保持不变，路径及归档所有者已脱敏；当前归档 SHA-256 `6811b5839b8c41fdf69158098383783a3102917b3ad6c3bb3436e5464b9a40a2`。
- 原 glass-world-performance 树中的 `glass-performance-20261025-130015-INCOMPLETE.tar.gz` 保持不变，SHA-256 `23afeeb2d0702fc0db45a87b6bb40d8092d414ca361764fe0fed75aa18047513`；未用于性能结论。

独立 detached worktree 交付工具和证据给父协调审查；没有修改 main／其他树，没有 push 或 deploy。
