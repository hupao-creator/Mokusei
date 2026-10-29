# Landing setup 原生 demo

[Spec #103](https://github.com/hupao-creator/Mokusei/issues/103)：新用户按「发现本机 Agent → Moku Host / Targets → Tag Agent → Report Agent → 中心输入」完成设置。
这是独立的 macOS 原生交互提案，使用确定性内存 fixture；不会扫描本机 CLI、安装 Agent、写入用户配置或调用模型。

## 交互约定

- 发现页只显示检测状态和逐个出现的 Agent 图标、名称，不显示 Moku 或说明段落。未发现时才展示官方安装入口和重新检测。
- 已发现 Agent 时只保留「继续」，移除左下角刷新按钮。
- Moku Host 单选，Targets 多选且至少保留一个；Host 可以同时作为 Target。Host 的模型与推理选择不应用到所有 Targets。
- Moku 步骤直接挂载设置页 `NativeMokuSettings` 的协调派发 map，使用 Git 历史 `8f3548f` 中的圆形 `MokuCharacterView`，不显示 Host / Targets 文案。沿用角色眨眼、Host 换乘动画、Target 连线和选中反馈；原生 settings draft 的保存回调只写内存。模型选择仍由示例 catalog 提供，首次设置暂不展示高级路由指导。
- Tag 和 Report 各有独立步骤，默认跟随 Moku；切换为独立配置后可选择 Agent、模型和推理强度，切回继承保留独立选择。
- 前后切换保留选择；全程保留原 landing 背景，在中央悬浮面板内完成设置。完成 Report 后，面板连续收拢到真实 Dock 的位置和尺寸，再交给生产 composer 和模拟派发。
- 首个模拟任务选取已勾选的 Target，并展示该 Agent 的原生品牌和示例模型。
- Demo 控制菜单提供有 Agent / 无 Agent / 模拟安装、浅深色、宽窄窗口与重新开始；演示控制不混入产品步骤。
- 已发现 CLI 不等于已登录或有可用模型。这里的模型名和目录均为示例，不代表本机 catalog。

## 视觉与内容

视觉主张：少文字，以 Agent、Moku 角色和能力动画作为每一步的主体。
发现页以逐个出现的品牌图标为主体；Moku 页以圆形 avatar 和派发连线呈现协调关系。
Moku 主标题下居中展示副标题「One mind to orchestrate them all.」（中文对应「一个头脑，统筹众 Agent。」），以较小的次级文字保留主次层级。
Tag 与 Report 沿用同样的居中副标题样式，分别使用「A few tags to find them all.」与「Less to read. More to understand.」（中文对应「循着标签，找到所需会话。」和「少些阅读，多些理解。」）。
Tag 页使用 SpriteKit 二维物理：十五个轻量元素带着稍长的任务标题和各自的生产 Harness logo，以不规则顺序和间隔落下，发生真实碰撞、旋转、反弹和堆叠。底部与侧边只有隐形碰撞边界，不绘制容器。
落入条件由固定 fixture 提供；堆叠由物理求解器产生。等待落定后解除刚体，再让同一批元素从实际位置归入设计、开发、调研、文档和维护五个标签。
文字与品牌图标从原生 SwiftUI 渲染为清晰纹理；不展示数量、模型或回复摘要。每个元素的 Harness 归属全程一致，减少动态效果时直接显示整理结果。离开步骤时取消排程并移除场景节点；非活动窗口暂停渲染与物理计算。
Report 页先横向展示六份长文档：页头使用生产 Harness logo，页内以密集、长短变化的文本骨架表现阅读负担。文档随后收拢，展开成一张横向的报告，左上角并列展示 Codex、Claude Code 和 OpenCode logo；三幅抽象图依次表达「全貌、关系、要点」，仅配少量短标签和简短文字骨架。
终态借鉴 ELI5 的大图少字原则与生产 Report 的理解优先契约，展示多图叙事文档这一产物；不讲解具体操作流程，也不把三幅图规定为生产报告的固定模板。
两种动画均为原生二维示意，Tag 使用 SpriteKit，Report 使用 SwiftUI；不引入 3D，也不复制生产任务或报告页面。
角色配置位于动画下方，仅保留继承或独立配置及必要字段。
继续、重新检测、返回与模型菜单统一使用不加 tint 的原生 `glass`；角色模式和 Agent 选择使用原色交互式玻璃胶囊。
相邻玻璃控件由 `GlassEffectContainer` 分组，选中态由中性轮廓和勾选标记表示，减少透明度时提供实色底。进度与报告状态也使用中性色，不设绿色主题。
面板继续提供稳定的阅读底色，发现的品牌图标与能力动画不添加额外玻璃底。
动画在离开步骤、窗口隐藏或应用非活动时停止；系统减少动态效果时显示整理完成的静态结果。
设置内容先退场，悬浮面板用约 780ms 收拢到生产中心输入的胶囊，最后以 180ms 交接到实际编辑器。
重置取消未完成的交接；减少动态效果时直接完成交接。设置期间不挂载隐藏编辑器，避免抢走键盘焦点。
步骤内容在同一个 ZStack 中交接，避免过渡中的新旧页面叠加成额外滚动高度。
面板采用 `.scrollIndicators(.never)`，覆盖 macOS 鼠标接入时可能优先显示滚动条的策略；紧凑窗口保留滚轮和触控板滚动。

原 landing 窗口、工作区和背景始终挂载；96% 中性底色仅用于悬浮面板，限制深色或高饱和壁纸透入内容后的亮度范围。
正文、说明和进度文字使用明确的浅深色颜色值，不依赖透明度降低文字层级。
系统提高对比度或减少透明度时底色完全不透明；最终 landing 继续使用现有组件。

## 运行与验证

```sh
python3 demos/landing-setup/build.py --verify --open
```

已构建当前 Swift 模块时可追加 `--skip-build`。产物路径位于 `.build/landing-setup/app-path.txt`，
窗口截图与回放报告在 `.build/landing-setup/evidence/`。按 Command-D 打开演示控制窗口。
Command-5 切换高对比背景检查：在同一窗口内放置黑、蓝、红、白底色，再经过实际内容底色合成；
这样窗口级截图也能捕获背景对比度压力。仍需在真实桌面壁纸下查看交互窗口，因为单窗口录屏可能不保留窗口背后的桌面材质。

回放操作挂载后的原生按钮，并通过生产 Settings 控件注册执行 map 的原有交互，验证空检测阻断、重检、单 Host / 多 Target、独立配置与继承切换、返回保留选择、
最终生产编辑器真实输入和派发。截图覆盖每步、无 Agent、深色与紧凑窗口；`04-report.png` 与 `04a-report-diagram.png` 分别捕获长文档和图示阶段。捕获仅限 demo 自己的窗口。
回放还检查面板四周保留背景、设置时没有隐藏编辑器，以及最终与真实 Dock 几何一致；`panel-to-moku.json` 保存布局观测，`04d-panel-contracting.png` 捕获收拢中的实际窗口。SwiftUI 布局观测可能只给出起止值，不能单独证明中间动画。
原生点击后连续检查过渡期间没有可见的 NSScroller。
代码合并前使用当前提交完整 CI 或等价的 `make check`，并运行本 demo 与共享 landing fixture 的原有回放。
不声称覆盖真实安装、登录、模型可达性、Runtime 保存和产品首次启动接入。

`LandingFixture.swift` 与原 landing demo 共用，品牌图标、Moku 眼睛与玻璃、窗口材质、最终工作区均来自生产模块。
独立 app 保留于临时目录，不替换已安装应用。

## 生产接入

[生产 onboarding](../../app/macos/Sources/Host/Onboarding/README.md) 已复用此处确认的视觉与流程。
Tag / Report 动画直接来自生产模块，本 demo 为其提供确定性的 Harness fixture；
Moku map、品牌、圆形角色和最终 Dock 同样复用生产组件。
独立 demo 的配置控件仍使用内存 fixture；真实首次启动、发现和保存由 Go-backed Settings
回放挂载生产 `NativeWorkspaceView` 验证，不能用 demo 的通过替代生产验证。

`SetupConfigurationPanel` 为本 demo 与 [Settings 顶部 tab 提案](../settings-tabs/README.md)
共享同一套配置交互；步骤进度、前后导航、发现与 Dock 交接仍由 `SetupSurface` 独立负责。
模型与推理选择复用生产 `NativeModelSelector`，仍由示例 catalog 和内存配置驱动。
