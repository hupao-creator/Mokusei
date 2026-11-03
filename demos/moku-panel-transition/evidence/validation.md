# 本地审查与验证记录

2026-11-03，macOS 26.5.1 / arm64，Xcode 26.5 (17F42)，Swift 6.3.2。
代码基线为 `9e3a941`；[源文件摘要](provenance.json) 对应最终构建与抓帧的代码。

## 证据

- [用户录屏收起阶段](source-close.jpg)：2.20–2.70 秒的局部抽帧。
- [修复前生产组件](before-close.jpg) / [修复后](after-close.jpg)：同类完整收起过程。
  旧版文字留到眼睛回程后段；新版文字先退场，外壳与眼睛连续回到常驻状态。
- [修复后展开](after-open.jpg)、[采样动图](sampled-motion.gif)：真实 WindowServer
  截图按观察间隔组成，**不是原生刷新率录屏或性能基准**。
- [极窄窗口](tiny.png)：180×140 逻辑视口，132pt 胶囊，两行输入，文本视口 85×34pt。
- [原始观察记录](samples.json)：36 个样本，含观察时间、窗口、原生文本视口、
  眼睛 frame、编辑器身份和选区。完整 PNG 位于工作树 `.build/moku-panel-evidence/final/`。

覆盖完整展开/收起、120/100ms 中途反向和再次展开、多行文本、420×300、
300×190、180×140、窗口缩放、landing 与预览禁用过渡。
所有观察样本均只有一个 face。快速反向沿用同一个编辑器；420→300 跨过布局阈值时
编辑器 ObjectIdentifier 保持相同，没有因两行布局而重建。

最终完整收起的已挂载文本视口样本，窗口坐标 y 恒为 **32.5pt**，宽度恒为
**406pt**、高度恒为 **58pt**；眼睛沿数值坐标回程。中间审查发现的
14pt 首帧文字上移已消除：保留原生布局的动画事务，将不同曲线仅限制在透明度，
并使用底边定位。没有通过跳过中间帧或放宽判据隐藏该问题。

实际鼠标/键盘预览确认：点击胶囊打开，输入 `Transition preview draft`，选择
`preview`，Escape 收起，重新点击后文字和所选区间均恢复；点击阅读背景可以收起。
这组鼠标/键盘操作已在最终构建中再次执行，并与最终完整像素抓帧一起复核。

## 已执行

- `xcrun swift build --package-path app/macos --disable-sandbox --product Mokusei`：通过。
  最终构建未使用 `--build-tests`，没有构建或运行测试目标。
- `GOCACHE="$PWD/.build/go-cache" ./scripts/go.sh run ./cmd/mokusei-check architecture`：通过。
- 预览使用 `swiftc -warnings-as-errors` 链接当前生产对象：通过。
- Python launcher 语法编译、`git diff --check`、本次修改的本地链接检查：通过。
- 本地 review 已处理动画事务泄漏、保留期与可见期混用、编辑器首帧位移、
  窄窗口零编辑宽度及跨阈值重建风险；最终抓帧在这些修正后生成。

最初受沙箱限制的 AVFoundation 解码、依赖下载、Swift macro 编译未成功；
在只读视频解码/构建与隔离预览授权范围内重试后完成，未改系统设置或真实数据。
预览曾尝试写入系统只读 Reduce Motion 环境值，编译拒绝后改为明确标记的本地
「禁用过渡」，不将它当作系统无障碍实测结果。

## 未执行与限制

按本次 sprint mode，**未新增或运行测试、历史回放测试、make check 或托管 CI**。
提交通过命令级 `core.hooksPath=/dev/null` 禁用 hooks；只交付 detached HEAD 的
本地提交，不推送、不创建 PR、不合并。

系统 Reduce Motion 为 false。已审查其几何、ink 和原生 caret 的 nil/still 路径，
并观察预览禁用过渡时直接到达终态；**未切换系统无障碍设置实测**。
未覆盖真实 Runtime 高频更新/负载、模型、语音、真实附件和输入法组合；
未完整回归共用眼睛所在的 Settings、Note 和历史页。此预览的纯 fixture 阅读背景
不认证完整生产导航。异步截图与几何读取存在时差，不能据此承诺设备 FPS、
能耗或所有运行负载下的流畅度。

验证前只读核对远端：main `8ca887b`，ruleset 要求 strict `Complete coverage`
和 PR 门禁。main 的历史 run `41475926061` 为失败（Native verification / Complete
coverage）；不是本次提交结果，未重跑。集成方应对最终集成提交遵守实际远程门禁。
