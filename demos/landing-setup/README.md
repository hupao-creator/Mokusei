# Landing setup 原生 demo

[Spec #103](https://github.com/hupao-creator/Mokusei/issues/103)：新用户按「发现本机 Agent → Moku Host / Targets → Tag Agent → Report Agent → 中心输入」完成设置。
这是独立的 macOS 原生交互提案，使用确定性内存 fixture；不会扫描本机 CLI、安装 Agent、写入用户配置或调用模型。

## 交互约定

- 发现页演示检测中、发现 Agent、未发现 Agent。未发现时展示官方安装指南、登录提醒和重新检测；继续按钮不可用。
- Moku Host 单选，Targets 多选且至少保留一个；Host 可以同时作为 Target。Host 的模型与推理选择不应用到所有 Targets。
- Tag 和 Report 各有独立步骤，默认跟随 Moku；切换为独立配置后可选择 Agent、模型和推理强度，切回继承保留独立选择。
- 前后切换保留选择；完成 Report 后，直接挂载现有 landing demo 的真实 Dock、composer 和模拟派发。
- 首个模拟任务选取已勾选的 Target，并展示该 Agent 的原生品牌和示例模型。
- Demo 控制菜单提供有 Agent / 无 Agent / 模拟安装、浅深色、宽窄窗口与重新开始；演示控制不混入产品步骤。
- 已发现 CLI 不等于已登录或有可用模型。这里的模型名和目录均为示例，不代表本机 catalog。

## 视觉与内容

视觉主张：沿用 Mokusei 的原生玻璃、安静留白和 Moku 双眼，每屏只出现一个需要决定的问题。
内容顺序：Moku 胶囊与步骤标题 → 当前选择 → 作用说明 → 唯一主操作。
交互：步骤短距离淡入、选择状态平滑过渡、最后让设置内容退场并进入生产中心输入；减少动态效果时关闭新增位移。

## 运行与验证

```sh
python3 demos/landing-setup/build.py --verify --open
```

已构建当前 Swift 模块时可追加 `--skip-build`。产物路径位于 `.build/landing-setup/app-path.txt`，
窗口截图与回放报告在 `.build/landing-setup/evidence/`。按 Command-D 打开演示控制窗口。

回放操作挂载后的原生按钮，验证空检测阻断、重检、单 Host / 多 Target、独立配置与继承切换、返回保留选择、
最终生产编辑器真实输入和派发。截图覆盖每步、无 Agent、深色与紧凑窗口。捕获仅限 demo 自己的窗口。
代码合并前使用当前提交完整 CI 或等价的 `make check`，并运行本 demo 与共享 landing fixture 的原有回放。
不声称覆盖真实安装、登录、模型可达性、Runtime 保存和产品首次启动接入。

`LandingFixture.swift` 与原 landing demo 共用，品牌图标、Moku 眼睛与玻璃、窗口材质、最终工作区均来自生产模块。
独立 app 保留于临时目录，不替换已安装应用。
