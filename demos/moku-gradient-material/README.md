# Moku 渐变玻璃 · 原生材质提案

独立 macOS 26+ / Xcode 26+ SwiftUI demo，用于评审参考图中的「上深下透、暖灰渐变、细亮边」。不接入正式 Dock，不连接 Runtime，不读取会话或启动麦克风。需求记录：[Issue #83](https://github.com/hupao-creator/Mokusei/issues/83)。

## 打开

```sh
python3 demos/moku-gradient-material/build.py
open .build/moku-gradient-material/MokuGradientMaterialDemo.app
```

产物只保留在本工作树 `.build` 中；不会替换已安装应用。关闭唯一窗口会退出 demo。

## 查看

- 左侧是生产 `NativeMokuCapsuleGlass` 的 regular glass；右侧是 clear glass 加方向性渐变的提案。上下分别展示展开面板与生产尺寸的 168×44 pt 胶囊。
- 默认强度 85%。强度控制渐变和附加亮边；0% 保留 clear glass，**不是**左侧 regular glass。浅背景且强度低于 50% 时，演示文字切为深色以保持可读。
- 切换暖沙、浅色、深色背景，用「移动背景」观察原生玻璃采样。背景是本地 SwiftUI 曲面图形，不是参考截图。
- 关闭「原材质对比」可单独观察提案；「收起 / 展开面板」检查大小变化。两侧共享可编辑的演示文字，收起后保留文字。
- 「恢复推荐」还原材质和展示参数，保留输入文字。「降低透明度预览」只作用于 demo，系统降低透明度设置始终优先；系统 Reduce Motion 禁用展开动画。

## 复用与实验边界

构建直接编译未修改的生产 `MokuGeometry`、`NativeMokuCapsuleLayout`、`NativeMokuCapsuleEyes` 和 `NativeMokuCapsuleGlass` 源码。仅把原有 `NativePlatform.swift` 编译成最小平台桥接模块，避免为了看材质而链接 Runtime、Markdown 或 WebRTC。

提案使用系统 `.glassEffect(.clear)` 提供背景采样和折射，再把暖黑至透明的渐变和底部细亮边叠于玻璃之上、文字之下。没有复制 Siri 私有实现，也不代表 Apple 官方材质。参考：[Apple Glass API](https://developer.apple.com/documentation/swiftui/glass)。

展开面板是独立内容 fixture：原生可编辑 TextField、装饰性附件/波形符号、收起按钮；不是生产 composer 或完整 Dock 的行为回放。仅生产几何、眼睛和基线材质直接复用，不能将此 demo 当作真实 Dock 的焦点、语音或动画验收。生产回放见 [MokuScene](../../app/macos/Sources/Host/MokuScene/README.md)。

## 验证

构建使用 Swift 6、warnings-as-errors 和 ad-hoc codesign。新增演示的集成检查应实际启动此 app，操作三种背景、强度 0% / 100%、移动背景、对比开关、输入编辑、收起再展开、降低透明度和恢复推荐，并检查文字和边缘无裁切。仓库代码检查仍运行 `make check`。
