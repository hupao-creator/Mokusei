# Overview 卡片 Liquid Glass 研究

本工具只在 `.build/overview-glass` 复制的 Swift package 中注入研究开关，
不修改产品源码、偏好、Runtime 或用户数据。源码不匹配时拒绝补丁。
复用生产 Canvas、Harness/Report 卡片、Chrome、Dock 及现有测量器，
不是自绘矩形的合成微基准，也不是完整应用端到端性能测试。

```sh
python3 tools/verification/overview-glass/run.py build
# 修改研究脚本后复用自己的编译缓存；重新生成并签名 fixture：
python3 tools/verification/overview-glass/run.py rebuild
# 新目录；每个计数分别启动一个私有 fixture。先完成所有编译再测量。
python3 tools/verification/overview-glass/run.py measure --count 5 --stage baseline --output /private/tmp/glass-five-baseline
python3 tools/verification/overview-glass/analyze.py /private/tmp/glass-five-baseline
```

`--count` 可选 1、5、12、30；默认窗口 1800×1000pt，必须真实屏幕能容纳。
先以五卡运行 `baseline`：静止和固定比例的纯平移，各做六轮三条件配对，
三条件的六种顺序各出现一次。只有取得有效基线后，才用 `--stage extended --count 5`
分开测缩放和 10Hz 单卡内容更新；再对 12/30 卡运行 baseline，自然溢出。
每段 2s 稳定、4s 预热、12s 测量，仅浅色。卡片沿用五种生产内容循环，
卡片数增加同时增加采样面积；不能据此拟合固定像素面积下的单卡成本。
所有卡片必须成功布局/挂载；1/5 张需完整放入窗口，12/30 张保留生产相机的可读比例和自然溢出，
记录窗口内完整/相交的几何卡片数。不绕过布局或用不可读缩放来强行塞满窗口。
相机只做小幅往返，未覆盖横跨全部大集合的长距离滚动。

三条件为 `all-on`、`shell-off`、`all-off`。`shell-off` 只切换现有 `glassWorld` 外壳，
内部仍使用玻璃；`all-off` 还将徽标/Follow-up 和 plan 的 glass
设为 Apple `Glass.identity`，并填入普通 surface。
终态小徽标的 `ultraThinMaterial` 是经典 SwiftUI Material，两边保留相同实现；
它不属于 Liquid Glass，不把“没有 Liquid Glass”偷换成“没有任何 blur”。空 GlassEffectContainer
与 glassEffectID 保留，以维持结构身份；它们没有有效 glass shape。
Chrome、Dock 的 glass、内容、布局和动作序列保持相同。Harness 卡片注入对应生产
`threadCardCloudPalette`；running Cloud 存在，但其自主动画在所有条件等量暂停。
不透明替代面同时改变遮挡和合成，差值是该替代实现的整体收益，不能单独归因于 shader。

只测进程 CPU（100%=一个逻辑核）、resident/physical footprint 和 MainActor
定时唤醒延迟。记录实际相机 API 调用、追赶次数和调用吞吐；这些都不是呈现帧/FPS。
不声称测得 GPU、WindowServer 内存或能耗。刷新直接驱动生产 Canvas 的单卡
presentationID 与文本输入，并记录最终 revision 是否到达 onChange 观察点。
观察失败也作为结果保留；观察成功不证明每次刷新均已显示。
绕过 Runtime/网络/Overview catalog projection；这测的是内容更新的原生呈现路径。
Dock 自主动画也在所有条件等量暂停，保留相同生产控件。

测量沿用现有输入空闲、编译干扰、失焦停止策略；
启动前要求至少 120s 无会话输入，并连续 30s 无编译/回放干扰（最多观察 180s）。
不停止外部进程，不恢复焦点，不请求屏幕录制/辅助功能权限。
主机 busy >40%、唤醒迟到 >250ms 和热状态为**被测结果**，原样保留。
分析器用已知竞争进程、自身 CPU 足以解释全机 busy、无法归因三档标注；
不会因被测过载而删去样本或重跑到过关。只有明确的外源干扰、失焦、输入等
协议破坏会使配对失效。没有获得稳定图形会话时，失败记录属于环境证据。
构建目录保留注入后的源码、补丁 diff、各输入 SHA 和 Release 构建信息。
报告与实际执行记录见 [REPORT.md](REPORT.md)。

只读环境预检（不显示窗口、不触发权限申请）：

```sh
mkdir -p .build/overview-glass-preflight
xcrun swiftc -module-cache-path .build/overview-glass-preflight/ModuleCache \
  tools/verification/overview-glass/environment.swift -o .build/overview-glass-preflight/environment
.build/overview-glass-preflight/environment
xcrun xctrace list templates
/usr/sbin/DevToolsSecurity -status
```

沙箱内可能得到空屏幕、空会话和不完整的模板清单；这只能说明沙箱视野，
应与有授权的宿主预检区分，不能直接判定机器没有图形环境。

无窗口几何检查，使用同一份生产布局/相机及卡片 plan composition；不测 glass 或 GPU：

```sh
python3 tools/verification/overview-glass/geometry.py
# .build/overview-glass/geometry.json 与 geometry-build.json 保留结果/链接来源
```
