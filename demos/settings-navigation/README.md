# Settings 面板原生 demo

直接链接当前 checkout 的生产 `NativeMokuScene`、`NativeMokuDock` 和
`NativeSettingsPage`，以 fixture 配置展示 Overview 内的设置面板。
面板复用 Dock 的容器，展开时采用居中的原色 glass 表面（780 点宽、默认 900 点高，随内容增高并受视口约束），背景模糊且不可操作，右上角关闭按钮走现有 draft gate。
顶部 tab、共享 onboarding 配置交互和表单直接使用生产实现；主窗口只保留自己的原生窗口按钮。

```sh
swift build --package-path app/macos
python3 demos/settings-navigation/build.py
.build/settings-navigation/SettingsNavigationDemo.app/Contents/MacOS/SettingsNavigationDemo
# 保持可交互时追加 --interactive
```

结果写入 `.build/settings-navigation/result.txt`，截图写入其 `screenshots/`。
覆盖浅色、深色、紧凑、窄窗口英文及多级缩放；验证关闭目标留在视口内、
IME 阻止关闭、分类键盘导航，以及无效分类回退 General。
设置面板恒定深色，因此浅色窗口截图同时验证“浅色工作区中的深色设置页”。
截图使用 ScreenCaptureKit，仅捕获 fixture 窗口。
完整面板生命周期和背景点击验收见
[Settings 回放](../../tools/verification/reading-presentation/README.md#settings-capsule-and-return)。
另存四个 Harness 的 Moku 页浅色、深色及单目标截图，验证透明图标座位、
派发短横线和虚线路径，以及生产协调/派发绑定和最后目标保护。
“模型选择偏好”开关直接可见，启用后另存常规、紧凑中文及紧凑英文截图，并验证编辑器保留独立无障碍名称。

数据和保存使用内存 fixture；偏好写入 demo 私有 profile。
不启动 Runtime、模型服务或麦克风。Harness 子表单为空，不代表其功能已验证。
需要 macOS 26 / Xcode 26；不安装或重启 Dev 应用。

交互预览可直接打开生产版 Moku Map。切换协调 Agent 可以查看各 Harness 的玻璃圆标。

```sh
swift build --package-path app/macos
python3 demos/settings-navigation/build.py --moku-map
.build/settings-moku-map-logo/MokuMapLogoDemo.app/Contents/MacOS/MokuMapLogoDemo
```
