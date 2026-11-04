# 本地维护整合 · 2026-11-04

用户授权仅更新本地 main，不建 PR、不推送；Spring Mode 下不新增测试、不运行
回归测试、回放或 CI。另一个仍在开发的 HTML 链接功能不纳入本轮整合。
原 main 为 `a77d3a354887eb054516e10d432f825378ca7c8a`，检查时工作区干净。
整合在 `/private/tmp/mokusei-maintenance-integrate-20261104` 的隔离 worktree 完成，
最终以 fast-forward 更新本地 main；保留原提交和其他 worktree 的工作。

## 已交付维护提交

| 提交 | 内容 |
| --- | --- |
| `4418041b17682c7844e66ba95057691752872ad6` | 移除退休的 Conversation 输入和并列 Talk/Note 测试；将 stale poll 的既有断言改为成功 no-op，保留调用次数和协调断言。 |
| `a83c22164c87f65088adddce69583ada70f50652` | 全局非空搜索结果 oracle；清空或退出搜索后仍检查当前 scope 的精确成员。 |
| `ffa0d78c0236003d15e95ab6d923c7dc653c23ba` | 在上述顺序链后，将审阅过的完整无窗口套件路由到 Headless 进程，再运行图形补集。 |
| `8783e1b95cbf00b62d4cef6860c4bf6cd001bbcd` | 移除未调用的 Runtime/workspace/store 入口和未挂载的原生视图；保留 Composer 支持、Moku 轨迹和逐 key 缓存。 |
| `2e791ddc45ea2a01caee9354b959dd8e40c371b6` | 按当前生产实现修订阅读转场、搜索、归档入口、材质、通知持久化及 worktree 文档，保留历史调查。 |

## Headless 审阅和整合修正

静态核对发现 35 个自包含和 4 个 fixture 套件名称均唯一对应源码，目标模块与
Package.swift 一致。fixture 仍由原变量决定是否进入 Headless；未供应时保留原
图形执行/延后路径。按发现的完整清单分区、原生方法排除、实际终态与 framework
计数对账保持不变；未知和混合套件仍归图形进程。

保留实际需要显示环境的窗口、焦点、输入法、WebKit 输入和中间像素测试，保留
11 个原生方法的专属 owner、执行 marker 及中间帧要求。Metal 仍为真实 GPU 离屏
渲染；Headless override 不能证明物理上不存在 WindowServer。

发现图形补集会继承父环境的 `MOKUSEI_TEST_HEADLESS=1`，因此显式给图形子进程
设置 `0`，防止误触发显示跳过。真实显示能力检查仍保留；不修改测试或断言。
同步修订运行文档及本地日志捕获说明。

文档冲突逐处协调：保留双进程计划，采用源码对应的 12 个 native checks；移除
已由 `a83c221` 修正的“搜索断言待清理”警告，保留 keyword-only 产品契约和现存
非 keyword 诊断分支的说明。[原文档审计](documentation-audit-2026-11-04.md)
保留其时间点上的依赖记录，另加整合补记。

## 非测试验证

- `make lint`：通过架构边界、静态注册、无 Node 源检查、gofmt 和 `go vet ./...`。
- `./scripts/go.sh build ./...`：通过。
- 变更 Python 文件使用内存语法编译；不导入、不执行测试或控制器入口。
- 对变更 Markdown 做本地路径及锚点检查，并检查 diff 空白和冲突标记。
- `xcrun swift build --package-path app/macos --scratch-path
  .build/maintenance-swift --force-resolved-versions --disable-index-store -j 2`：
  通过，116.28 秒；没有使用 `--build-tests` 或运行测试。

Go 初次检查因沙箱不允许写编译缓存而停止，获准使用正常缓存后通过。Swift 初次
尝试受 manifest 沙箱限制；下一次发现复制的 PCH 含原 checkout 绝对路径，改用
独立 scratch 目录，仅复用依赖源码。失败构建日志保留，不作为产品失败或成功证据。
原始非测试检查日志位于整合 worktree 的 `.build/maintenance-integration/`。

## 此前失败与未验证范围

[失效测试清理记录](../tools/verification/swift-tests/obsolete-tests-20261104.md)
记载 Spring Mode 之前：全 Go race run 的旧 `TestMokuDeliveryAdmissionFence`
错误期待失败，修正后 Runtime 的 16 个方法通过；最初 Swift 测试构建因已删除的
Conversation API 失败，移除旧用例后测试构建通过，但其后 Talk 清理未执行测试。
普通 Swift 执行和 adapter group 被中断，均不算完整通过；未诊断为产品回归。

本次没有测试执行结果，不以旧结果认证整合提交。Swift 过滤器的真实运行、分进程
计数、取消语义、fixture、图形输入、WebKit、Metal 和托管 Complete coverage
均未执行。未改变远程保护或声称通过远程门禁；本次授权仅涉及本地 main。

## 后续交付：Tag Agent 只读 Overview

前五项维护内容已先以 `4ac93e032a9bc3a1c03fc060c3c5cb7e741573e9` 快进
本地 main；随后按用户追加要求整合
`b6697112055cca5ba6f3b2c7f71b3743d3aecdaa`（Remove filter selection
authority from the Tag Agent）。没有等待或纳入仍在开发的 HTML 链接功能。

静态审阅确认 `select_tag_filter`、opaque observation 决策及插件写适配器被移除。
`read_overview_context` 保留 scope 成员过滤、分页快照、大小限制与 lifetime/request
取消；不再输出 client/context 身份、revision 或 selection handle。背景能力仅有
`ReadClients`。手动 Overview 筛选和客户端 transport 协议保持可用，其现有测试
不因 Agent 写权限移除而删除。既有 Tag 只读 evidence 与退休生命周期用例保留；
仅移除退休的选择权限用例和 fixture。没有新增测试。

此提交与现有维护内容自动合并，没有文本冲突。另在 transport 文档明确客户端
控制与 Tag 只读能力的边界，并在原文档审计补记后续变化，保留历史基线。
最终 `make lint` 和 `./scripts/go.sh build ./...` 均通过，日志为
`tag-lint.log` 和 `tag-go-build.log`。最终静态复核解析 7 个变更 Python 模块、
567 个本地文档路径与 21 个锚点，没有发现错误；diff 空白检查通过。
没有重复执行 Swift 构建，因为后续提交及协调修订没有改变 Swift 源码、依赖、
资源或构建输入。没有运行任何测试、回放或 CI。

## 后续交付：本机 HTML 链接

在前两轮整合完成后，以干净的本地 main
`2c1c10ce06eb8f52a37f38604841d0f723aa5fb3` 为起点，单独整合
`24cfed131f59697e07e4c79654e9f16dcef98954`（Open local HTML links in
Agent Thread browser sidecards）。来源基于较早的 `a77d3a3`，保留原始提交。
沿用专属隔离 worktree；PluginUI README 自动合并，检查后确认死代码清理和其余
已整合文档均保留，不覆盖用户或其他 worktree 的工作。

### 路径和编码约定（源码审阅，未运行行为用例）

- 接受绝对路径与本地 `file:` URL；相对路径、`~` 不推导 cwd 或 Home。
- 绝对路径的 `?`/`#` 属于文件名。查询和片段需使用 file URL，例如
  `file:///tmp/a%23b.html?q=%2520#section` 指向文件 `a#b.html` 并保留后缀转义。
- 路径转义解码一次；`%20` 表示空格，字面 `%20` 文件名应写 `%2520`。
  原生 URL 传递时重新编码，不再递归解码百分号序列。字面空格与 Unicode 保留。
- file URL 只接受无 host 或 localhost；拒绝远程 authority、凭据、端口、网络路径
  和 NUL。绝对路径也拒绝解码后以双斜线开头的网络路径。
- 打开前要求 `.html`/`.htm`，解析 symlink 后仍须为可读、常规、本地卷 HTML 文件。
  这是文件属性与扩展名准入，不是 HTML 内容净化，也不保证检查后文件不会被替换。
- Markdown 各内联链接经共享 parser；inline code 中的 HTML 路径可点击，普通未链接
  的文件文本和 fenced code 保持原样。Browser 不可用时，系统 HTML fallback 仍验证
  文件；默认外部应用对查询/片段的实际处理未验证。其他非 HTML 文件操作沿用原行为。

### WebKit 权限审阅与修正

`loadFileURL(_:allowingReadAccessTo:)` 的本机 Xcode SDK 声明区分单文件和目录读取。
普通文档授权其 canonical 所在目录以支持资源；这是目录内容读取范围，不是仅允许
CSS/图片的文件清单。发现根目录文档原先会授权 `/`，修正为只授权该文件，并使页面
导航的 admission 同样区分单文件和目录，保留 UTF-8 路径比较及目录分隔边界。

明确点击/地址输入才增加 session 的读取范围。本地 page/frame/GET popup 只能导航
到已授权范围内、重新验证过的 HTML，不能借 symlink 扩大目标范围。新 HTTP(S)
导航不能复用旧本地 grant；现有 back/forward 历史允许返回本地文档。会话释放清除
本地 admission 记录。子资源、跨 origin 读取及资源 symlink 仍由 WebKit 与 macOS
权限约束；没有新增 security-scoped grant、隐私权限旁路、私有 file-access 设置或
通向 Runtime/shell/Thread 的页面桥。HTML 保留原有 JavaScript 和网络行为。

本地文档禁用网页批注，避免将本地路径送入 HTTP(S)-only 批注载荷；之前的 web
批注草稿及回到网页后的功能保留。文档同步明确根目录、历史导航例外与权限限制。

### 本轮验证与剩余限制

本轮 Swift 生产构建通过（78.61 秒），命令为
`xcrun swift build --package-path app/macos --scratch-path .build/maintenance-swift
--force-resolved-versions --disable-index-store -j 2`，没有 `--build-tests`。
`./scripts/go.sh run ./cmd/mokusei-check architecture` 通过架构、静态注册与无 Node
源检查；diff 空白、文档本地路径/锚点及与已整合维护内容的差异复核通过。
日志保留在整合 worktree 的 `.build/local-html-integration/`。
没有新增或改动测试，也未运行测试、回放、CI，没有 PR 或 push。
实际 WKWebView 打开、资源加载、文件权限/TCC、symlink 竞态、
导航后缀、历史/弹窗、跨 origin 行为及打包应用的系统 fallback 均未做运行验证。
