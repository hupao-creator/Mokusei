# 正式 Overview Tag Morph 原生回放

此入口直接链接当前 Debug `MokuseiUI.NativeOverviewChrome`，用于验证正式实现；不复制标签 UI，不启动 runtime，也不读取用户会话。

```sh
make check
python3 demos/tag-filter-morph/build.py
open .build/tag-filter-morph/ProductionTagMorph.app
```

需要 macOS 26+、Xcode 26+。构建使用 Swift 6 / warnings-as-errors。产物在 Git 忽略的 `.build/tag-filter-morph/` 内，不安装或替换正式应用。应在每次生产源码变更后先重建 Debug 模块，再重建回放 app。如果回放已运行，先退出它再重新打开，以加载新的构建。

先点“加载 2 项”检查首次数据直接呈现；再检查增加、选中删除、批量六项、反转排序、成员/计数变化和清空。计数按钮同时改变 `selectionKey`，模拟真实会话成员更新；控件 identity 应保持不变。别名 Design 应选中“界面设计”，并在排序和计数更新后保持选中。

窄行宽度 540 pt；在标签区域滚动，检查“全部”仍固定、长标签可选、边缘不漏出文字。深色与手动相机开关覆盖正式主题和相邻操作按钮。系统无障碍偏好原样继承；SwiftUI 对应环境值只读，此入口不伪造或修改系统设置。

“自动增删回放”每 1.5 秒变更测试数据，循环 `2 → 3 → 6 → 2 → 0 → 2`。动画由正式组件自己决定，回放代码没有 `withAnimation`。先停止自动回放再做手动检查；停止或关窗会移除计时器订阅。

当前职责与交互见 [Overview 模块](../../app/macos/Sources/Host/Overview/README.md)。本目录仅是可重复的原生验证工具，正式行为位于 Overview 源码。
