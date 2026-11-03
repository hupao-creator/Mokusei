# Moku 输入胶囊转场修复与隔离预览

本次依据用户的 6.932 秒录屏定位：普通 **Agent Thread 阅读页底部的
Moku 输入胶囊**，占位文字为「发送给『修复历史执行工具消息泄漏』…」。
不是 Settings、Note 或 Moku 历史阅读页。视频原始尺寸 3088×2094，
轨道标称帧率约 54.89；抽帧不代表逐显示帧性能测量。

## 录屏证据与原因

[原录屏收起阶段抽帧](evidence/source-close.jpg) 保留请求时间戳。
0.8–1.1 秒展开时，Stop 先出现在中间，再到右侧；2.25–2.30 秒收起时，
外壳已骤窄，文字仍在胶囊内被截断；2.40–2.65 秒眼睛回到中央时文字仍未退完。
这组抽帧证明可见缺陷，不单凭视频推断掉帧的硬件/负载原因。

检查基线为本地 main / HEAD `9e3a941e913fd6cc24ffc4a00f661b616f93a804`；
同时核对远端 main `8ca887b832aae6dd788781bb36df0b080533ba7f`，本地包含其后续改动。
Thread 将自己的 draft、标题、运行状态和发送/停止回调交给同一个生产 Dock。

生产实现中的具体问题：

- `capsuleFraction` 在 `onChange(expanded)` 中另开事务，外壳目标几何已更新后，
  眼睛的 inset 才开始变化；眼睛所在行还在 intrinsic / 固定高度间切换。
- 收起后 `inputLeaving` 继续保留编辑器 420ms。旧透明度条件仍认作输入展示，
  因而使用 420ms 的展开曲线，文字会留到收缩中后段，与回程的眼睛相交。
- 透明度的 value 动画包住了整个 composer，也给原生行的几何换了曲线；
  输入行和外壳因此不是同一条运动时序。极窄视口的固定动作席还会把编辑宽度压到 0。

## 方案

外壳直接从当前 intent 导出几何；单个持久眼睛视图通过数值坐标与外壳在同一
420ms smooth 事务中移动，反向操作继续当前呈现值。胶囊以底边定位，
输入行保持完整目标宽度，外壳负责揭示/裁切；透明度曲线只作用于 ink，
不清空整段原生布局事务。文字在关闭 intent 到来后
120ms 退场，编辑器仍保留到原来的生命周期结束，以保留草稿和选择。

低于 260pt 的可用胶囊宽度时，编辑器/附件与眼睛/动作分成上下两行。
自定义 Layout 移动四个持久席位，不在宽度阈值处替换 NSTextView；
紧凑输入保留可滚动文本区域。外壳高度限制在可用视口中。
系统 Reduce Motion 继续让几何与淡入淡出动画为 nil，原生光标沿用其已有系统策略。

## 打开预览

```sh
python3 demos/moku-panel-transition/build.py --open
# 已构建当前产品后：
python3 demos/moku-panel-transition/build.py --skip-build --open
```

只构建 `Mokusei` 产品，不使用 `--build-tests`，不运行任何测试。
独立 app 路径写入 `.build/moku-panel-evidence/app-path.txt`。
app、资源和 workspace 暂存在 `/private/tmp/mokusei-native-replay-panel-*`；
无 Runtime、账户调用或真实用户设置/数据访问，不替换或重启已安装的应用。

主窗口可实际点击、输入、Escape、外部点击和调整大小。独立控制窗口提供
展开/收起、运行状态、Thread / landing、窗口尺寸和「禁用过渡」。
这个开关仅禁用该预览的 SwiftUI 事务动画，**不是系统 Reduce Motion 注入**，
不会修改全局无障碍偏好。

对该独立 app 使用 `open -W -n <app-path> --args --capture` 可重放纯展示序列。
它只截取自身窗口，输出 `evidence/*.png`、`samples.json` 与隔离收据；
没有测试断言、测试运行器或真实业务请求。截图异步抓取，间隔包含截图开销，
JSON 时间是观察时间，不宣称固定 FPS 或逐帧同步的性能结果。

## 本次验证与限制

见 [验证记录](evidence/validation.md)。预览复用生产 Scene、Dock、composer、
材质、原生编辑器和眼睛；阅读页背景与业务状态使用内存 fixture。
未接入真实 Runtime、模型、语音或用户存储，不能替代这些边界的集成验证。
