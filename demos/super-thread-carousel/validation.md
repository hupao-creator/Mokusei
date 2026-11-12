# 生产接入验证

## Light mode 指示点对比度修复 — 2026-11-11

- 控件取消强制深色环境，数量、箭头、页码菜单和玻璃跟随工作区主题；
  选中点使用系统 primary，未选中点使用 secondary，保留长胶囊/圆点区分。
- 本地静态审阅覆盖选中/未选中、过渡/非活动禁用、七篇以上菜单、
  命中区域、辅助功能选择标记及拖动/滚动/自动翻页的现有逻辑。
  输入、时钟与生命周期代码无改动；这不代表实际交互回放通过。
- `python3 demos/super-thread-carousel/build.py --headless` 首次因沙箱 DNS
  无法下载依赖而退出 1；允许网络后同命令退出 0。当前生产 Debug 构建、
  独立生产组件 fixture 编译/签名及 headless 导出完成。13 个数据场景、
  30 个生产投影场景可解析，所有生产 `error` 为空，stderr 为空。
  日志：`/tmp/carousel-light-contrast-headless.log`、
  `/tmp/carousel-light-contrast-headless-retry.log`；数据在
  `.build/super-thread-carousel/`。
- `git diff --check` 通过。没有新增测试、运行全套回归、启动 GUI 或重启应用。
  headless 不挂载轮播玻璃或 WebKit，不能证明浅/深色像素对比度、
  hover/pressed/focus/disabled 外观、辅助功能显示选项或转场帧通过；
  这些图形验证本次未运行。
- 只读查询 main 实际 rules 与 PR/run 状态：规则 26378950 要求 PR，
  未返回 required status check 规则；已有 CI 属于其他提交。
  本轮不推送、不自行合并，由调用方协调本地 main 集成与最终 CI。

## 历史生产接入记录

基线 `d2127dbf70280bddac5a1d0ba8515bac6ec1c3b5`，2026-11-10。用户先确认独立 demo，随后授权落地生产；本轮交付 detached 工作树提交，由调用方集成 main。不安装、关闭或重启正在运行的正式应用。

## 已完成

- 当前源码 `Mokusei` Debug product 构建通过，最终生产代码构建日志为 `.build/super-thread-carousel/production-integration-build-3.log`。SwiftPM 的用户缓存只读提示未影响编译。
- 既有 `NativeOverviewMembershipTests` 的 7 个无窗口方法、`NativeOverviewScopeFilterTests` 的 7 个方法通过，共 **14 项**，零失败。`MOKUSEI_TEST_HEADLESS=1`，显式排除需要 display 的 `mountedContentUpdatesAvoidCanvasInvalidationAndRetainLatestExitSnapshot`；该图形用例未运行，不算通过。日志 `.build/super-thread-carousel/focused-headless-tests.log`。
- `mokusei-check architecture` 通过，覆盖模块边界、静态注册及 no-Node 规则；日志 `.build/super-thread-carousel/architecture.log`。
- 生产组件 demo 以 Swift 6 warnings-as-errors 编译，ad-hoc 签名、严格签名验证和动态依赖检查通过。最终日志 `.build/super-thread-carousel/production-demo-final.log`，产物 `/private/tmp/mokusei-native-replay-carousel-5xft2l1w/SuperThreadProductionDemo.app`。
- 原 13 个 fixture 场景导出完成，资格判断使用生产 policy，严格 600 秒边界符合要求。
- 16 个生产模型场景导出并人工核对：各标签内一组/零组；成员与独立项无重复；打开 source 指向集合；展开期间背景不变、返回后移出；单候选解散；preferences 重载保留事实；搜索不集合；成员内容更新可见；临近门槛前独立、定时到期后无 catalog 事件也能归组；普通偏好写入保留打开记录。所有模型 error 字段为空。文件 `.build/super-thread-carousel/production-projection.json`，headless stderr 为空。
- 本地审阅：集合身份与真实报告身份分离；回程按重新布局后的成员卡片定位；取消/隐藏时停止任务；打开失败写盘时保留本次会话事实并报错；最大四个封面挂载；集合参与语义导航且不成为 Runtime 实体。新文件空白、Python AST 与新增本地文档链接已检查。

## 远端状态与范围限制

初次沙箱内 GitHub 查询连接失败。扩展执行下重新读取：旧 branch protection endpoint 返回 `Branch not protected`，实际 main ruleset `26378950` 要求 PR、解决 review threads，返回规则中没有 required-status-check 条目。查询时可见 PR #300、#290 已有各自成功的 Complete coverage；这些是其他提交的结果，不能认证本次改动。

本工作树不创建/切换分支，不推送、不创建 PR、不合并或修改共享 refs；调用方负责最终集成与最终提交的 CI。没有新增测试，没有运行全套 `make check`、无关回归或托管 CI。本地 fixture 数据不是图形验证：真实触控板路由、Liquid Glass 像素、转场中间帧和生产 reader 展开/返回的图形回放未运行，不宣称通过。原设计 demo 的启动观察只属于当时产物。

此前 demo 迭代的编译参数缺失、JSONText 重载歧义及 Animatable actor isolation 问题均已修复；相关保留日志在 `.build/super-thread-carousel/*attempt-*.log`。这些旧失败不替代本次最终源码验证。


## 打开记录缺失调查与修复（基于 db6aac3）

本次工作树以 `db6aac38db959a15463768ae215243a8913175d8` 为父提交，调查过程只读用户状态；没有打开报告、推送、重启或安装应用。

### 实际证据

- 运行中的正式 Dev App 使用 `Mokusei Native Dev` profile；connection 元数据的 Runtime PID 与同一安装包路径下的 Runtime 进程匹配（进程已由 launchd 持有，不声称仍是 App 的直接子进程）。二进制包含 `NativeReportCollection`、collection policy 及两个 `recordApplicationOpen` 符号；反汇编运行包的 `NativeWorkspacePresentation.open` 确认有对 Overview 记录方法的直接调用。包未嵌入 Git SHA，因此不把这些符号当成运行包精确等于 db6aac3 的证明。
- 初次读取的 `desktop-preferences.json` 仅有 preferences/onboarding 字段，**没有 `applicationLastOpened`**，mtime 为 2026-11-10 22:01:11（+08:00），早于本次进程 22:22:36 启动。截图附件 mtime 为 22:23:33；这只是附件落盘时间，不是精确拍摄时间。
- 只读复制数据库与 WAL，在源文件 size/mtime 前后稳定后，仅查询隔离副本。第二、第四篇是有效、未归档的报告，共享 Mokusei 目录和“界面显示”语义标签。截图没有标签栏，不能确认截图时具体选中的 tag。它们的记录没有打开字段；卡片所示 1 小时/56 分钟来自 `updatedAt`。
- 旧版 Report 不记录可恢复的持久化打开历史；Overview `recentActions` 属于瞬时 broker context，性能 `thread.open` 仅记录普通 Agent 且不提供这两篇的打开证据。没有用更新时间、报告正文、封面预加载或关联 Agent 访问来推断 Report 已打开。
- 调查后期正式 profile 又被外部运行活动更新，出现空 `applicationLastOpened` 与普通选择字段；历史条目仍为零。这个变化晚于 headless fixture 退出，因此不宣称 live 文件全程字节不变。本任务没有对真实 profile 写入；所有验证写入均在临时 fixture profile。私有数据库副本已删除，只保留最小观察摘要 `.build/collection-investigation/observations.json`。

**结论：**当前持久化状态不足以让截图中的两篇通过“曾打开且最后打开超过十分钟”条件。不能证明用户过去没打开过；能证明软件没有那份历史。旧数据无可靠时间可以自动迁移，必须等真实新打开产生记录。这个条件没有改为“报告更新超过十分钟”。

### 独立复现的入口缺陷与修复

基线 `recordApplicationOpen` 额外要求 Overview 私有 `applicationsByRef` 已填充。实际 catalog 已含报告、Overview 尚未投影时，调用真实 `NativeWorkspacePresentation.open` 可选中报告，却静默漏记。这是独立确认的入口缺陷，不把它冒充已经证明导致截图的唯一原因。

改为从权威 catalog 校验引用；记录不再依赖是否投影过卡片。增加只读归组诊断，明确区分无历史、最近打开和时间合格；报告时间标签增加 tooltip，说明它是更新时间。

| 无窗口生产入口场景 | db6aac3 基线 | 修复后 |
| --- | --- | --- |
| 旧偏好缺少打开历史 | 0 条；不猜测 | 0 条；诊断 `no-open-record` |
| catalog 已加载、Overview 未投影，真实 open 方法 | selected=true，persisted=false | selected=true，persisted=true |
| 已投影后真实 open + 返回 | persisted=true | persisted=true |
| 新打开的资格诊断 | — | `within-open-interval`，eligible=false |
| 不存在的报告引用 | — | 不写入打开记录 |

基线日志/输出：`.build/collection-investigation/baseline-entry.log`、`baseline-projection.json`。修复日志：`fixed-build.log`、`fixed-entry.log`；最终生产 fixture 共 22 个输出场景，原有归组/到期/搜索/持久化结果仍可审阅。生产 Debug 构建、Swift 6 warnings-as-errors fixture 编译、签名及 headless 导出通过。按 sprint 未新增测试、未运行回归套件或 GUI 回放；真实鼠标/触控板操作仍未验证。

验证前读取 main ruleset 26378950（PR 规则），现有远端 CI 属于其他提交。本轮不推送或运行托管 CI，最终集成由调用方完成。

## Collection close/read timing — 2026-11-11

本次 sprint 不新增测试、不运行无关回归；复用现有 headless fixture 导出，
通过生产 catalog、Overview、导航入口和临时 profile 核对行为。

- `python3 demos/super-thread-carousel/build.py --headless`：当前工作树 Debug
  生产构建、独立 replay 编译/签名与无窗口导出完成（退出 0）。13 个轮播 fixture、
  30 个生产场景；所有生产投影 `error` 为空。
- 严格边界：120 秒整保留资格；累计前台 120.001 秒清除；中间遮挡不计时；
  同一路由重复打开不重置。实际 cancellable reading deadline 在无新事件时清除资格。
- 短读返回和反复短读保留；长读返回恢复独立卡片；只剩一位候选时集合解散。
  每次关闭重新开始等待；打开期间即使推进墙钟一小时也不获得资格。
- 实际关闭记录往返保存后：300 秒整不合格、300.001 秒合格；未来关闭不合格。
  首轮核对发现 Date 参考 epoch 与 Unix epoch 往返的浮点精度导致精确边界提前通过；
  改为在持久化的 Unix 秒域比较后，重新构建及导出确认以上结果。
- 无 catalog 事件的关闭到期自动归组、持久化重载、普通偏好写入保留、搜索逐篇显示、
  成员内容刷新、首次 Overview 投影前真实导航落盘和无效引用拒绝均已核对。
- 旧 profile 仅有 `applicationLastOpened` 不会生成关闭事实；真实 open 写入无关闭时间的
  marker，路由替换/返回写入关闭。保留旧打开数据，不推断历史关闭或阅读时长。

首次构建因沙箱 DNS/网络及用户缓存写权限失败，未执行 replay；获准下载锁定依赖后
构建成功。随后本工作树增量构建和 headless 导出成功。没有把首次失败或旧提交结果
计作通过。导出在 `.build/super-thread-carousel/{headless,production-projection}.json`，
使用独立临时 profile，没有操作运行中的正式应用或用户数据。

已查询远程：经典保护接口返回 main 未受保护；有效 ruleset 要求 PR 和解决 review
threads，没有 required status checks。当时 PR #300、#290 的 Complete coverage 为
success，最近 main run 42788322800 为 failure；这些结果不认证本次提交。
本次不推送、不合并，由协调方串行集成；未触发本次托管 CI。

未运行全量 `make check`、Swift 测试套件、GUI/截图/物理手势或实机验证；不声明视觉
中间帧通过。关闭计时属于本地客户端事实，异常退出不会伪造关闭时间；未保存的前台
阅读时长不跨进程恢复。

## 2026-11-11：轮播页数禁用态变暗

- 用户录屏 `录屏2026-11-11 16.55.49.mov`（attachment
  `019b038f-b946-484a-99b1-a78b76c20d1b`）以软件 FFmpeg 解码；全片
  7.97 秒，提取全片概览及 4.2–5.4 秒的导航条中间帧。未打开播放器。
  AVFoundation 初次提帧因解码能力错误 `-11821/-12911` 失败，改用软件解码成功。
- 原因：翻页期间 `NativeReportCarouselChrome.disabled` 正常锁定控件，但
  `.borderlessButton` Menu 自带的禁用外观覆盖了导航条 ButtonStyle，单独压暗
  x/x 和下拉箭头。改用 `.button` 继承既有样式，显式保留下拉箭头和原标签间距。
  页数表达式、选择状态、原生禁用边界、布局高度和 460ms 动画均未改动。
- headless 对照使用当前生产源码的 chrome modifier/ButtonStyle 及菜单标签，
  在无窗口 `NSHostingView` 中缓存位图；未创建 NSWindow、未启动 GUI 验收。
  以 1/2、2/2、1/4、4/4、1/12、12/12，分别注入 light/dark，比较锁定前后。
  修复前 12 组位图均不同，修复后 12 组均完全相同；所有场景修复前后的
  控件尺寸一致（四篇以内 96×59，1/12 为 102×59，12/12 为 109×59，含 probe 外围）。
  这是临时验证 probe，没有新增测试或测试套件。
- 当前工作树 `MokuseiApplications` target Debug 编译通过；仅构建受影响 target
  及其依赖。`git diff --check` 通过。原始帧、临时 probe、位图与编译日志保留在
  `.build/carousel-dimming/`（不提交生成物）。
  提交 hook 的 `make lint`（architecture/static registration/no-Node 和
  `go vet ./...`）通过；未执行回归测试。
- 限制：离屏 AppKit 缓存不认证真实窗口的材质、颜色或中间动画帧；没有运行
  GUI、物理输入、无关回归或完整测试。GitHub 门禁、PR/run 查询因无法连接
  `api.github.com` 失败；未推送、未触发 CI，最终由协调方验证并合入。
