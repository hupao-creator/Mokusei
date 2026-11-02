# Agent Thread 面板转场 · 原生提案

独立 macOS 26 SwiftUI demo，使用内存 fixture，不连接 Runtime、不读取用户 profile。
已确认设计的独立 fixture 预览；生产导航已接入同一面板与分屏几何。真实工作区生命周期以生产集成回放为准。

```sh
python3 demos/thread-panel-transition/build.py --verify --open
```

已完成当前源码的 Swift build 时可追加 `--skip-build`。
独立 app 的地址记录在 `.build/thread-panel-transition/app-path.txt`。

- 点击任意任务卡片：从其实际位置展开为有边距的阅读面板；左右各 76pt，顶部 58pt，底部 88pt 留给 Moku；右侧工具列位于预留空间中。
- 不对 title、model / author、emoji 单独做位置转场；保留卡片外壳展开，完整生产详情页渐入。
- 标签栏收起、设置按钮退场；红绿灯保持窗口职责，关闭按钮位于面板内部。
- 原有输入与执行、浏览器、语音讨论入口位于面板外右侧，垂直居中排列；各自为 42pt 圆形 Liquid Glass 按钮，间距 14pt，没有整组玻璃背景。
- Moku Dock 在展开期间保持同一实例，仍可打开输入。发送只模拟接收。
- 关闭按钮 / Escape 返回来源卡片；支持展开中途关闭。
- 「演示」菜单：⌘1 打开首个任务、⇧⌘W 关闭面板、⇧⌘S 慢速转场、⇧⌘D 深浅色。
- 点击右侧入口按现有逻辑分屏：同时展开一张 Sidecard，再次点击同一按钮或侧栏自身关闭按钮会收起；点击其他入口可切换。
- 主阅读区与 Sidecard 为两张独立圆角卡片，外壳统一使用生产阅读页的实色背景与细边框，不使用 Liquid Glass；右侧入口按钮仍保留独立玻璃效果。卡片之间露出 16pt 工作区背景。整体仍保持左右各 76pt；Moku 不移动。
- 复用生产默认比例：输入与执行 1/3、浏览器 2/3、语音 36%；侧栏至少 320pt，主阅读至少 360pt。中间使用生产分隔线，可拖动或键盘调整；每种侧栏保留各自宽度。
- 可用面板宽度小于 760pt 时，沿用上下分屏，卡片间仍留 16pt。折叠和切换不卸载插件会话，输入草稿保持。
- 三张侧栏的内部内容复用实际 Conversation、Browser、Voice 插件。发送和语音能力由内存 fixture 提供，不执行真实任务、不打开麦克风；浏览器初始为空，只有用户输入网址才导航。

Overview Canvas、Chrome、HarnessThreadCard、ThreadConversation、ThreadDetailTurn、ThreadMessage / Markdown、Moku Scene / Dock、窗口材质与图标均复用生产组件。
详情完整保留生产阅读列宽、标题与 emoji 排布、author、消息/执行过程筛选、历史侧栏、执行页脚和原生滚动；数据由两个执行轮次的 fixture 提供。
外层独立卡片编排属于 demo。直接链接完整生产卡片、阅读、Sidecard 内容与分隔线组件，不插入身份元素的几何观察器。
面板与分屏几何直接使用生产 `NativeReadingPanelGeometry` 和 `NativeSidecardWorkspaceGeometry`，不再提取或改写生产源码。宽度偏好来自真实插件的 `SidecardView`。
演示始终展示三个入口（包括尚未打开网址的浏览器），以便比较布局；正式插件可用性门禁和 Runtime 不属于演示。
减少动态效果时取消动画。

`--verify` 在独立 AppKit 事件循环中检查源卡片、展开/关闭、左右各 76pt 留白、顶部 58pt 与底部预留、
窄窗口深色和打开中途反转。新增三个真实侧栏的分屏、16pt 卡片间隙、非重叠、宽度调整/记忆、快速切换、会话保留及窄屏上下分屏检查。
捕获当前进程的窗口截图、panel-geometry.json 与 split-geometry.json。
回放状态驱动不代替鼠标命中验证；交互另用原生 UI 点击卡片、关闭按钮、Moku 输入与侧边入口检查。
中间帧需要视觉复核，几何观察值本身不证明逐帧渲染。产物在 `.build/thread-panel-transition/evidence/`。

本地验证范围为 Swift 构建、demo 编译（Swift 6，warnings-as-errors）、该 demo 的回放和原生交互。
没有运行完整 `make check` 或托管 CI，也不以本提案认证生产路由、真实执行、浏览器或语音生命周期。

本轮首次回放发现演示语音能力的异步回调离开主线程导致退出，已将模拟状态发布显式切回 MainActor；原始崩溃日志保留在 evidence/failures/，修复后重新运行最终版本回放。
