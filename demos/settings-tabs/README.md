# Settings 顶部 tab 原生提案

已确认的原生交互提案，保留批准时的内存 fixture，供设计对照。
正式 Settings 已按此布局接入共享生产组件；当前产品外观与生命周期验收使用
[生产 Settings 导航回放](../settings-navigation/README.md) 和 Go-backed Settings flow。

视觉方向：保持 onboarding 的居中、留白与配置交互，让顶部导航和内容共享一层无额外 tint 的系统 glass。
内容结构：General、Moku、Tag、Report 单层并列；页标题、既有图示、配置控件依次排列。
交互方向：顶部选中短线平滑换位，页面短暂淡入淡出，Moku 保留生产角色换乘与派发反馈。
Tag / Report 保留原有能力动画，配置同时可用；只移除 onboarding 步骤推进。
系统减少动态效果时取消过渡，能力图示显示完成态。

## 运行

```sh
python3 demos/settings-tabs/build.py --verify --open
```

已构建当前 Swift 模块时可加 `--skip-build`。独立 app 路径写入
`.build/settings-tabs/app-path.txt`，截图、点击记录与结果写入
`.build/settings-tabs/evidence/`。不替换或重启已安装的 Mokusei。

- 顶部四个 tab 随时可用，没有进度条、继续或返回按钮。
- Moku、Tag、Report 使用与 onboarding demo 相同的 `SetupConfigurationPanel`，
  继续共享内存配置和继承/独立选择；Moku map、品牌图标和能力图示来自生产模块。
  模型与推理选择直接挂载生产 `NativeModelSelector`，catalog 仍是示例。
- Tag 与 Report 进入即播放原有能力动画，配置立即可用，无需等待动画完成。
  切换 tab、继承模式或关闭重开后保留选择；离开 tab 时停止动画，返回时重新播放。
- 面板使用系统 `.regular` glass，不叠加 onboarding 的 96% 阅读底色，
  不使用原 Settings 侧栏与内容区底色。系统减少透明度时保留实色回退。
- General 预览复用生产设置行、外观选择器与开关，展示三个模拟已安装 Agent。
  外观和 `glass world` 只驱动 demo；语言、Agent 默认配置、安装与清空操作不属于本轮原型。
- 关闭、Escape 和背景点击使用现有配置 draft 的关闭 gate；关闭后通过右上角设置入口重开。
- `⌘0` General、`⌘1` Moku、`⌘2` Tag、`⌘3` Report；聚焦顶部 tab 后支持左右方向键、Home 和 End。
- `⌘D` 打开独立演示控制窗口，可切换外观、高对比背景、减少透明度、减少动态效果和窗口大小；
  其中实色与过渡开关仅覆盖本提案外壳；系统无障碍设置仍由共用控件独立遵守。
  `⌘4` 切换外观，`⌘5` 切换高对比背景。

## 验证边界

原生回放通过 AppKit 实际点击顶部 tab 和继承/独立配置控件，通过生产交互注册操作 Moku map，
检查 Report 直接访问、选择保留、至少一个 Target、键盘导航和关闭时的输入法保护。
截图覆盖 Moku / Tag / Report 浅深色、General、窄窗口、对比背景与减少透明度。
`02-tag-light` / `02a-tag-organized` 与 `03-report-light` / `03a-report-diagram`
分别记录 Tag 下落到归类、Report 长文档到图示的动画阶段。
共用配置抽取后另运行原 onboarding demo 回放，检查原五步流程保持可用。

所有模型、推理和安装状态均为确定性 fixture；不扫描 CLI、不调用模型、不启动 Runtime，
不写入真实用户设置。此回放不认证真实账户 catalog、Runtime 保存或生产 Settings 生命周期。
本目录保留提案的导航外壳；正式 Settings 使用其真实草稿、原生目录和保存机制。能力动画直接复用生产组件，未新增播放模式。
不以本次 demo 的结果宣称生产集成或完整 CI 已通过。
