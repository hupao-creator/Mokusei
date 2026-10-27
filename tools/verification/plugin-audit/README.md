# Plugin 专项审计（2026-10-25）

基线：`c17a3fcb270b8d862bbd9cc03ae18c45c4c133fd`。本报告记录本次专项的范围、证据与验证，不代表没有其他缺陷。

## 修复规格与协作边界

- 保持当前公开协议、数据格式和启停语义兼容；修复错误调用、错误准入、状态丢失、重复能力、清理遗漏及不可恢复状态。
- 在真实生产边界使用本地协议 fixture、临时配置/数据库和可控并发屏障。禁止真实模型、付费请求和外部消息。
- 不引入动态插件框架、不升级依赖、不为风格重构。注册输入只在所属边界验证，内部使用可信类型。
- 初期只静态扫描；验证窗口待父协调确认，避免干扰 Overview 测量。Runtime/Overview 文件保持只读；交界事实单独交接。
- 本树保持 detached HEAD，按问题批次提交。父协调独立 review 后负责整合；本线程不操作 main、其他 worktree 或远端。

## 实际架构与契约

| 边界 | 当前实现与权威 |
| --- | --- |
| 发现与装配 | `core/composition/bootstrap.go` 静态构造 Go 模块；Swift `NativePlugins.make()` 静态注册显示模块。没有动态安装包扫描或远端清单加载。 |
| Harness | Codex、Claude、Pi、OpenCode；各自拥有外部原生引擎的模型、账号、凭据、设置、session state 和协议翻译。Runtime 只通过 `core/plugin` 合同授权线程能力。 |
| Application | Report、Tag 和不可禁用的 Git；Application host 验证 manifest/贡献身份、注册、schema、scope、事务、receipt 和后台 agent 生命周期。 |
| Context | Artificial Analysis；独立 Context host，仅接收绑定模型目录，向 Moku 注入附加内容，不获得应用记录或执行能力。 |
| Sidecard | Conversation、Browser、Voice；原生 host 管理线程身份、实例 lifetime、选择与抑制；Voice 使用私有只读讨论。 |
| 启停与持久化 | 当前进程捕获 active catalog；保存的是 desired enablement，重启生效。禁用应用保留 schema/settings；移除的贡献清理过期设置及偏好。 |
| 工具与资源 | 注入由 `Injection`/`ToolBinding` 提供；各 Harness 转换其原生协议。Pi/OpenCode 的小型 JS 资源仅供外部引擎加载，没有独立 Node 应用。没有统一的 skills/resource 服务注册表。 |
| 版本与信任 | 当前 Application/Context API version 为 1；各 Harness 自行验证原生协议与 JSON，宿主注入的是受限能力；没有跨 Harness 凭据发现。 |
| 生命周期 | Start/Stop 管理 host 代次；Handle Interrupt/Close 撤销准入并排空拥有的工作；临时工作和 session state 的持久化由各所属模块负责。 |

## 覆盖与结论

以下是已保存的生产修复及对应回归边界。接管时仅有静态审查、格式与 diff 检查；所有执行验证结果另列，不能把 fixture 已存在当作测试通过。

| 边界 | 确认的问题与修复 | 对应证据 |
| --- | --- | --- |
| Application 注册 | 保留的 Registry 可在校验后继续注册；manifest、默认值和 Requires 可被原引用改写。注册返回后关闭入口并复制可变声明。 | `applicationhost/registry_test.go` 经真实 Host、SQLite、Query 验证晚注册拒绝、默认值及能力隔离。 |
| 后台生命周期 | 第一次 native Close 失败后再次 Stop 会错误成功；历史分页取消后仍继续读。保留清理错误，逐页检查 context。 | `background/runner_test.go`、`evidence_test.go` 使用真实 runner 和 evidence tool。已进入的单页 Read 无 context，仍不能中断。 |
| Tag 参数 | 非法 optional 字段和嵌套未知字段被静默忽略后仍发出修改。改用共享严格 typed decode，省略与显式空值语义分开。 | `tag/tools_test.go` 从生产 ToolBinding 派发，覆盖合法值和拒绝路径。Runtime 仍负责规范化、容量与 scope。 |
| Metadata | 输入已准入但 native dispatch 失败或 caller 取消时丢失命名意图；超长首次输入丢失最初前缀。成功准入立即持久保留，Interrupt 不重启旧命名，先截取首次文本预算。 | `thread-metadata/admission.go`、`intent.go` 覆盖持久化错误、准入/中断交错、重开、UTF-16 与附件。 |
| Codex | JSON 数字精度丢失；旧 turn 借用新准入；工具未排空就完成；stdin 背压时取消失效；非阻塞问题错误暂停；NUL 阻断持久化；启动取消漏清理。修复对应生产边界并去除只写不读的无界正文副本。 | 四个 `*_boundary_test.go` 覆盖 HTTP、真实 OS pipe、ReduceEvent/DecodeState 和回调清理屏障。 |
| Claude / Pi | bridge Close 仅取消未排空；Claude 转义 ID 无法关联取消；Pi 工具 panic 终止进程；native 写入与排队不受请求取消约束。关闭封闭准入并 join，按解码 ID 关联，panic 转为工具错误。 | 各模块的 `*_lifecycle_test.go`；Max 另修复三家完整帧写入与取消竞争误杀、Pi 排队取消遗留 goroutine，真实 OS pipe fixture 覆盖完成与部分写入。 |
| OpenCode | steering 在 native receipt 前被标为送达；锁内 HTTP 令 Interrupt 无法取消；bridge/SSE 未排空；配置发布非原子；`__proto__` 别名遗漏；隔离 HOME 使用错误；版本 wrapper 后代及 completion 清理错误遗漏。 | 模块 HTTP/文件系统 fixture 与 `opencode` native thread 回放；Max 复核准入与 drain 无新阻断，并修正 permission HTTP fixture 未读 body 导致取消挂起的问题。form 取消、allow-session GET/PATCH 挂起仅静态审查。 |
| Context / AA | Collect 提前返回使 Close 漏等 catalog 清理；共享刷新期限令其他目录陈旧；合并 slot 分隔符未计入总字节。join 回调，按 identity set 保存有界刷新期限，补计分隔符。 | `artificialanalysis/cache.go`、`lifecycle` 回放覆盖独立过期、失败隔离、warm cache、共享租约、关闭屏障与字节边界。10 分钟重试到期及 4096-key 淘汰仅静态审查。 |
| Git | 重启且时钟回退时新同步被持久旧 fence 拒绝，刷新和删除冻结。继承持久化最大尝试时间再递增。 | `git` 回放经真实 Host/SQLite 重启检查新文件、任务删除、身份保持及旧批次拒绝。 |
| Browser | 文件选择和 JS sheet 在隐藏、导航、释放后继续回调。按会话持有并以否定结果取消，每个 WebKit completion 仅一次。Max 补上取消期间递归导航提前清空 owner 的漏洞。 | `NativeBrowserDialogTests` 以本地 HTML 获取真实 WebKit 参数，19 个 case 覆盖四类 dialog、三类失效、隐藏、确认后重入和递归取消；必须图形会话执行。正常选文件和 alert/confirm 确认仅静态审查。 |

已有扫描覆盖静态发现与装配、manifest 精确匹配、能力版本/归属、工具注册调用、启停配置保留与过期配置清理、进程/会话恢复、原生 Sidecard 注册和生命周期。Report scope、事务/receipt、Git literal pathspec/读取授权、Harness native session ownership 及 enablement 重启生效未发现本轮需要改变的证据。Sidecard host 的异常 fallback 未释放实例是潜在扩展风险，现有内置插件没有可达触发，未修改 Host。

## 验证状态

2026-10-25 实际执行结果如下。完整命令、各次状态和已验证源码指纹见 [validation.json](validation.json)；原始日志保留于 `/private/tmp/plugin-audit-max-validation-20261025/`。

| 检查 | 实际结果 |
| --- | --- |
| `make check ARGS=` | 最终通过：Go 架构/格式/vet/build、Swift 包及测试编译、并发属性、插件/Host/Runtime/Moku race 测试，以及 13 项目录标签测试。 |
| 10 个 Go 生产边界回放 | `thread-metadata`、`applicationhost`、`runtime`、`artificialanalysis`、`artificialanalysis/lifecycle`、`git`、`codex`、`claude`、`pi`、`opencode` 均以 `go run -race` 串行通过。 |
| OpenCode installed-native | 2.0.25 的 `native`、`thread`、`foreground` 三个 case 全通过；真实 JS 加载及 `__proto__` 工具别名、配置/恢复、HTTP/SSE、权限/表单和清理均经 loopback provider 验证。 |
| Pi installed-native | 1.3.0 的 `-mode native` 通过；实际 loader、FD3 工具桥、read guard、持久化/恢复、取消和异步 shutdown 清理均通过。 |
| Browser 原生 dialog | [隔离 AppKit runner](../reading-presentation/README.md#browser-page-owned-dialogs) `--browser-dialogs` 最终完整通过 4 个测试、19 个 case，逐组与最终成功标记均检查。 |
| Browser 联动 | viewport、annotation、Sidecard navigation 共 7 个测试完整通过；普通 SwiftPM dialog suite 的明确 skip 也已单独核实，skip 不计作功能通过。 |
| 本地审查 | 继承的已完成分区审查和三个 Max 后续审查已收敛；最终 diff、格式、文档链接检查通过，无遗留确证阻断。 |

验证真实暴露并修正了两项遗漏：Tag 复用严格解码器的依赖声明，以及 OpenCode fixture `ReadThread` 的返回类型。前两次 `make check` 失败记录保留；修正后完整检查通过，Browser 验证方式变化后再完成最终检查。

Browser 普通 SwiftPM 首次返回 0，但在第一个原生文件选择 case 提前退出，没有完整摘要，因此记录为 **incomplete**，从未计作通过。复用现有 AppKit 应用事件循环后，同一 suite 完整通过；普通路径现在明确门控，原生 runner 额外校验 12+4+1+2 个 case 的成功标记。

未测边界：真实账户、付费模型、远端 OAuth/计费、真实音频硬件、生产性能；Codex/Claude 使用协议 fixture，未运行其 installed-native 模式。AA 的 10 分钟同键失败重试到期和 4096-key 淘汰、OpenCode form 取消及 allow-session GET/PATCH 挂起、Browser 正向选择文件和 alert/confirm 确认仅静态核对。后台已进入的单页历史读取没有 context，仍不可中断。所有 installed-native 推理仅使用临时配置、合成凭据和 loopback provider。

## 跨线程交接

原线程 `b2e812f7-dd02-4ee1-ba2d-9efb3ef3022f` 对应的旧本地 rollout 主 turn 已在 13:24 中断，但子任务仍在完成审查和写入。Max 接管保存 tracked patch 和全部 71 个文件指纹后，以旧 rollout 打开句柄确认其唯一 server，终止该旧 server 及后代；退出已复核。全部已写成果保留，未 reset、checkout 或重做扫描。之后仅启动 Astra Max，按 Harness I/O、OpenCode、Browser 分配互斥文件所有权以完成遗留 review。

接管恢复摘要：`/private/tmp/plugin-audit-handoff-recovered.md`；初始文件指纹：`/private/tmp/plugin-takeover-files.json`；初始 tracked diff：`/private/tmp/plugin-takeover-tracked.patch`。这些临时文件只用于审计追溯，代码与结论以本树及提交为准。

当前可用工具未提供向用户指定的其他顶层线程发送消息的接口，不能声称父协调已经完成独立 review。接管后遵守 Overview 13:33–13:48 测量窗口；额度恢复时核实无旧采样进程。Overview 14:21 明确记录当前没有测量窗口占用，后续验证串行完成。本树不编辑 Runtime、Overview 产品代码或其他 worktree；保持 detached HEAD，不操作 main、push 或 deploy。各批提交交父协调独立 review，通过后已获用户授权直接合入 main。

须由父协调留意的交界文件：

- `internal/tooling/architecture/check.go`：只为 Tag 增加既有共享 `plugins/applications/value` 的精确依赖；Report/Git 已使用该模块，没有增加通配规则。随 Application/Tag 批次整合。
- `tools/verification/reading-presentation/run.py` 及 README：复用现有 AppKit runner 增加 `--browser-dialogs` 和完整 case 标记检查，现有 suite 选项行为不变。随 Browser 批次整合；未修改 Overview 产品代码或测量工具。

## 提交批次

基于 `c17a3fcb2`，按下列顺序提交；最终代码 HEAD 为 `f7f11d401`。验证在提交前执行，`validation.json` 的源码 SHA-256 与提交内容逐文件一致；提交钩子也全部通过。

| Commit | 内容 |
| --- | --- |
| `97961e62f` | 注册冻结、后台清理与 Tag 参数边界 |
| `f094f5333` | 已准入输入的 metadata 保留 |
| `137d59d0c` | Context 排空、AA 独立刷新及大小边界 |
| `2adc1c8d1` | Git 跨重启时间栅栏 |
| `f6ec50f3f` | Codex 工具/文本/写入生命周期 |
| `188ba950d` | Claude/Pi 工具排空和写入取消 |
| `ad9d2b409` | OpenCode receipt、锁外取消、配置与清理 |
| `f7f11d401` | Browser 页面弹窗生命周期及 AppKit 回放 |
