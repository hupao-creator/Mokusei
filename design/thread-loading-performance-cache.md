# Thread / execution 阅读加载与短时实时缓存

2026-11-03；基线 detached `bace0f05ce80`。本次按 sprint mode，仅本地实现、
review、生产构建和人工观察；不运行/新增测试、CI、测试 hooks，不推送、建 PR 或合并。
不修改另一线程负责的 placeholder 视觉，也不合入其他 worktree 的消息显示规则。

## 本地规格与加载链路

目标：首次数据等待与 420ms 原生打开动画重叠；重复打开复用仍在实时更新的数据，
避免重新订阅、磁盘旧副本和相同 Codex opaque value 的重复解码。保留动画后的正文挂载、
运行状态、历史/消息目标和 reader 自己的滚动策略。缓存只拥有数据，不拥有视图、动作、
阅读请求、可选中文本、滚动位置或 Sidecard 生命周期。

当前生产链路：

1. `NativeWorkspacePresentation.open` 选择 thread/readingTarget，保存选择并更新输入、voice、presence。
2. `NativeReadingPageStack` 提交独立 Core Animation 几何运动；完成后才挂载 Agent workspace。
3. workspace 创建 Sidecard model 和 `NativeHarnessThreadSurface`，申请 manifest。
4. RuntimeClient 申请 content subscription；Runtime 投影/序列化，经实时流返回 snapshot。
5. Harness 主线程 materialization → Codex 后台校验解码 → conversation 选当前/目标 row。
6. row 再订阅对应 turn；解开 deferred envelope，后台 Codex admission 后构造可见消息。
7. Markdown parser actor 解析，主线程创建 attributed text、NSTextStorage/TextKit，布局并显示。

基线的第 3–6 步不能与打开动画重叠，且每次关闭都释放订阅。
基线联网打开还会先读取/展示持久阅读缓存，然后刷新实时内容；它不是新鲜度凭据。
Go 投影函数本身的同机 30 次观察：manifest 4185B，p50/p95 0.017/0.022ms；
turn 188233B，0.951/2.412ms；execution 737869B，2.109/6.591ms。
这些不含 Runtime 锁、磁盘、调度与传输，不能解释为完整订阅耗时。

## 新录屏证据

用户指定 `录屏2026-11-03 16.53.27.mov`。AVFoundation 实际解码 587 帧，
4096×2502，时长 12.758333s；不把 nominalFrameRate 当作应用帧率。
对应 thread 的只读 SQLite 快照保存在本机私有临时目录；没有连接用户 Runtime，
没有修改用户会话或离线缓存。该 snapshot 是录屏后取得的状态，不能认证为录屏瞬间的逐字版本。

| 画面阶段（实际 PTS，约值） | 录屏内首次打开 | 同 thread 重复打开 |
| --- | --- | --- |
| 首次清楚可见展开纸面 | 1.933s | 6.650s |
| 纸面接近/到达最终几何 | 2.200–2.233s | 6.833–6.867s |
| 标题出现 | 2.500s | 7.150s |
| 多段正文出现 | 2.633s | 7.350s |

即面板已到达目的地后仍约有 0.4–0.5s 的可见正文等待，重复打开仍约相同。
录屏未同步采集鼠标事件、资源 ready、主线程栈或文本 apply，不能把这些帧认定为点击时间，
也不能从视频精确拆出 IO/传输/解码/布局的毫秒占比。录屏内首次也不代表进程首次。
本次负载有多段可见 assistant 正文，与 a64a6ad 调研的单回复＋本地图片负载不同。

## 实现契约

- 外层 workspace 按 route visit＋目标 execution 发起 cancellable read-ahead task，
  只申请 manifest 和插件给出的最多一个 opaque row scope。Codex 根据目标/最新 execution
  生成自己的 row key；Host 不解析 Codex timeline。其他 Harness 默认只预读 manifest。
  预读没有视图构造、主线程会话投影或 Markdown/TextKit 挂载。
- RuntimeClient 最多保留 4 个 ready、已确认的闲置实时订阅，30 秒过期，合计 8MiB
  保守 JSON 存储计费预算。它们持续处理真实 snapshot/patch，增长超预算时淘汰。
  前台容量紧张时先淘汰闲置项；原有 32 个总订阅上限继续生效。
- 释放 consumer 时同步撤销其 ID，缓存取得独立 ID；命中时移交同一 live wire 给新 ID。
  同 scope 同时可见的多个消费者仍各持独立 handle；关闭一个不能撤销另一个。
  只移交 snapshot 和 acknowledgement 均完成的订阅，pending 预读不会移交给 reader；
  预读未赶上挂载时允许正常前台读，而不等待它。
- stream retirement/reconnect、协议 reset、patch gap/error、TTL、容量/预算淘汰会丢弃闲置项。
  reset 在任何 release await 前撤销 freshness；失败 release 沿用生产的 stream retirement。
  被取消的预读移除自己的 handle；迟到 ack 仍会释放已接受的 add，不能向替换路由交付。
- 联网新读/重连/重试先等实时 snapshot；持久 bytes 继续只做离线回退，不能作为联网缓存命中。
- Codex 只缓存成功的 immutable admission，完整 JSONValue（精确 UTF-16）＋createdAt 为 key，
  actor 内串行校验/hash/解码，最多 16 项、8MiB 计费预算；大值可读但不缓存。
  内容变化自然 miss，取消/代次检查防止过期结果交付。没有缓存 error、资源、closure 或导航状态。
- 只读 Markdown NSTextView 设置 `writingToolsBehavior = .none`，避免为程序写入的 transcript
  请求重写能力；原生 selection/copy/link/TextKit 保留。它不启用正文的提前挂载。

计费预算是包含节点/UTF-16/typed DTO 开销的保守估计，不能当作实测 RSS 上限。
活动 reader 的数据与应用原有解析/图片缓存另有其现有所有权；本次不会保留 TextKit view。
历史、显式消息锚点和滚动位置依旧由 fresh reader 与原有 readingTarget/ThreadTimeline 管理，
不会用旧 view 覆盖新请求，也不引入跨 thread/execution 的滚动恢复。

## 隔离真实 reader 的前后观察

生产 Release Core/PluginAPI/PluginUI/Codex 模块，独立 NSApplication，
不激活的 2048×1260 屏幕外窗口；边界供应真实 manifest/turn snapshot，无 Runtime/IO 等待。
每个进程连续三次打开/关闭；8ms run-loop timer 记录最大回调间隔，**不是帧率或呈现延迟**。
沿用生产 NativePerformance 的 text/Markdown spans，没有新增测试 hooks。
截图不在下表计时区间。首次 sandbox 运行的初次正文未挂载，已排除，不能作为快样本。

| 独立进程观察 | 首次包含挂载的最大回调间隔 | 重复 1 | 重复 2 | 最慢 text.replace |
| --- | ---: | ---: | ---: | ---: |
| 基线，第 1 组 | 684.99ms | 73.19ms | 61.27ms | 516.01ms |
| 优化，第 1 组 | 132.80ms | 75.59ms | 73.89ms | 21.75ms |
| 基线，第 2 组 | 114.18ms | 77.93ms | 72.29ms | 26.54ms |
| 优化，第 2 组 | 124.09ms | 51.69ms | 74.23ms | 16.19ms |

另一次带截图的基线首次 text.replace 为 241.69ms；截图污染其他阶段，因此不进入上表。
第一组基线所有 Markdown parse 合计 6.15ms，最慢一次 3.44ms；
第一组优化对应 3.22/1.90ms。数据支持“曾发生显著的首次原生文本替换成本”，
与先前 Writing Tools/dlopen 栈一致，但**不支持稳定 5 倍提速**：第二组基线与优化首次重叠，
系统 dylib/字体缓存、并发构建和用户其他应用均未控制。重复打开依然需要 TextKit 创建/布局，
ready 边界的重复挂载未观察到稳定大幅下降。不能把这些数值用于完整 workspace 的点击响应保证。

## 隔离生产订阅观察与 review

用生产 composition/daemon/transport 和最终 Release RuntimeClient，在 `/tmp` 创建新的
profile＋workspace，仅导入这个已完成 thread。禁用所有 Harness 执行、扩展与在线 context，
没有复用账户配置或启动真实 agent；只读内容仍经过真实生产 renderer、HTTP 和事件流。
Workspace recovery 提示导入副本的 managed-worktree 关系不可恢复、Moku 无可用执行 Harness；
没有执行恢复动作，内容订阅正常。Go 仅做该生产路径 helper/Runtime 构建，没有运行测试。

| 最终 Core 观察：从 open 到 ready 记录 | manifest | row |
| --- | ---: | ---: |
| 冷读 | 14.48ms | 20.92ms |
| 关闭后重复打开 | 0.19ms | 1.34ms |
| 先预读，420ms 后打开 | 0.17ms | 1.34ms |
| 超过 30 秒后打开 | 11.04ms | 20.70ms |

观察程序收到 ready 后编码并计算 SHA-256，再记录时间，因此包括了观察端开销，
不等于纯传输耗时，也不包含视图挂载。冷读、两条预读、过期后两条读以及重连后的两条读
共 8 次新建 wire；重复打开与预读后的消费均无新 content.ack。
这是订阅复用和动画前准备的实际路径证据，**不能认证整机端到端降低同样比例**。
该 helper 手动模拟 420ms 等待；完整 workspace 在真实并发负载下是否能全部预读完成尚未认证。

停止服务后，使用生产 Store API 修改隔离副本的 answer，再重启并订阅 row：
ready 内容从 190986B 变为 191021B、摘要改变，先 loading 再收到新的 snapshot。
没有把重连前的旧 bytes 当成联网 ready。服务已通过正常 stop 退出，discovery 已删除。
多次观察 attempt 的数字不同；提交保留最终 Core attempt 的完整 timing/hash，未引用旧提交结果认证新代码。

人工截图确认生产 reader 的首次与重复挂载仍展示相同标题、正文、布局、工作摘要开关；
截图未放入仓库以免复制用户会话正文。未操作用户正在运行的应用。
本轮没有实跑真实 agent 持续 streaming、复杂历史/fork/显式消息锚点滚动、Sidecards、
IME/焦点、系统 Reduced Motion、所有 Harness 或内存压力；这些边界完成静态 review，
不能把它们写成动态验证通过。预算淘汰、取消中的 ack、reset/patch gap 的并发时序亦以
代码审查为证，没有构造测试 hooks 注入。

本地 review 检查并修正了 ready 与 ack 的双重移交条件、撤销旧 handle 的同步时点、
reset 在 await 前的 freshness fence、取消预读的迟到 ack、独立消费者的资源归属、
过期任务 generation、增长后的预算与前台容量优先。原生 panel driver、ThreadConversation、
ThreadTimeline 和 readingTarget 的原有滚动/锚点实现均未改变。

最终源码完成完整 `Mokusei` Release 构建，Go Runtime 构建完成。
开始复制旧 scratch build 时出现 Clang/Metal module-cache 路径不匹配；清理临时目录内的
module caches 后重建成功，不计作产品失败。没有运行 `make check`、测试、CI 或 hooks。
因此不读取/等待远程合并门禁，也不声称可以绕过它们；交由调用方独立 review/integration。

证据（不含会话原文）：[reader observations](thread-loading-profile/reader-observations.json)、
[最终 live timing/hash](thread-loading-profile/live-observation.json)、
[最终 content spans](thread-loading-profile/live-spans.json)、
[video PTS](thread-loading-profile/frame-timestamps.csv)、
[video 白色纸面横向扫描](thread-loading-profile/video-geometry.csv)、
[构建与输入 provenance](thread-loading-profile/provenance.json)。
扫描在 1024×626 图的 y=500 取 RGB > 0.975 的最长白色区间，只是边缘代理；
图片/文字及纸面未穿过扫描线时会失效，不作为完整矩形检测。
分析源码、原始截图、性能 JSONL 和导入数据仅留在本机 `/tmp/thread-loading-profile/`。

## Local main integration review

The integration retains the later terminal assistant/empty-Hook classification,
OpenCode complete target reply parts, delayed placeholders, and shared Close with
its unfolding hit aperture. Those policies are not part of the cached value:
readers still apply their current presentation state to admitted native data.

Review found an offline-cache ownership edge: an idle patch can be pending in the
400ms disk-save debounce when its retained id transfers or is evicted. Removing
that dirty id would silently discard the pending save. Retiring an idle id now
flushes pending reading bytes first, matching the existing visible-release policy.
This may add existing disk-cache work on a dirty transfer; it is not included in
the source author's isolated timing figures. Offline cache failures remain
best-effort diagnostics and cannot prevent live reading or affect drafts.

The main integration combines final production Release verification with the
following spacing change. No tests, CI, hooks or real Harness traffic are run.
The source timings establish isolated live subscription reuse only; full-window
latency, sustained streaming CPU from whole-JSON budget accounting, decoder
queueing and memory-pressure acceptance remain unmeasured.
