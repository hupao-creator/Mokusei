# Moku 渐变玻璃 · 原生材质提案

独立 macOS 26+ / Xcode 26+ SwiftUI demo，用于评审参考图中的「上深下透、暖灰渐变、细亮边」。两款渐变已接入正式 Moku；此独立预览不连接 Runtime，不读取会话或启动麦克风。需求记录：[Demo #83](https://github.com/hupao-creator/Mokusei/issues/83)、[正式接入 #84](https://github.com/hupao-creator/Mokusei/issues/84)。

## 打开

```sh
python3 demos/moku-gradient-material/build.py
open .build/moku-gradient-material/MokuGradientMaterialDemo.app
```

产物只保留在本工作树 `.build` 中；不会替换已安装应用。关闭唯一窗口会退出 demo。

## 查看

- 默认左侧是暖黑到透明的深色渐变，右侧是乳白到透明的浅色渐变；两者都以 clear glass 为底，各自使用深/浅局部外观和相应文字颜色。上下分别展示展开面板与生产尺寸的 168×44 pt 胶囊。
- 默认强度 85%。强度控制渐变和附加亮边；0% 保留 clear glass，**不是** regular glass。强度低于 50% 时根据背景选择文字颜色；正常强度下深色材质用亮字、浅色材质用深色字。
- 切换暖沙、浅色、深色背景，用「移动背景」观察原生玻璃采样。背景是本地 SwiftUI 曲面图形，不是参考截图。
- 「展示」可切换深浅对比、单独深色、单独浅色或历史 regular glass 原材质；「收起 / 展开面板」检查大小变化。两侧共享可编辑的演示文字，收起后保留文字。
- 「恢复推荐」还原材质和展示参数，保留输入文字。「降低透明度预览」只作用于 demo，系统降低透明度设置始终优先；系统 Reduce Motion 禁用展开动画。

## 复用与实验边界

构建直接编译未修改的生产 `MokuGeometry`、`NativeMokuCapsuleLayout`、`NativeMokuCapsuleEyes` 和 `NativeMokuCapsuleGlass` 源码。仅把原有 `NativePlatform.swift` 编译成最小平台桥接模块，避免为了看材质而链接 Runtime、Markdown 或 WebRTC。

提案使用系统 `.glassEffect(.clear)` 提供背景采样和折射，再把暖黑或乳白至透明的渐变和底部细亮边叠于玻璃之上、文字之下。深浅方案共用相同渐变停靠位置与强度；降低透明度时分别使用暖黑和乳白实色。没有复制 Siri 私有实现，也不代表 Apple 官方材质。参考：[Apple Glass API](https://developer.apple.com/documentation/swiftui/glass)。

展开面板是独立内容 fixture：原生可编辑 TextField、装饰性附件/波形符号、收起按钮；不是生产 composer 或完整 Dock 的行为回放。生产几何、眼睛和当前渐变材质直接复用；历史 regular glass 对照只保留在 demo 中，不能将此 demo 当作真实 Dock 的焦点、语音或动画验收。生产回放见 [MokuScene](../../app/macos/Sources/Host/MokuScene/README.md)。

## 验证

构建使用 Swift 6、warnings-as-errors 和 ad-hoc codesign。新增演示的集成检查应实际启动此 app，操作三种背景、强度 0% / 100%、移动背景、四种展示模式、输入编辑、收起再展开、深浅实色回退和恢复推荐，并检查文字和边缘无裁切。仓库代码检查仍运行 `make check`。
