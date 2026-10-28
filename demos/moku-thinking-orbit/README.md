# Moku thinking 原生历史对照

这是 Moku thinking 的独立 native demo，默认复用正式“胶囊 + Arc”实现，另保留两个历史版本对照。
正式 Dock 接收当前公开 Harness reasoning；本 demo 的文字全部来自内存 fixture。

```sh
python3 demos/moku-thinking-orbit/build.py
open .build/moku-thinking-orbit/MokuThinkingDemo.app
# 验证并截图后退出；检查 evidence/result.json 的 ok，而非 open 的退出码。
open -W -n .build/moku-thinking-orbit/MokuThinkingDemo.app --args --verify
# 保留已打开的预览时，构建独立副本，不覆盖正在运行的 app：
python3 demos/moku-thinking-orbit/build.py --skip-build \
  --output .build/moku-thinking-orbit-check/MokuThinkingDemo.app
```

需要 macOS 26 / Xcode 26。构建脚本复用 native replay 的模块、对象和资源打包，
链接当前生产 `MokuseiUI`，产物位于 `.build/moku-thinking-orbit/`。
已完成当前源码的 Swift build 后可加 `--skip-build`。源码不依赖历史仓库仍在磁盘上。
构建和回放串行运行。demo 不安装生产应用、不启动 Runtime、不打开真实用户 profile 或模型账户。

## 胶囊 + Arc 提案

保留当前生产胶囊和眨眼，文字使用以胶囊中心为圆心的 **288° 开口圆弧**，中心角 −110°。
半径为胶囊半宽加 19pt（168×44 胶囊对应 103pt），避免文字碰到胶囊侧边。
字形沿圆弧切线旋转，使用 Electron 的 glide FIFO：追加平滑推进，输入停止后读完并停在尾部。
没有使用后续 native contour 的永久旋转 phase。短文本按实际宽度在弧中央对齐。
正式表情组件负责 Arc、眼睛、运行彩点和可反向的交接，demo 不另建 Arc 时钟或绘制副本。
真实 Dock 在底部空间不足时整体平滑抬升，极小视口按组合尺寸缩放，避免字形裁切。
眼睛使用当前生产眨眼，完整的历史扫读与身体跟随留在圆形对照页。

## 两种历史对照

**Electron · 原始阅读** 是对圆形角色的原生还原，整个 400×310 study
等比例放大 1.5 倍方便观察，字形、身体和眼睛一起缩放：

- 原始弧长 200% = 288°，中心角 −110°（左倾 20°），半径 90，字体 10，字距 1.3。
- 短文本按实际宽度居中；保留沿切线的字形方向，包括底部倒置。
- 已确认的 glide FIFO 按源位置接收输入，最多同时测量 112 个字素，显示尾部上限 56 码点且不拆字素。
  新输入推动旧字退出；暂停流入后继续读完队列，最终停在尾部，不无限绕圈。
- 放大 10% 的眼睛按可见文字范围扫读，带停顿、落点修正、偶尔回瞟；身体延迟约 110ms 跟随。
  文字只跟随身体平移，不继承身体旋转或形变。增量不打断当前阅读句，下一句才更新范围。
- Running、Thinking、工具和空闲之间使用历史 550ms 交接，能观察彩点展开成文字、文字收拢为工具标记。

**Native · 胶囊环流** 是后来针对胶囊有意改编的版本：

- 胶囊、眨眼、Running 三点、输入框及取消按钮均来自当前生产 `NativeMokuDock`。
- 恢复历史 CoreText 文字 overlay：基线在胶囊外 19pt，12.5pt medium，26pt/s 连续等弧长行进，
  34pt 安静接缝，soft 360ms 字素淡入、22pt 两端渐隐。保留底部倒置。
- 同段追加保留阅读时钟；替换段落重置 reader。打开输入或工具接管时让位，结束时清空并停表。
- 这版只有生产胶囊的眨眼，没有把圆形角色的身体形变和大范围扫读套到细长胶囊上。

“暂停流入”只停止 fixture 新输入，已有 FIFO 继续消费；“暂停动画”冻结视觉时间和输入。
“短文本”检查居中；“新段落”用自定义文字检查 reader 重置。“深色”在同一窗口切换。
系统 Reduce Motion 冻结 demo 的运动；原生窗口隐藏或最小化时停止各自的动画计时器。

## Git 依据

设计来自原 OpenAgent/Bart 仓库的 Git 历史，最后 Electron 快照为
`89c56123261487325d15a30c88e0501a9142b2e1`：

| 提交 | 设计决定 |
| --- | --- |
| `18e1f5709` | 锁定 200%、左倾 20°、glide；自然扫读与身体跟随 |
| `ff382241c` | 源位置 FIFO、完整字素、有界测量缓冲，避免跳过中间输入 |
| `44c759408` | 共享 550ms 角色交接，文字/彩点/工具标记连续迁移 |
| `c42042268` | 专属动作接管时保留 resident 和逻辑时钟 |
| `d495018c9` | 胶囊外轮廓的原生 26pt/s 环流改编 |
| `310149f1d` | SwiftUI 迁移将 contour 替换为底部普通 Text |
| `b714d812b` | 删除 reasoning 角色和文字投影 |

`History/` 从完整的原生 contour 基准 `b478a1f0e540b732bc6c11ae4af082d89cd58833`
恢复（即 `310149f1d^`），不能使用紧接删除前已经退化为普通 Text 的版本。
原路径为 `apps/macos/Sources/OpenAgentUI/Bart/` 的 Resident、ReadingTrack、ReasoningContent，
以及 `BartScene/NativeBartCapsuleReasoning.swift`。Electron 设计说明位于
`apps/desktop/labs/bart/README.md`，对应 `bart-motion/reasoning-*`、`resident-*` 实现。

恢复时对类名和 import 做隔离，复用当前生产角色几何、材质和 Running 编排；
补回 Electron 已有的逐句 cycle 变化（旧 Swift 移植固定 cycle=0），胶囊 Canvas 增加 demo 暂停输入。
正式 Arc 已提取到 `MokuseiUI`，主页面直接传入生产 Dock 的 reasoning fixture。
`History/ThinkingCapsuleReasoning.swift` 仅保留旧 contour 比较，圆形角色的历史 FIFO 也只供该参考页使用。
原生显示生命周期由 demo 外壳管理。历史代码独立保留，便于后续评审后选择接入方式。

## 验证边界

`--verify` 挂载真实 native 组件、使用自己的 WindowServer 窗口截图：
检查可见文字和自然变化的像素、流式追加时钟连续性、暂停/恢复、输入与工具让位、结束清理、
隐藏/恢复，并保存三种版本的浅深色截图；Arc 还检查短文本停止推进及追加时钟连续性。
程序最小化只有在 AppKit 确实执行时才计入，通过不了该动作时明确记为 skip，再验证真实 hide/show。
它不手工调用 draw 或快进动画时钟。
验证结果与 PNG 位于 app 同级 `evidence/`。公开 reasoning 链路另由
[生产回放](../../tools/verification/moku-reasoning/README.md) 验证。
合并 demo 源码前还需运行 `make check`；完整结果以本次运行日志为准。
