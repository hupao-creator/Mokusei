# Settings 面板原生 demo

直接链接当前 checkout 的生产 `NativeMokuScene`、`NativeMokuDock` 和
`NativeSettingsPage`，以 fixture 配置展示 Overview 内的设置面板。
面板复用 Dock 的容器，展开时采用居中的不透明原生窗口背景（无 tint、无 Liquid Glass；780 点宽、默认 900 点高，随内容增高并受视口约束），背景模糊且不可操作，右上角关闭按钮走现有 draft gate。
顶部 tab、共享 onboarding 配置交互和表单直接使用生产实现；主窗口只保留自己的原生窗口按钮。

```sh
swift build --package-path app/macos
python3 demos/settings-navigation/build.py
.build/settings-navigation/SettingsNavigationDemo.app/Contents/MacOS/SettingsNavigationDemo
```

预览支持交互，不配置自动断言或截图验收。

数据和保存使用内存 fixture；偏好写入 demo 私有 profile。
不启动 Runtime、模型服务或麦克风。Harness 子表单为空，不代表其功能已验证。
需要 macOS 26 / Xcode 26；不安装或重启 Dev 应用。

交互预览可直接打开生产版 Moku Map。切换协调 Agent 可以查看带眼睛角色的换乘和注视动画。

```sh
swift build --package-path app/macos
python3 demos/settings-navigation/build.py --moku-map
.build/settings-moku-map-logo/MokuMapLogoDemo.app/Contents/MacOS/MokuMapLogoDemo
```
