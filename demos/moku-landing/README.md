# Moku landing 原生 demo

[Spec #66](https://github.com/hupao-creator/Mokusei/issues/66) 的原生视觉回放与交互预览。
复用生产 `NativeMokuScene`、`NativeMokuDock`、原生 composer、Overview Canvas、
Chrome、Harness 卡片和 SwiftUI 窗口材质。中心态为 680 × 76pt，正文 16pt / 行高24pt；
窄窗口保留24pt横向边距。普通 Dock 的168 × 44pt位置及展开尺寸保持现有值。
没有文字、附件或目录时，发送按钮及背景完全隐藏；保留空布局占位避免输入区跳动。
输入光标为2.6pt圆头短光芯，上暖黄、下冷蓝光晕，以2.4秒周期平滑呼吸。
深色使用白色光芯（20–100%亮度），浅色保留原生深色文字颜色（80–100%亮度），避免最暗时丢失对比度。
同一行保留120ms平滑移动，连续输入从当前呈现位置接续。
输入法组合使用原生光标，换行保持即时定位。系统减少动态效果关闭位移与呼吸动画，光标保持常亮。

```sh
python3 demos/moku-landing/build.py --verify --open
```

构建完成后，独立 app 的路径记录在 `.build/moku-landing/app-path.txt`，
回放结果、几何测量和当前进程窗口截图保存在 `.build/moku-landing/evidence/`。
`caret-motion.json` 记录真实原生输入触发的光标起点、中间点和落点。
`caret-contrast.json` 记录当前窗口像素中的光标对比度与实际宽度，包含浅色最暗阶段（至少3:1）；
`caret-breathing.json` 记录跨越完整周期的真实呈现层亮度采样；
`01c-breathing-caret-closeup.png` 及 `08-narrow-dark-closeup.png` 用于检查浅深色光标亮态与光晕。
截图要求窗口内容完整覆盖画面，系统收起窗口的缩略过渡不能作为通过依据。
已完成 Swift build 时可以追加 `--skip-build`。app 和其私有工作目录保留在
临时目录，便于重新打开审阅；不替换已安装的 Mokusei。

主窗口可以直接输入，Return 发送，Command-Return / Shift-Return 换行，
输入 `@` 可选择 fixture 目录。发送默认等待1.3秒后模拟任务创建成功。
顶部「演示」菜单提供：

- Command-D：打开独立演示控制窗口。
- Command-1：重置为空工作区。
- Command-2：演示首次成功派发和回到底部。
- Command-3：演示创建前失败并保留草稿。
- Command-4：归档全部会话并重新居中。

控制窗口还可以选择保持派发中、添加示例附件和目录、筛选无结果、对照原来的空页面，
以及切换浅深色和宽窄窗口。右上角设置按钮在该 demo 中打开演示控制窗口。
这些控制不属于产品 UI。

`--verify` 通过本进程窗口的真实原生编辑器输入文字并派送 Return，检查居中尺寸、
pending 保持位置、失败保留草稿、成功回到精确底部坐标、筛空不迁移、
归档后居中、附件/目录及480pt窄窗口。截图只枚举和捕获当前进程窗口，
不读取桌面或其他应用。
回放也检查初始空输入、清空到空格时没有发送按钮，输入文字或只添加附件后恢复按钮，
以及原生光标动画确实经过中间位置并落到目标位置，减少动态效果时不再位移动画。
同一个输入框还验证中文组合输入使用原生光标、提交后文字完整保留、
选中文字时没有额外插入点，以及失焦时动画层立即退场。

任务集合及派发结果由内存 fixture 提供；派发相位使用生产 `NativeMokuDispatch`
解读。附件采用生产导入/展示流程，模拟暂存服务只返回元数据。
本 demo 不连接 Runtime、模型、麦克风或用户 profile。
创建前失败通过提交回调返回错误来演示草稿保留，不证明真实 Runtime 接受输入之后的
异步派发失败、历史通知、权限交互或语音生命周期。

正式工作区与此预览共用 Dock、composer 和光标实现。这里的控制面板仍以模拟状态
演示视觉，不代替全局 catalog、派发时序和导航接入验证。运行
`python3 tools/verification/reading-presentation/run.py --moku-landing`
验证实际工作区和已安装 catalog 的绑定；详见
[生产 landing 回放](../../tools/verification/reading-presentation/README.md#empty-workspace-and-first-dispatch)。
