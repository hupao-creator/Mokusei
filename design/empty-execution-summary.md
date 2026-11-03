# Empty execution summaries in Agent detail

## Evidence and root cause

The reported screenshot is the Codex thread “统一阅读卡片左上角关闭按钮”.
A read-only query of the local development SQLite record identified thread
`988e00cf-fe5a-4b0c-aab3-20565286d9f7`. Its first execution was still running at
inspection. After the hidden user message, its first two timeline entries refer
to completed `session-start` and `user-prompt-submit` Hook activities. Both have
only identity, `kind: hook`, `label: 运行 Hook` and `status: completed`; neither
has detail/output, a tool-call marker, reasoning or an interaction. The next
entry is the settled assistant paragraph visible in the screenshot. Later
execution work contains actual commands and reasoning.

These Hooks are real lifecycle records, not synthetic placeholder rows. In a
full reader their nodes contain the Hook label and completed state, with no
output to disclose. In ordinary Agent detail, the existing policy mounts only
`ThreadExecutionProcess.summaryRow`: Hook labels, commands, thinking bodies and
detail loaders do not mount. Thus this particular first group has nothing
beyond its generic “执行过程” heading. Clicking it does not load hidden Hook
content in Agent detail. The independent full/Moku reading presentation retains
its existing activity groups, disclosures and deferred detail loaders.

`CodexTurnRows` groups the activities and supplies zero tool calls because
Hooks are not tools. `bindThreadExecutionSource` supplies native execution
membership. `partitionExecutionRows` joins adjacent execution work, while an
assistant reply separates the two groups shown in the screenshot.
`14f510c` (“Show only execution summaries in Agent Thread detail”) removed
the member/detail rendering in Agent detail while leaving unconditional group
headings in place. `groupThreadExecutionRows` previously created a summary for every such run,
even when the native reader had no useful content to summarize. An empty
Codex/Claude reasoning record could likewise create an empty disclosure and a
bare heading. This is not evidence that every Harness or every first row is
empty; deleting by position or by zero tool count would remove real work.

## Presentation contract

`ThreadExecutionSummary.hasContent` explicitly classifies known empty records.
Its default is true; absent summaries and unknown record kinds also keep their
existing presentation. Bindings copy the complete summary without changing
native IDs or membership. Agent detail omits an execution group only when all
members explicitly report no content and the group has no valid positive
reported reasoning usage. Zero usage alone does not create a summary; existing
zero-usage formatting remains available on otherwise admitted groups.

Codex and Claude classify these records as empty:

- Reasoning with neither non-whitespace content nor deferred content presence.
- A completed Hook with neither output nor deferred output presence, and no
  native tool name/call evidence. Hook names and successful lifecycle status
  alone are bookkeeping in the summary-only Agent reader.

Running, failed and cancelled Hooks remain visible, even without output.
Hooks with actual output or tool evidence remain admitted. Commands, file
changes, tools, agents, other activities and unknown events keep the conservative
default, including zero-count records. Approval/question interactions,
independent errors, reviews, compaction and background status retain their
existing rendering and actions. Mixed groups retain their useful reasoning/tool
counts; reported reasoning usage remains on its existing last native group.
No canonical records, native events or stored history are deleted.

The classifier runs for every render rather than latching an initial result.
An empty reasoning body becomes visible when content arrives; a running Hook
can disappear on successful no-output completion; output or failure keeps it
visible. A tool/request added later retains its existing identity and action
path. Filtering happens after native partitioning, preserving source identities
and boundaries rather than shifting IDs to whichever row is first afterward.

## Harnesses and history

Codex and Claude lightweight deferred content strips activity detail. Their Go
projections now record nonempty `detail` by native activity ID in the existing
`nonempty` presence list before stripping it. Swift distinguishes deferred output
from truly empty output without fetching the full detail. Both turn activities
and Claude inherited timeline activities receive this treatment; duplicate
presence facts are idempotent in the existing presence set. Failed activity
bodies retain their previous projection policy. No new wire schema or state
migration is required; stored canonical data is projected again on reading.

Claude current turns, fallback activities, fallback reasoning and inherited
history all supply the classification. Codex current/history/fork turns share
`CodexTurnRows`. Full readers keep the original groups and loading even if the
summary metadata classifies a record as empty.

Pi already admits thinking only with content or presence. OpenCode already
filters empty reasoning parts by text/presence, including child sessions.
Neither supplies the new explicit empty classification, so their real tools,
child-session summaries, replies and interactions keep their existing behavior.
The shared default does not treat zero counts as proof of emptiness.

## Compatibility with 957740f

`957740f` (“Hide terminal interim assistant replies in Agent detail”) changes
terminal assistant classification and message anchors in some of the same Swift
files. This change does not modify assistant classification or anchor admission.
An interim assistant row folded into work by that commit has no explicit empty
summary and therefore remains execution work; the real row is not deleted even
when its reasoning/tool count is zero. A nearby no-output Hook cannot suppress
it. Explicit message visits and pending requests retain the other commit's
admission policy.

A temporary Git index based on `957740f` accepted this change with
`git apply --cached --3way` without conflicts. No branch, shared ref or working
checkout was changed. An initially considered redundant OpenCode call-site edit
conflicted with that commit's child-anchor change; that edit was removed because
OpenCode has no new empty-classified rows. The final patch needs no OpenCode edit.
This is static integration evidence, not an integrated build or runtime check.
Future changes to summary aggregation must carry `hasContent` alongside counts
if they start wrapping these classified rows in another execution summary.

## Validation and limits

Sprint scope: no tests added or run, no historical replays, no CI, no hooks,
no push or PR. Inspection used the supplied screenshot and a read-only local
record query, source review of all four Harnesses, native grouping/deferred
loading/action paths, and diff whitespace checks.

The first `make build` was blocked by sandbox access to the Go cache. The
authorized build then compiled and linked the Release product (250.67 seconds),
but its input-stability guard rejected that attempt because source edits had
continued during compilation. It was not counted as a passing build; the final
stable-source `make build` passed: Go Runtime and arm64 Swift Release were
built, the Swift incremental build took 78.15 seconds, and the input-stability
guard passed. The executable is at
`app/macos/.build/arm64-apple-macosx/release/Mokusei`. This is a production
configuration build, not a signed packaged-app acceptance run. `git diff --check`,
Go formatting inspection and the new README link check also passed. No live
UI replay or visual acceptance is claimed. Static reasoning covers running,
waiting, completion/failure/interruption, history/fork/deferred output and late
content, but it is not runtime certification of those scenarios. Conservative
classification intentionally retains unknown events and nonempty Hook details,
even if some details are only verbose native metadata. No-output Hook failures
still have the existing generic summary in Agent detail; this change does not
introduce a new diagnostic disclosure policy.

## Local main integration review

The final integration preserves fe16a6a's terminal assistant policy and OpenCode
whole-target reply parts. Only the shared README conflicted; both placeholder
and empty-group contracts are retained. No other worktree was modified.

Two additional boundary corrections were required. Codex hook/completed records
serialize their run object into detail: a JSON object containing only matching
id, completed status and an absent/empty/matching name is lifecycle metadata,
not output. The native classifier and Go deferred-presence classifier agree on
this narrow case. Malformed JSON, mismatched identities, unknown fields and
actual output remain conservative; canonical/full detail is retained.

Claude inherited activities intentionally have no embedded activity id. Their
output-presence marker uses the enclosing timeline item's stable id, matching
the native inherited classifier. Otherwise all inherited output would share
the empty id and could keep unrelated empty Hook groups visible. Current-turn
activity identities retain their existing behavior.

Sprint validation uses production builds, Go vet/format/boundary checks and
manual isolated fixture windows, without tests, CI, hooks or native Harness
traffic. Actual results and limits are recorded with the integration report.
