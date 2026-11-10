# 生产接入验证

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
