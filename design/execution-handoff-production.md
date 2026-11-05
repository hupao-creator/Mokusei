# Execution 交接进入生产 Thread Detail

基线：`740e725`。确认提案来自
[execution-handoff demo](../demos/execution-handoff/README.md)。本次将提案接入
生产 Host、真实 Harness reader 和 Sidecard 生命周期；demo 自身不变。

## 编排与归属

1. 仅对已展开且拥有本轮 execution 的 Sidecard 启动交接。原有同 execution、
   reading target、历史导航、归档、覆盖、禁用与生命周期检查保留。
2. 原生 Host 保留正在阅读的主 reader。隐藏的第二个生产 reader 立即取得本轮内容；
   正文 owner 确认终止状态、Markdown 解析就绪或可读错误到达后才开始运动。
   catalog 的终止通知不代表缓存中的运行中正文已经完成。
3. 第一段复用 Sidecard 原生折叠布局和 `NativeReadingPageTiming` 的 420ms 曲线。
   Sidecard 保持原尺寸横向收入不透明主面板后方；堆叠布局向上收入。主面板同时扩宽
   或增高。上一轮保持自己的列宽与滚动位置，随主面板居中移动。
4. 第一段真实 completion 后才进行第二段 420ms 纵向整页替换：上一轮向上离开，
   最新 execution 从下方进入。Core Animation 只移动呈现层，TextKit 的 model
   viewport 留在可见区域。新页从准备开始就采用目的地宽度，不逐帧重排文字。
5. 到达后保留同一个新 reader、释放旧 reader；已被遮挡的 Sidecard 隐藏退场，避免
   正常 fold 再露出一趟。原生 hosting 根结构始终一致，不因撤销门禁而重建文档。

生产采用新页自己的目的地列宽；demo 将新旧页都固定在旧列宽。本次每个文档在运动
期间仍只接受一次宽度，落地后遵守生产全宽布局。没有照搬 demo 的 220ms 完成停顿、
独立按钮、fixture 页面或慢速控件。

宽度偏好、分隔线、Browser/Voice、输入与媒体的归属不变。新 execution、卡片选择、
reading target/覆盖变化、归档和 release 取消旧交接；异步内容与完成回调仍按交接
UUID 和 execution identity 校验。Close 与 launcher 保留取消入口；交接不请求焦点。
Resize、inactive scene、减少动态效果在内容就绪后直接停靠；运动中启用减少动态效果
也立即停靠。窗口调整允许按新尺寸重新排版，不继续使用旧位移覆盖新几何。

## Sprint 构建与实际观察

没有新增、修改、编译或运行测试用例，没有执行 `make check`、测试回放或 CI，
没有推送、创建 PR 或修改分支/远程规则。交由调用方合入本地 main。

生产构建命令：

```sh
xcrun swift build --package-path app/macos --product Mokusei --disable-sandbox
```

构建覆盖四个 Harness 和最终 Mokusei 产品。首次受限构建无法解析 GitHub；允许下载
固定依赖后完成构建。一次增量构建读取到编辑中的旧 timing 模块而失败，随后重建
消除错误。最终构建结果以本地 `production-execution-handoff-final-build.log` 为准。

实际观察使用临时、无断言的 AppKit 窗口，链接当前产品对象，挂载生产
`NativeSidecardWorkspaceLayout`、状态机、Codex scoped reader、Markdown 和执行
Sidecard。仅在隔离临时 profile 中提供内存内容事件，不连接 Runtime、执行任务，
也不启动已安装应用。独立窗口显式提供 active scene；否则 NSHosting 默认后台
场景只会观察到停靠路径。未启动任何测试运行器。

最终观察序列退出状态为 0，无 stderr 运行错误；留下 21 张窗口截图及原生视图记录：

- 普通交接与延迟正文：先保留双栏，再收入，之后翻页；源卡没有伸缩/渐出，
  落地后没有再次闪回。普通记录从准备开始至正文就绪约 760ms，收入约 458ms，
  随后翻页至到达约 478ms。截图与主线程排版会影响这些采样时刻，不代表 FPS。
- 连续执行、深色长正文、740pt 窗口的堆叠布局、准备中 resize、用户收起和新轮
  中断均观察到对应收尾；可读加载错误可以交接到主面板。
- 人为延迟正文终止状态：catalog 已完成但内容仍运行中时保持双栏；终止正文
  到达后才开始收入和翻页。
- 长正文滚动到 `y=300` 后，准备/翻页中的主滚动视图保持同一原生对象、675pt
  viewport 宽度与 `y=300`。新页 viewport 为 1060pt、起点 `y=0`；落地保留
  该新对象，没有把上一轮滚动位置带过去。
- 翻页中开启减少动态效果、翻页中 resize 均直接停靠；预先减少动态效果仍等待
  正文。观察未修改系统无障碍设置。

临时观察程序、截图、`phases.json`、视图记录、启动/隔离/退出收据保留在当前工作树
`.build/execution-production-observation/`。最后一次构建日志位于
`/private/tmp/production-execution-handoff-final-build.log`。这些文件不是提交中的
持久化测试设施。

观察修复了两个实际问题：已收入源卡在正常 fold 时露回；不一致的 hosting 根修饰器
导致 reader 重建和第二次正文 entrance。最后一轮图像及原生对象记录已复核这些修复。
Claude/Pi/OpenCode 的终止 readiness 经构建及代码审查，未做它们各自的运行观察。
完整 Runtime/Harness 联动、输入焦点/选择的人工操作和后台场景切换未做实机认证。

## 留给集成方的验证边界

只读查询确认远程 `main-pr-gates` ruleset 仍要求 strict `Complete coverage`；
当前 detached 工作树没有 PR。本次没有本提交的托管检查，构建/观察不替代该门禁。

现有 `NativeThreadSendFeedbackTests` 的交接用例仍描述旧契约：先扩展源卡，再释放
主内容；部分断言要求运动早于 destination readiness。本次没有运行或改动这些用例。
自动审批拒绝了同步既有断言的操作，理由是超出本次 Sprint 测试范围。集成方需要
在获准的后续测试工作中按新契约同步这些旧断言，不能把它们当作本次已通过的结果。
