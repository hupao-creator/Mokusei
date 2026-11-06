# Report Thread 原生交互提案

保留已确认的卡片对照提案，并提供正式 Report 卡片、分栏与 HTML surface 的确定性 fixture。预览不启动 Runtime 或 Agent。生产 Report 契约与 Host execution reader 已接入；此处的 execution factory 仍注入固定正文，不能认证真实 Harness 内容订阅。

- Report fixture 独立持有 `emoji`、`shortDescription` 与关联 executions。
- 卡片沿用普通 Agent Thread 的 360×200pt 尺寸、18pt 内边距、15pt 单行标题与右上角 44pt emoji 座位。摘要复用 `ThreadCardExcerpt`；emoji 复用 `ThreadCardProviderStatus`。
- 标题下方按关联 execution 的 harness 去重显示 12pt 生产 logo，并在同一行展示更新时间。多来源样本包含 Codex ×3、Claude ×2；同一 harness 仅关联一个 Thread 时不显示数量，侧卡中的执行也标识对应 harness。
- 整张卡片可点击，不单独放置“打开报告”按钮。不显示关联 Thread / execution，也不附加文档 icon 或“报告”类型标签。
- 卡片预览并排展示一个真实 `HarnessThreadCard`，便于比较同一尺寸下的标题、emoji、元信息、摘要、材质及间距。
- 打开后右侧列出关联 execution，侧卡与报告正文为 **2:8**（不含 16pt 间距）；报告始终在左侧。
- 点击 execution 后原侧卡变成该执行的阅读区，与报告正文为 **5:5**。
- 侧卡顶部返回按钮回到关联列表；Escape 先返回列表，再收起报告。报告关闭按钮直接回到卡片。
- 报告的同一个 WKWebView 在列表与 execution 切换之间保持挂载，保留阅读位置；窄列自动把报告中的统计块排成单列。

复用生产 `HarnessThreadCard`（对照）、`ThreadCardExcerpt`、`ThreadCardProviderStatus`、`NativeTypography`、`NativePalette`、`NativeIcon`、`NativeScrollView`、`ThreadMessage`、`NativeReadingPanelCloseButton` 与 Moku Dock。默认模式保留设计对照；`--production` 使用正式 Report 卡片、分栏和 HTML surface。底部 Moku 为环境参照，不接收输入。

## 运行

```sh
python3 demos/report-thread/build.py --production --open
```

生产原生模块已构建且没有变更时，可加 `--skip-build`。App 打包到隔离临时目录，路径保存在 `.build/report-thread/app-path.txt`。预览窗口顶部可切换三种状态和浅深色；⌘1 / ⌘2 / ⌘3 也可切换。窗口最小宽度为 1060pt，以保持本轮指定比例。

## 视觉复核

```sh
python3 demos/report-thread/build.py --skip-build --capture --open
```

截取卡片、2:8 列表、两条 execution、返回列表、深色与窄窗口状态，记录实际挂载后的面板几何到 `.build/report-thread/evidence/geometry.json`。这是设计预览，不运行 XCTest 或完整 CI，不认证生产数据契约。

## 本次本地验证（2026-11-05）

- Swift Debug 生产构建、`make lint`（架构检查及 Go vet）通过。
- Report 与 Application Host 的 race 测试通过；Application Host、Runtime 和 Thread Search race 集成回放通过。
- `reading-presentation --report-navigation` 四个原生用例通过。首次运行的关闭点击仍定位旧的右上角；修正为实际左上角圆形命中区的边缘位置后，保留并通过原有关闭动画和返回断言。
- 正式组件 fixture 实际点击卡片、两条关联执行、返回列表及 HTML 内 Escape；HTML 的 WebKit 文档身份保持不变。
- 用户指定仅合入本地 main；未创建远端 PR、未运行托管 CI，未运行全套 `make check`。数量标记追加前，签名生产 Release 导航（300 次随机交互）及阅读（三个种子与 trace 重放）通过。追加后重新构建最终签名产物，导航 `--steps 10`（30 次随机交互）及阅读 `--steps 10 --seeds 41`（含 trace 重放）通过；正式卡片的 Codex ×3、Claude ×2 已检查实际渲染和辅助功能标签。组件 fixture 不单独认证真实 Harness 订阅。

## 关联执行玻璃列表

正式模式现使用无序号、无连接竖线的 Liquid Glass item；标题下显示两行正文摘录，底部为 Harness 与耗时。`Production.swift` 注入固定耗时和示例正文，实际产品由每个 Harness 按精确 execution ID 提供数据。深浅色、降低透明度和真实导航由正式组件负责；旧设计对照不作为正式样式依据。

### 无序号玻璃列表接入验证（2026-11-05）

- 当前工作树的生产 Swift `Mokusei` product 和 Go `mokusei-runtime` 构建通过；架构检查、Go vet 与 `git diff --check` 通过。
- 正式组件 fixture 以 Swift 6 warnings-as-errors 编译并签名，实际打开 Report 卡片，确认五条玻璃 item 没有序号或连接线，正文为两行纯文本，底部显示耗时。截图：[生产组件列表](../../.build/report-thread/evidence/production-glass-list.png)。此 fixture 的固定正文/耗时只验证渲染，不认证真实会话数据链路。
- 初次 Swift 构建的 `guard` 尾随闭包语法已修复；预览首次受沙箱内 Swift 宏进程及 `ps` 限制，获批扩展执行后构建、打开成功。最终生产构建只有 SwiftPM 用户级缓存不可写提示，无源码编译错误。
- 按本会话 Sprint mode：未新增或运行测试，未运行集成回放、远端 PR/CI，不将本地构建视为 `Complete coverage`。当前 detached 工作树只交付提交，main 集成由调用方负责，未安装或替换用户的生产 App。

## Report 关闭的生产宿主验证

`python3 demos/report-thread/build.py --production --open` 现在包含完整的正式
`NativeReadingPageStack`、native panel、`NativeExecutionRouteSlide` 和
`NativeReportDetail`/WebKit，点击来源卡打开，左上角 × 通过正式 motion.close 返回。
列表采用生产 7:3，执行详情采用 5:5。已有当前构建时可加 `--skip-build`。
这是手动交互 fixture，不连接 Runtime；execution factory 仍使用合成正文。

右下角「慢速 ×5」改变本次阅读转场时长（正常 420ms）；「录制本窗口」通过
ScreenCaptureKit 只录制自身窗口、无音频和麦克风，停止后写入隔离 app 同级
`evidence/return-<timestamp>.mp4`。这两个控件不自动点击、不触发测试。
从 `.build/report-thread/app-path.txt` 可找到当前隔离 app 和录屏目录。
旧 `--capture` 仍是独立提案的历史截图入口，不能认证生产返回。

已用真实原生 UI 手动复现旧实现瞬隐，随后观察原生 carrier 修正的慢速/正常列表返回、
5:5 详情滚动后返回，并解码窗口录屏检查中间帧。证据与边界见
[Report 关闭调查](../../design/report-sidecard-close.md)。

共享 Agent 返回动画的后续复核保留同一入口。录制按钮在预览未成为 key window
时仍只选择本 app 的可见窗口，并显示无法录制的原因，不静默退出。最新验证以
[Report 关闭调查](../../design/report-sidecard-close.md) 的共享返回后续记录为准。

## Super Thread HTML/CSS 封面（2026-11-06）

```sh
python3 demos/report-thread/build.py --cover --disable-sandbox --skip-update --open
```

基于当前源码 `1d50be3`，不使用旧快照。封面模式在现有 production fixture
中复用 `NativeOverviewLayout` 当前 360×220pt 网格，在同一张 360×456pt
卡片内放入 HTML/CSS 封面行和生产 `NativeReportCard` 内容行，内部间距 4pt，
与普通 Agent Thread extension 的两行占位一致。封面占 308pt（约 68%），
内容区 144pt，短介绍最多两行；生产卡片统一限制为两行。
整张卡片只有一个背景、边框
和外层圆角；封面、内容和内部间距均可打开报告，动画起点为整张两行卡片。
原内容的字体、emoji、来源计数沿用生产组件。封面无 SVG、脚本和外部资源。
默认模式与 `--production` 保留原入口；`--cover` 自动选择生产组件。

构建使用当前工作树的生产模块，再将 demo 和资源签名打包至独立临时目录。
`.build/report-thread/app-path.txt` 记录最近成功打包的 App；封面构建旁的
`cover-preview` 标记让直接双击也进入封面模式。App 不启动 Runtime，不读取真实会话，
不安装或替换生产 App。关联列表与执行正文为确定性 fixture，非真实业务数据验证。
现有 fixture 已对齐当前 emoji 参数、Report 面板组合与 `report.relations` 查询接口。

`--disable-sandbox` 同时传入 SwiftPM 与 demo 的 swiftc，仅禁用编译器的嵌套
子进程沙箱，不改变系统权限或外层文件访问限制。`--skip-update` 跳过远端依赖
更新并锁定 Package.resolved；依赖须已缓存，缺失时不承诺完全离线。
SwiftPM 提示 skip-update 已弃用，但当前工具链仍支持。
生产模块已完成构建且源码未变化时可将 `--skip-update` 换成 `--skip-build`。
仅编译阶段直接清理自身临时文件，不调用用于运行中回放的进程扫描。

手动查看：第一屏确认同一卡片内上封面、下原内容；点击原卡片打开报告，再关闭返回完整两行卡片。
`--capture` 是历史提案的自动截图入口，与 `--cover` 不兼容。
本次按 sprint mode 不新增测试、不运行回归或 CI。

本次验证：生产 `Mokusei` Debug 增量构建通过；最终 demo 以 Swift 6
warnings-as-errors 编译、签名和动态依赖检查通过。通过桌面 UI 打开隔离 App，
实际检查封面与原卡片、点击展开的 Report HTML/四行关联摘录，以及关闭返回完整两行卡片。
未验证真实会话订阅或执行详情导航，不将手动展示检查计为回归通过。

环境记录：SwiftPM 和 swiftc 各自的嵌套沙箱都曾报 `sandbox_apply: Operation not permitted`，
各自传入标准 disable-sandbox 参数后解决。仅编译清理曾因 `/bin/ps` 权限失败，
已移除这个阶段不需要的进程扫描。命令行 `open` 曾报 `kLSNoExecutableErr (-10827)`，
尽管二进制存在且签名通过；同一构建经桌面 UI 打开成功。若命令行启动仍失败，
可在 Finder 中前往 app-path.txt 所列路径并双击 App，无须更改系统权限。
远端门禁/PR/run 查询返回 `error connecting to api.github.com`，未认证远端合并门禁。

后续比例修正：以同一完整外壳承载两行，总高 456pt；封面调整为 280pt，
短介绍由生产组件限制为两行。最终生产增量构建和 demo 编译签名通过，
已打开新版隔离 App 并目视确认统一边框、大封面与两行短介绍。
本轮未重做展开/返回检查；前述展开/返回记录属于此前布局版本。


生产落地：`--cover` 现由 fixture 提供 `coverRevision` 和 `report.cover` 的
确定性 HTML 响应，整张卡片直接使用生产 `NativeReportCard` / `NativeReportCover`。
Demo 不再持有自己的 WKWebView 或重复拼装封面与元信息；封面最终高 308pt，
内部间距 4pt，总高 456pt。默认 `--production` 注入无封面文档。

生产接入验证（2026-11-06）：最终 Go Runtime 与 Swift `Mokusei` 构建通过，
demo 编译和签名通过。手动查看生产 `NativeReportCard`，确认 308pt 封面、
4pt 间距、两行短介绍及整卡点击展开/关闭返回。最初的 srcdoc 容器显示空白，
改用本地 `mokusei-cover` 文档响应后实际渲染正常；WebKit delegate 签名警告已修复。
Go 默认缓存权限不足时仅改用项目 `.build/go-cover-cache`，Swift 使用标准
`--disable-sandbox`。没有运行测试、集成回放、回归或 CI，也未安装/重启生产 App。
本次 fixture 只认证生产组件展示，不认证后台模型实际生成封面的质量。
