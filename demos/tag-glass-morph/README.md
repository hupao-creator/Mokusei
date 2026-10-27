# Tag Glass Morph 原生预览

这是接入 Overview tag filter 前的独立参数实验，保留用于复查当时的设计选择；当前正式标签已使用 morph，验收请使用 [生产组件回放](../tag-filter-morph/README.md)。本目录不代表当前产品行为。无需启动 Mokusei，也不需要项目的 Release 依赖；所有演示数据都来自本目录。

## 打开

需要 **macOS 26+、Xcode 26+**（包含 macOS 26 SDK 和 Swift 6）。在仓库根目录运行：

```sh
python3 demos/tag-glass-morph/build.py
open .build/tag-glass-morph/TagGlassMorphDemo.app
```

构建脚本使用当前机器架构，Swift 6、warnings-as-errors，并给本地 app 添加 ad-hoc 签名。不会安装或替换正式应用。

也保留了 `TagGlassMorphDemo.swift` 末尾的 `#Preview`。它不属于生产 Swift package target；如需 Xcode Canvas，可在一个 macOS 26 SwiftUI 临时项目中添加该文件并打开 Canvas。当前仓库中直接预览方式是上面的独立 `.app`。

## 查看顺序

1. 点击“播放完整演示”：循环展示 `2 → 3 → 4 → 2 → 6 → 0 → 2`，观察新标签从相邻玻璃分离、删除时回收，以及剩余标签的位置变化。
2. 勾选“慢速”：动画从 0.48 秒变为 1.6 秒；关闭“启用动画”可对照原本的即时变化。
3. “增加一个”补回第一个缺失标签，保持固定顺序；点击任一标签后，“删除选中 / 末尾”可以删除中间项。删除当前选中项会回到“全部”。
4. “批量 2 ⇄ 6”与“清空”覆盖大幅数量变化；“全部”作为持续存在的玻璃锚点。横向滚动可查看长目录；计数按钮覆盖一位到三位数字的宽度变化。
5. 切换深浅外观，或使用局部无障碍模拟开关。模拟开关不会修改系统设置；系统已经开启的降低透明度仍优先。动画仅由手动“启用动画”控制。

任意手动数据操作会停止自动播放。停止或关闭窗口会移除播放计时器订阅。

## 原生机制与实验参数

两行各自使用一个 `GlassEffectContainer`、独立 `@Namespace`、稳定的 tag ID、`.glassEffectID`、显式 `.glassEffectTransition(.matchedGeometry)` 和 `withAnimation`。没有自绘液体、普通 `matchedGeometryEffect` 替身或随机 identity。

- 放大观察行：48 pt 高度，regular glass，标签间距和 container spacing 均为 16 pt。
- 紧凑行：32 pt 高度、12 pt 水平内边距、4 pt 标签间距、180 pt 最大宽度和 clear glass，接近当前 Overview；这里使用系统字体，未依赖项目字体与目录图标资源。
- **紧凑行的 container spacing 为实验性的 4 pt。** “全部”也包含在实验 container 内，确保清空到零时仍有邻近玻璃可参与变化。正式组件的参数与行为以其源码为准。
- container 位于滚动视口内，避免捕获的文字越过裁切边界。背景是普通着色内容，未嵌套玻璃采样层；不包含正式云图、工具栏入场和 behind-window 桌面采样。
- 由系统选择匹配的邻近形状。多项同时增删时，具体吸收对象由 SwiftUI 决定；本 demo 不承诺固定配对。
- 降低透明度时改用不透明 capsule 和 identity glass。

Apple 官方资料：

- [用户指定的 morph 视频](https://developer.apple.com/tutorials/videos/com.apple.SwiftUI/liquid-glass-morph-views~dark.mp4)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)
- [glassEffectTransition](https://developer.apple.com/documentation/swiftui/view/glasseffecttransition(_:))

官方机制指出：container spacing 越大，形状越早融合；超过静止标签间距会造成静止状态也相连，因此本 demo 未把融合距离放大到高于标签间距。


正式标签行为见 [Overview 模块](../../app/macos/Sources/Host/Overview/README.md)。本目录是独立参数实验，不作为产品行为或验收结果的依据。
