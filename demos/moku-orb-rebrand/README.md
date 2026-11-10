# Moku 球体 Rebrand · Native Preview

生产组件的原生 fixture 预览，支持 Codex、OpenCode、Claude Code（CC）和 Pi。
没有 Runtime、账户、模型请求或真实设置写入。

```sh
python3 demos/moku-orb-rebrand/build.py --open
# 已完成当前生产产品构建时：
python3 demos/moku-orb-rebrand/build.py --skip-build --open
```

独立 app 路径记录在 `.build/moku-orb-rebrand/app-path.txt`。
主窗口复用生产 Overview Canvas、Chrome、Harness 卡片、Scene、原生编辑器、
Talk、Note 和派发内容。所有业务数据均来自内存 fixture；不连接 Runtime、
模型、真实账户或用户 profile，也不替换已安装的 Mokusei。

构建脚本直接链接当前生产 `NativeMokuDock`、`NativeMokuTheme`、材质、
Note/Talk、composer 与插件 logo，不复制或在临时源码中重写实现。
控制窗的「Agent 输入」与第二个 Harness 选择器用于检查目标颜色/logo；Moku 配色
保持独立，回到球体后恢复。实际 detail 路由由现有 landing/send regression 检查。

## 交互与形态

- 收起态为 64pt Liquid Glass 球体，不附 Harness logo。
- 球体的同一玻璃节点直接展开成输入框、Talk、Note 或创建 Thread 气泡。
  展开后没有独立小球或眼睛。圆角和控制样式沿用现有组件。Overview/Note/Talk/派发与历史输入不再预留眼睛空间；
  Agent detail 只保留实际 Harness logo 的位置。
- 输入、Talk、Note、派发气泡使用各自球体最深色调的 Clear Glass 和白色文字，
  不使用旧的灰黑/暖黑底调。各展开状态共用稳定的亮度上限；时间和模型信息保持
  足够亮的白色墨色。展开后使用均匀深色，不添加底部浅蓝渐变或发光边；球体保留原始渐变。
  控制窗顶部可切换四款配色，展开时也可直接对照；不会读取或变更真实 Harness 设置。
  圆形 artwork 的透明边缘在变形前段退入整块渐变，避免被拉成椭圆。
- 运行态沿用原有三点环绕逻辑、数量、颜色与节奏，轨道跟随新的球体几何。
  一圈为 3 秒，沿用生产 quintic smootherstep：前半圈加速、后半圈减速，首尾速度为零。
  圆形运行态的停止按钮居中，仍在悬停或键盘聚焦时显现；展开后的控件位置保持原样。
  不增加 thinking trace，也不按 Harness 数量改造环绕点。
- 点击球体可输入，Escape/外部点击收起，向上滑动打开 Note。
  独立控制窗口可切换各形态、深浅背景、窗口宽度与连续演示。
  「禁用预览过渡」只改变本预览 SwiftUI transaction，不宣称注入了系统 Reduce Motion。

## 验证与限制

这个预览构建入口只运行 `swift build --product Mokusei` 和独立 app 编译、签名。
生产落地另行运行现有 regression，未新增测试用例。
给独立 app 传 `--capture` 可生成自身窗口的展示截图，包含深浅背景、展开/收起
中间帧、快速反向、窄窗口和原有三点运行态。截图为异步观察，不能作为固定帧率
或性能测量。

```sh
open -W -n /private/tmp/mokusei-native-replay-orb-<id>/MokuOrbPreview.app --args --capture
```

本次只合并本地 main，不触发远端 CI；fixture 不验证真实模型请求或麦克风。

本地完成产品构建及独立预览构建。首次编译修正了旧 demo 的 Canvas 参数和只读的
无障碍环境设置；改用本地禁动画事务。动画着色使用主 actor 隔离的 Animatable
conformance。视觉复核修正了素材被拉成椭圆的问题，并保留最终版本的深浅色、
中间帧、窄窗口、快速反向及三点运行态展示。

## Harness 配色对照

球体直接加载 Settings 的同一素材。展开 tint 以素材内部低亮度 0.1% 分位的色调为基准，
排除透明边缘和最外侧 4% 的高光边；再仅降低亮度以照顾白字与 85% 占位字。
所有展开状态共用白字所需的亮度上限，不另引入灰黑调色板。Pi 使用其较深的蓝青色，CC 使用陶土色，
OpenCode 使用近黑中性色；所有深色展开形态均无底部渐变。

`--capture-palettes` 展示四款配色 × 深浅背景 × 球体/输入/Talk/Note/派发。
这是内存 fixture 展示与截图，不是 Harness 连接或业务集成验证。

生产回归范围、旧用例清理及失败处理见 [本地回归记录](validation.md)。
