# Public models and validation

Public DTOs, command schemas and validation live in this package. Native session state remains owned by each Harness.

- `model.Object` 用于动态 JSON 对象；`model.Decode` 使用 `json.Number`，避免原生长整数在 Go 中转时变成 `float64`。
- `SessionRecord.SessionState`、Harness settings、metadata 和 application record value 使用 `json.RawMessage`。读写边界复制这些字节；接收方不得修改共享权威状态。
- Harness 解释自己的原生会话。Core 只读取 `PublicObservation`、身份、时间和配置边界。
- Catalog 中只放 `SessionStateAdapter.ProjectRenderer(..., {Kind:"overview"})` 的有界投影。完整 turn/execution 内容通过独立订阅按需提供。
- `RuntimePlugin` 只投影插件 key、当前启用状态和不可用原因，供原生执行权限与内容可用性判断；不提供插件管理页专用的名称或分类。
- `model.ParsePublicAgentInput` 拒绝客户端提供附件路径；附件 ID 先由 Core 解析、验证并保留 owner，再交给 Harness。媒体和 annotation URL 采用 WHATWG 解析；域名拒绝解码后只有 ASCII 的 Punycode 标签，正常国际化域名仍受支持。
  解析后的规范化 URL 进入可信输入；批注的附件边界继续采用同一 WHATWG 解析规则，避免后续解析器拒绝合法的 URL 路径或重新解释原始写法。
- `ParsePublicObservation`、`ParsePublicExecution`、响应 DTO 的严格 JSON 解码及 `ValidatePublicInteractionAnswers` 处理公开交互边界。字符上限沿用 UTF-16 单位。表单 regex 使用 ECMAScript 规则和有限匹配时间。

Public form preflight also produces internal typed native values, including active
defaults. Runtime passes those values to the Harness without reinterpreting the
original numeric text. Client JSON cannot supply this trusted handoff. Free text
remains literal even when it begins with an internal option-ID prefix; advertised
choice membership is enforced separately.

Source: [commands.go](commands.go), [command_validation.go](command_validation.go), [validate.go](validate.go), [records.go](records.go), [state.go](state.go). The authenticated wire version belongs to [transport](../../platform/transport/README.md).

Verification: `./scripts/go.sh run -race ./tools/verification/command-boundaries` from the repository root.

`ThreadNote` carries `readingRevision` and one server-owned `lastExposure` snapshot.
An exposure is evidence that the exact nonempty revision completed foreground
viewport coverage; it does not assert attention, understanding or approval.
`moku:record-note-exposure` is a write command with one closed object containing
`noteId` (UUID), positive safe `revision`, and the sole signal
`complete-viewport-coverage-v1`. Validation rejects client text, timestamps,
extra fields and out-of-range numbers before Runtime admission.

`harness:detect-installation` is a read-only command with one bounded Harness ID
string. It returns that Harness's installation facts independently. The existing
zero-argument `harness:detect-installations` command remains explicit environment
refresh and batch recovery.

`moku:submit` admits an optional host-derived `directoryScopeId` alongside the
display-only `directoryTag`. The scope must be nonempty, at most 4096 UTF-16 units
and contain no NUL; a display tag never identifies a selected directory.

`ThreadRecord.mokuHistory` marks an archived, read-only conversation retained when the coordinating Harness changes. It retains the original Harness payload and transcript but no Moku note; Runtime forbids execution, fork and unarchiving. Current Moku identity remains singular.

Native string default admission and public answers share `ValidatePublicQuestionString`: UTF-16 length, ECMAScript patterns (including all four dot line terminators), email shape, WHATWG URI and date formats. Date-time accepts signed expanded ISO years and JavaScript Date.toString offset/comment forms; unknown legacy timezone abbreviations are rejected.
