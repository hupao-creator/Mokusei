# Collection 展开与 hover 修复（2026-11-17）

## 基线与范围

- managed worktree：`collection-panel-expansion`，detached HEAD 基线
  `fb6edadc70c0ffc15dfeeafedc0fefebef5e9b46`。
- 只读对照集成端最新 `064445a3c2d9400a8f3c1c81bc3dcc3954511391`。
  BrowserWebSession、ThreadConversation 和两个任务的设计文档均未改动。
  共享文件只有 `Shared/PluginUI/README.md`，新增 Collection 容器说明在玻璃材质段之后，
  不替换最新 main 的历史文档身份段。未切分支、修改 main、推送或发布。
- 不新增测试，不跑全量回归。没有连接 Runtime、真实会话存储、麦克风或正式应用。

## 两个问题与实现

右上角 x/x 原来挂载 SwiftUI popover，最大 760×650pt，以 NSScreen 而不是
当前窗口定尺寸，位置锚定角落，视觉上像附属浮窗。
现在 Shell 提供窗口级 `nativeCollectionPanelHost`，Collection 仍拥有成员和生命周期。
直接复用 Agent/Super Thread 的 `NativeReadingPageStack`、
`NativeReadingPanelGeometry`、强调式 420ms 开场、原生合成器和关闭按钮；
从整个 Collection 的实际卡片 frame 展开，背景退出视觉和输入，关闭刷新来源 frame。
例如 1192×780pt viewport 的面板为 1040×634pt，500×400pt 时为 348×300pt，
遵循既有阅读面板的水平等边距和上下预留，不越出窗口。
固定标题栏下是居中的 LazyVGrid / NativeScrollView。卡宽最多 360pt，20pt 间隔，
根据窗口逻辑尺寸自适应列数；封面保持 360:308，元数据另占 164pt，封面与元数据间距 4pt。
成员顺序、原始身份、归档能力、打开回调和封面缓存保留。成员更新刷新当前面板，
关闭恢复轮播完整停留周期；覆盖路由/失活/离屏/卸载立即清理所属面板。
成员打开先清除面板再调用原有导航，不另造阅读或持久化语义。

追加录屏为 8.733 秒、4096×2554。以 1fps 提取了 9 帧：
`../../.build/collection-expansion/evidence/reported-hover-01.png` 至 `09.png`。
第 1 帧鼠标在卡片下方空白，第 4 帧在下排 Agent 卡片上，第 7 帧在窗口左侧空白，
第 9 帧在窗口下缘之外；Collection 封面底部的**整条箭头 / 圆点 / 页码菜单胶囊**仍显示。
不是成员面板，也不是封面自带的图案。

隔离诊断版临时把 `hovered` 和 `controlsVisible` 写进 x/x 的 AX value：
`hover-diagnosis.ax.txt` 记录二者均为 false，配对 `hover-diagnosis.png` 中胶囊仍完整可见。
确认原生 Liquid Glass 表面未被透明 SwiftUI mask 隐藏；不是简单把 hover 条件取反。
最终移除透明 mask，非 hover 时不挂载整条底部导航，连同命中与 AX 子节点一起移除。
仍使用整个 Collection 的原有 onHover 区域，额外以 active、成员面板和可见性准入，
面板开关显式清除 hover，失活/离屏/卸载继续清理。键盘焦点和菜单追踪不会强制显现。
右上角 x/x 常驻，正常轮播与成员入口不被删除。诊断 AX 文本未进入最终源码。

## 已执行

- 生产 `Mokusei` 编译通过；初次含依赖编译 97.81 秒，最终产品源码构建 12.95 秒。
  命令：`xcrun swift build --package-path app/macos --product Mokusei
  --cache-path "$PWD/.build/swift-cache" --disable-sandbox --disable-automatic-resolution -j 4`。
  最终日志：`.build/collection-expansion/logs/final-build.log`。
  增量构建仅有 SwiftPM 用户级 cache 不可写的环境警告，没有编译错误。
- `GOCACHE="$PWD/.build/go-cache" ./scripts/go.sh run ./cmd/mokusei-check architecture`
  通过架构、静态注册和 no-Node 检查；日志同目录 `architecture.log`。
- 既有 `python3 demos/super-thread-carousel/build.py --skip-build --headless` 使用本次
  生产对象构建/签名独立 demo，导出 **13 个数据场景和 29 条生产投影记录**。
  未把这些数据导出称为像素或物理手势验证。
- GUI 串行持有 native replay 锁，复用真实生产 Collection、成员卡和阅读容器。
  最终产品源码对应的隔离预览观察到：500×400 单列，滚动到第 9 篇无封面成员，
  点击进入该成员示意阅读 sheet、返回、再次展开；1.5× 两列、2× 单列；深色面板；
  Escape 和关闭按钮收起。标题与关闭按钮不随滚动移动。
- 展开前第 5/9 页，经过小窗口滚动及成员打开/返回后仍为第 5/9 页；随后继续轮换。
  原有最近关闭 fixture 自然到期后增至十篇，当前展开面板同步显示十篇。
- 非 hover 的初始状态与多次关闭/返回后，底部导航从截图和 AX 树消失，x/x 保留。
  `09-after-close.ax.txt` 可核对最终源码的隐藏子节点。
- 源码审查覆盖 owner fencing、旧成员动作、打开/关闭生命周期、当前窗口来源转换、
  scroll/cover 尺寸、不同窗口缩放和 reduced-motion 共享路径；`git diff --check` 通过。

## 视觉证据

所有路径均相对于本 worktree 的 `.build/collection-expansion/evidence/`，不提交用户录屏帧。

| 文件 | 内容 |
| --- | --- |
| `hover-diagnosis.png` / `hover-diagnosis.ax.txt` | 修复前 hover=false / controls=false 但玻璃胶囊仍显示 |
| `01-hover-out.png` | 改为按条件挂载后，初始非 hover 状态无底部胶囊 |
| `02-panel-wide.png` | 同一面板实现的 1192×780 三列浅色截图 |
| `03-panel-500x400.png` | 最终产品源码，小窗口单列与固定 Close |
| `04-panel-last-member.png` | 最终产品源码，滚动末尾无封面成员 |
| `05-after-member-return.png` | 最终产品源码，成员阅读返回后底部不残留 |
| `06-panel-zoom-1_5.png` / `07-panel-zoom-2.png` | 最终产品源码，窗口缩放两列 / 单列 |
| `08-panel-dark.png` | 最终产品源码，宽窗口深色三列 |
| `09-after-close-dark.png` / `09-after-close.ax.txt` | 最终产品源码，Close 返回且导航无残留 |

`01/02` 拍摄时曾试用 onContinuousHover，之后还原为原有 onHover；面板实现未变。
最终源码以 `03` 之后的产物为准。诊断版及最初缺少 scenePhase 注入的截图不充当最终视觉通过。
独立 App 路径在 `.build/super-thread-carousel/app-path.txt`；最末一次 demo 编译只删除
重复的原生菜单尺寸入口并改成 weak window 捕获，底部验证按钮和产品实现未改变。

## 未验证及工具限制

- CUA 的坐标输入不能可靠建立连续 hover 移入/移出：出现 `windowNotFoundAtPosition`，
  工具观察时窗口也可能失去前台焦点。**不声称真实鼠标 hover 显示/离开序列、
  原生页码菜单选择、隐藏区域实际点击穿透已经验收通过。**
  已确认无 hover 状态下的绘制修复、面板返回后的隐藏及 AX 子节点清除；
  复核者应在此隔离 App 实际移入/移出，组合面板开关和页码菜单选择。
- 空白边缘点击未取得可靠关闭证据；保留已有共享 backdrop 实现，不以本次工具结果宣称通过。
- 原生菜单自动化曾出现元素失效且无法退出；只清理已识别的本任务 demo 进程，
  随后以预览底部的尺寸/缩放按钮完成验证。不把菜单工具失败解释为产品成功。
- 未做物理触控板、VoiceOver、完整 Tab/Space 焦点遍历、多屏、Reduce Motion/Transparency
  系统设置切换或生产 Canvas 缩放中的来源动画逐帧测量。
  复用了生产 compositor，但没有宣称 420ms 动画性能或每个中间帧通过。
- Demo 目的地是示意阅读 sheet；未运行真实 Runtime 的完整 Report/Agent 导航回放。
  未新增测试，未运行完整 Swift suite、Go vet、make lint / make check 或托管 CI。
  pre-commit 默认会跑包含全仓 Go vet 的 make lint；本次按用户 Sprint 范围以本次提交
  命令级 hooksPath 覆盖跳过，不更改仓库配置；受影响的产品编译和架构检查已显式完成。
- 只读远程规则：main 有 pull_request ruleset，没有 required_status_checks；经典 protection
  返回 404。当前远程 runs / PR 已检查，但均不认证此候选。按用户要求未推送、触发 CI
  或合并；独立复核和本地 main 集成由协调端处理。


## 独立本地 main 集成复核（2026-11-17）

集成起点为 `b11242a1fcbb3a41aaf5cb7072f139cfc4e52a2d`，HEAD 在 main，
工作区与暂存区均干净。候选 `21a237dbb41fa3fa3f856a3dd5700727d4303258`
与该起点无冲突；未修改来源工作树。复核实际 diff、调用路径、原始录屏第 3 秒、
作者 receipt 与指定的深色/末尾成员截图，并在当前 main 的合并结果上构建。

### 发现与修正

- 空白边缘点击在本次隔离 GUI 中稳定不关闭。临时、只读的事件诊断确认 down/up
  均命中 `NativeReadingPanelBackdrop.BackdropView`；系统窗口分享指示器是可见的
  `NSLocalWindowSharingWindow`，但 `canBecomeKey == false`。
  原有“所有可见 childWindow 都阻断关闭”的条件把系统装饰也当作弹窗。
  共享 backdrop 现只以可见且可获焦的子窗口阻断；sheet、modal 与 NSPopover
  转发同一 press 的保护保留，不按系统私有类名判断。未改 Moku 等其他调用边界。
- 最终生产源码的隔离 demo 复验：左右边缘中的左侧点击关闭成功；返回时选中成员保留，
  后续自动轮播继续。成员上下文菜单打开时，第一次边缘点击只关菜单，第二次才关面板。
  Escape、展开及返回后的导航隐藏也已观察。初始与返回后的截图/AX 均没有底部导航。
- demo 的 8 秒轮播 / 2 秒静止说明已过期。标签改读 `NativeReportCoverTiming.dwell`，
  README 对齐 6 秒动画上限、独立封面完成后静止 5 秒、集合只播一次并停留 11 秒。
  生产时序文件、已有 15 秒失败封面回放预算、对应注释/README/断言均与集成起点相同。
  手动切换路径未增加等待。新增 archive 需求由独立候选负责，本次不改 archive 语义。

### 本轮实际验证

- 合并结果的生产 `Mokusei` build 成功（68.59 秒）；backdrop 修正后再次成功（14.40 秒）。
- 最终源码的既有 `build.py --skip-build --headless` 成功：13 场景、29 条生产投影。
  同时构建/签名了最终隔离 GUI；没有新测试用例、完整 Swift suite、全量 lint/check 或 CI。
- 串行持有现有 native replay 锁，仅操作临时 fixture App。最终 App：
  `/private/tmp/mokusei-native-replay-carousel-vtuxjsaq/SuperThreadProductionDemo.app`。
  工具无法保持前台，开启了既有“保持预览活跃”；不据此认证系统失活生命周期。
- 日志与本轮录屏抽帧在本 checkout 的 `.build/collection-integration/`。
  `mokusei-collection-pointer.log` 保留真实事件/命中，`mokusei-collection-children.log`
  保留系统子窗口属性；临时诊断未进入生产或最终 demo 源码。
  首次临时诊断编译因局部递归函数缺少 MainActor 标注失败，补标注后完成诊断；
  这不是产品编译失败。最终构建与 demo 日志分别为 `final-build.log` / `final-demo.log`。
- 只读远程规则确认 main ruleset 仅要求 PR，无 required status check；经典保护 404。
  远程现有 CI 不认证本次本地提交。按用户明确本地集成授权，未推送、未触发 CI、
  未修改远程规则。命令级 hooksPath 跳过会执行全仓 lint 的 hook，不改仓库配置。

### 保留的验证限制

CUA 无独立鼠标移动 API，坐标输入偶有 windowNotFoundAtPosition、AX 入口失效。
不把点击、滚动或状态注入当作连续真实 hover 进出：连续往返显示/隐藏、页码菜单选择、
隐藏导航区域真实点击穿透仍未认证。源码确认导航整体条件卸载且没有残留的命中/AX 子树；
这不替代实际指针验收。小窗口、缩放、末尾成员和成员返回复用作者证据，未无故重跑。
原生菜单出现归档入口但本轮未执行归档；新增归档交互及关联 Thread 的隐藏属于后续候选。
没有运行真实 Runtime 导航，也未认证全部动画中间帧、VoiceOver 或真实触控板。
