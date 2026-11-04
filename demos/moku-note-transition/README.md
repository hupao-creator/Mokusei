# Moku Note 收起 · 生产组件视觉预览

直接链接当前工作树 Release 生产模块，挂载 `NativeMokuDock`。只有背景卡片、Note 文本、草稿和状态切换是 fixture；没有复制 Note、玻璃、眼睛或动画实现。它是视觉预览，不包含断言、不运行测试或 Runtime，也不访问用户 profile、剪贴板或麦克风。

预览通过生产 `NativeMokuScene` 驱动可见性生命周期。直接单独挂载 Dock 会保持
`windowVisible == false`，只能展示隐藏窗口的立即收敛分支，不能验收动画或 Talk。

```sh
xcrun swift build --package-path app/macos --configuration release --product Mokusei -Xswiftc -warnings-as-errors
python3 demos/moku-note-transition/build.py --label candidate
mkdir -p /private/tmp/moku-note-transition-candidate
ditto .build/note-dismiss/candidate/MokuNoteTransitionPreview.app /private/tmp/MokuNoteTransitionPreview.app
open -W -n /private/tmp/MokuNoteTransitionPreview.app --args /private/tmp/moku-note-transition-candidate
```

输出目录必须是新的空目录。约 15 秒后预览自动关闭，输出该进程窗口的 `note-transitions.mp4`、状态事件/合成文本/草稿的 `observations.json`，以及当前窗口完整范围的尺寸场景 PNG。窗口是非激活 Panel；不会替换、重启或操作已安装应用。录制使用 ScreenCaptureKit 的 `currentProcess`，不捕获其他应用窗口或声音。`build.json` 在 app 同级目录记录源码、预览、二进制 SHA-256 及生产 diff；编译生产模块后再链接，期间不要修改生产源码。`--label baseline` 可保留修复前二进制供同 fixture 对照。

顺序：长笔记开关 → 120ms/90ms 内快速反向 → 短笔记 → 窄窗口及打开时改尺寸 → landing 居中布局 → 5× 缩放 → 局部禁动画 fixture。大小由生产几何计算，笔记通过生产 Markdown 渲染；禁动画 fixture 用 transaction 展示无动画结果，不改系统设置；macOS 的 `accessibilityReduceMotion` 是只读环境，因此真实 Reduce Motion 分支另行源代码审查，不能把此 fixture 说成系统偏好实测。窗口 resize 和缩放 fixture 不代表完整产品的缩放/窗口生命周期。

## 原始问题与根因

已读取用户提供的 2026-11-03 13:16:43 录屏（5.585 秒，3088×2094，约 52fps），按 250ms 全段抽帧，再以 25ms 检查 1.350–1.675 秒的收起段。画面是 Overview 中带标题、正文、日期及底部眼睛/历史入口的 Note。1.375 秒起正文淡出时，尚未收完的面板变浅，左上出现最终尺寸的小黑胶囊，眼睛仍在下方；随后黑胶囊向最终位置移动，约 1.675 秒合拢。第二次收起（约 3.5 秒）可见同类分离。这是 Note 的背景转场缺陷。

`NativeMokuCapsuleGlass` 已保留单一 glass 节点，但原先在退出 Regular 材质时才插入 `if !regular` 下的渐变和描边。这两个新子视图没有旧的大面板布局可插值，从最终 168×44 尺寸出现在仍在收缩的玻璃左上方；原 Regular 玻璃同时变透明，形成与底部眼睛分离的灰色残影。修复让两个装饰层始终挂载，仅改变透明度，与玻璃共用现有尺寸、位置及 420ms 动画。Note 内容的 120ms 淡出、底部锚点及单玻璃材质节点保留。没有延迟回调、第二个壳或新的 Note 数据状态。

## 本轮观察与范围

本轮为 sprint mode：不新增或运行测试、CI、测试 hooks，不推送或创建 PR。已完成本地 diff 自审、生产构建和真实 WindowServer 画面检查。

- **生产构建**：当前工作树 Go Runtime `go build -trimpath` 成功；Swift 6 Release `Mokusei` 产品加 `-warnings-as-errors` 成功（最终生产源码构建 113.04 秒）。没有编译测试 target，也没有运行测试。最终 Swift 源码 fingerprint 为 `543f6d4fb57b203b7ea207e56897d3da2463ba080e2d9d1ffa503525056d7afb`。
- **收起对照**：[相同生产 fixture 的真实连续帧采样](evidence/close-comparison.png)。上排复现原始录屏的左上黑胶囊/浅灰壳分离，下排已消除。标签为各自视频时间，未归一化动画进度，不作帧率或延迟比较。完整录屏保留在本地 `/private/tmp/moku-note-dismiss-{baseline,candidate,layout}-20261103/`，原始用户录屏及内容未复制进提交。
- **打开与快速往返**：已查看打开及 120ms/90ms 内反向的录制帧，后续展开、收回保持同一外壳，未见装饰层脱离或旧完成回调拉回。第一次冷挂载在非激活预览中出现较晚的可见首帧，因此不把此观察当作冷启动延迟、真实活跃应用的逐帧流畅度或 GPU 性能认证。
- **位置与尺寸**：[360×380 窗口](evidence/narrow-open.png)、[打开时改为 440×300](evidence/resized-open.png)、[landing 居中](evidence/landing-open.png)、[5× 缩放](evidence/zoom-open.png) 均通过重新取得当前窗口范围截图核对。外壳、眼睛和历史入口留在 viewport 内；窄窗口正文换行并保留滚动区域。5× 仅核对壳体边界及控制席位，极短正文 viewport 的滚动可用性未做交互验证。
- **内容与生命周期自审**：生产改动仅保留渐变/描边身份并改透明度，未改 Note 文本、存储、revision、曝光提交、Markdown、草稿、打开/关闭入口或普通 Agent Thread 输入动画。原有单 glass 节点、Reduce Transparency 实色分支和 Reduce Motion 的 nil animation 路径保留；没有新增动画计时器、完成回调、用户数据写入或延迟卸载。合成草稿在所有开关后仍为原值，预览没有切换前台应用。
- **其他检查**：Python 语法、diff 空白及改动文档的本地链接已检查。构建/预览起初遭遇沙箱解码 `-12911`、宏插件限制和 LaunchServices `-10827`，在允许的只读解码/本任务编译与启动范围内解决；SwiftPM 使用锁定版本的本地依赖缓存。首次预览编译还暴露只读 Reduce Motion 环境，已改为明确标注的 transaction fixture。窗口 resize 后连续录制保留旧画幅的裁切通过当前窗口完整截图补足，未把裁切帧算作边界适配通过。

[原始观察、源码/二进制/录屏 SHA-256 和生产 diff](evidence/observations.json) 保留基线、修复后相同 fixture 及补拍版本。补拍只增加截图采集，生产源码与修复后版本完全相同。

**未验证**：真实用户 profile 和笔记、真实 Harness/语音/权限流程、物理触控板手感、系统 Reduce Motion/Transparency 偏好实时切换、5× 正文滚动/选择、完整应用窗口/缩放生命周期、签名生产 bundle 启动、帧率和 GPU 开销。禁动画 transaction 只是视觉对照，不能替代真实系统 Reduce Motion 分支实测。测试、测试 hooks 和 CI 均未运行，不以历史结果认证本提交。
