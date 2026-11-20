# Chief coordination

Chief is the assistant’s display and prompt identity. The implementation uses
`moku` for its module, tool namespace, persisted role fields and command names.

[coordinator.go](coordinator.go) owns Moku's conversation, admission queue, saved/applied execution configuration and native handle. [ports.go](ports.go) declares injected Runtime capabilities. Ordinary tasks remain Runtime-owned; Moku coordinates them through admitted tools and lifecycle facts.

Startup recovery prepares native configuration without reserving the settings
admission gate. Runtime verifies the captured source and settings revision before
applying it, so slow catalog discovery does not block a prompt save and a newer
edit wins a recovery race. User input retains the full admission gate through
native acknowledgment; recovery itself never submits a task.
The coordinator's serial queue observes cancellation while waiting, so abandoned
inputs release their claims before a slow owner finishes.
Cancellation of a waiter does not interrupt the admitted owner.

**PBT-MOKU-QUEUE** exercises the production admission queue with 1–8 generated
cohorts of 1–12 waiters and cancellation subsets. A held owner provides a barrier:
cancelled waiters must return before that owner releases, surviving waiters must
enter exclusively, and the same queue must remain usable for subsequent cohorts.
The [property](admission_property_test.go) does not assume FIFO scheduling or set
a user-experience latency budget; its 3s deadline is a deadlock guard.

If an execution ends while preparing its follow-up, Runtime checks saved versus
applied settings before admitting a successor. The coordinator prepares fresh
settings, instructions and context once when Core confirms that no input was
consumed. This covers typed, lifecycle-event and durable outbox inputs. An exact
native `ErrExecutionEnded` can provide that guarantee; wrapped or uncertain
native failures cannot authorize replay or clear an uncertain outbox attempt.

## Tools and creation

[tool_schema.go](tool_schema.go) composes tool schemas from Harness declarations. `create_thread` takes a `target` object with exactly one Harness key containing its native settings. Each Harness has its own named property, so model-facing fields and catalog descriptions retain their ownership even when a host discards root composition keywords. Inclusive property hints expose model/thinking choices only within that Harness; native fields are never merged across targets. The target's union selects a key without validating other Harnesses' options, keeping bounded error output focused on the supplied target. [schema_validation.go](schema_validation.go) and each Harness validate the actual request before execution; the parser decodes the one key into the existing internal Harness/options pair. Before validation, [schema_validation.go](schema_validation.go) repairs one narrow serialization fault: a container that a Harness stringified where the schema declares object/array is decoded, while declared strings, invalid JSON and values hidden behind `$ref`/`$defs` or conditional keywords pass through unchanged so the original schema error still surfaces. The same repair runs again against the native settings schema when `create_thread` resolves its target.

Fixed tool schemas compile once per installed binding and are reused for that
configuration generation. Dynamic target schemas remain freshly discovered and
validated at creation admission.

The Codex Harness additionally places the original injected input schemas in
native developer instructions, so its model can read the complete creation
contract even when native tool-schema conversion drops composition details.
Moku retains the same named-target schema and authoritative validation; Pi,
OpenCode and Claude continue receiving their existing definitions.

[tools.go](tools.go) implements `list_threads`, `create_thread`, `remove_worktree`, `describe_native_harness`, `get_thread_status`, `send_to_thread`, `interrupt_thread`, `ask_thread`, `talk`, `timer` and `update_note`. Tool calls and results are audited under the owning Moku execution; cancellation follows the captured owner. Creation success means the target input was admitted, not that its work has completed. Listing and queries retain bounded, explicit public access. `ask_thread` makes a model request against an ordinary Agent Thread history fork or captured snapshot; it does not return raw history, send a message to the source, or change source state. The snapshot can be stale and is not a live status query. Terminal events arrive automatically; do not poll for progress or readiness.

Tool scopes follow the current Moku Thread's monotonic record revision, not the
arrival order of commit callbacks. A delayed note or metadata notification cannot
cancel a successor's tools or revive a completed execution's scope. Reinstalling
configuration for the same Thread preserves that revision floor; replacement
and restart initialize it from the adopted Thread. Older terminal facts still
settle their own audit rows independently of scope authority.

Tool-operation transcripts are business records, written under the captured Moku
execution. [tools.go](tools.go) assigns host `id`, `callId` and `invocationId` at
insertion, retains the native `harnessCallId` when supplied, and records arguments
and completion results. These identities do not depend on a private log sink.
A callback rejected before transcript insertion has no operation row; its error
returns through the tool bridge. Result-recording failures remain tool faults.

**PBT-MOKU-SCOPE** generates valid execution histories with running, waiting and
terminal observations, then delivers their commit callbacks in arbitrary order
with duplicates. Only the highest observed owner revision may control tools;
superseded contexts are cancelled and stale callbacks cannot revive them.
Same-owner configuration installation preserves the revision floor, while a new
owner establishes its own floor. [The property](scope_property_test.go) calls the
production coordinator transitions, using 1–12 executions and bounded callback
permutations. It checks cancellation authority, not provider I/O, transcript
contents, physical UI interaction or timing. Run `make pbt-go`; seed/evidence
controls are in the [PBT guide](../../../tools/verification/pbt/README.md).


Moku guidance defaults to managed `worktree:true` for tasks in a committed Git workspace, even without parallel tasks. It reserves `false` for tasks without an eligible Git workspace, explicit requests for the existing checkout, or tasks requiring its uncommitted changes or live state. Moku creates the managed worktree through `create_thread` rather than delegating worktree creation to the Agent. This is model guidance, not an enforced boolean default.

Every `create_thread` call supplies `worktree` as a boolean. `false` uses an explicit existing directory or allocates a temporary workspace. `true` requires an explicit committed Git workspace. The result distinguishes base `workspace.cwd` from execution `workspace.worktreeCwd`. Optional `worktreeName` is a directory label, never the task title; [workspace rules](../workspaces/README.md) define validation, normalization, collisions and reported adjustments.

On an explicit cleanup request, `remove_worktree` accepts only the owning ordinary
`threadId`. Its binding uses the current Chief execution scope and records the
call and result in the tool transcript. Success returns `ok`, `threadId` and
the confirmed `absentRoot`. A partial removal reports the retained path or pending write. Retry with the same owning `threadId`. The thread still reports its base `workspace.cwd`
and directory tag. Its former execution directory is available as
`workspace.removedWorktreeCwd`. See the [removal checks](../workspaces/README.md#explicit-removal).

Ordinary tasks require the target Harness's explicit model/thinking choices. Codex also requires service tier. All built-in targets expose their native options in the initial creation schema; Moku does not need an on-demand discovery call to compare Harnesses. Cached discovery is not admission authority. Moku's own concrete execution profile is independent of ordinary task defaults.

Moku uses each selected Harness's nonempty native response inventory for routing.
[Model catalog metadata](../../core/plugin/model_catalog.go) separates completed
enumeration from source completeness: native caches/fallbacks remain usable;
unproven remote completeness remains false. Configuration identity fences reuse,
and actual creation validates native options again. This does not attest remote
source completeness or current execution availability.

See [native catalog evidence and limits](catalog-evidence.md).

Every new execution crosses Runtime's common `admitMokuExecution` boundary:
initial Send, renewal after exact unconsumed `ErrExecutionEnded`, and native
Accept. Typed and relay submissions share Send. The immutable injection captures
the prepared catalog/settings and installs its authority callback before native
Open. The callback is not serialized to tools or instructions. Native new work
during Open is refused until preparation is published, avoiding reentrant lock
acquisition. Background work cannot exempt new foreground executions from saved
configuration or catalog checks. Steering an already admitted execution keeps
its original configuration.

The coordinator's idle checks are preparation optimizations, not authority.
Runtime holds configuration and final admission ownership while deciding whether
to reserve a new execution. It calls the guard before allocating a new execution
ID, native Send or native project/commit. A changed preparation returns the exact
configuration-pending sentinel for one safe reprepare. Other Core rejection
reasons retain an exact `MokuAdmissionRejectedError`; durable notifications can
release their unconsumed attempt without treating wrapped/uncertain native errors
as replay permission. With pending configuration and live background work, input
remains blocked until the old work drains instead of reopening underneath it.

`x-mokusei-model-catalog` carries enumeration and source evidence separately.
Routing accepts a successful nonempty native response inventory for every selected
Harness. Source proof is informational; native cache/fallback is usable without
being called remotely complete. Full inventories remain in the initial standard
tool-schema description; unknown thinking controls restrict creation branches
without hiding identities. Schemas over the 1 MiB budget fail rather than truncate.

A matching successful snapshot returns immediately even when expired or during
refresh. Failed, empty or superseded refreshes do not replace it. Background
failure is retained and exposed as a snapshot note; cold failure reports an error.
Caches are Harness-owned, memory-only and drained on Close. Same-process handle
replacement retains them; application restart reacquires native catalogs.

Routing identity includes the captured launch/environment and observable native
configuration/account inputs. Bounded dependency scanning strengthens the key;
if scanning fails it falls back to root-file generations with a degraded marker.
Cancellation still rejects and a detected source change fences publication.
Arbitrary imports, custom credential helpers and remote/MDM policy are not thereby
proven; unknown provenance does not prevent native inventory routing.
Settings changes still participate in final Runtime admission. No system-prompt
or tool-use instruction is added by discovery; directory data stays in schemas.

Creation resolves the actual destination workspace, discovers its schema again,
validates exact options and performs Harness-native admission. Keychain, remote
account and untracked include-file changes may remain invisible until TTL expiry,
background/manual native-settings refresh or live admission. Cached directories
are explicitly described as potentially outdated, not current availability.
These limitations do not turn
an unknown/empty directory into a complete one.

A successful matching cache hit does not wait for a native catalog fetch. A miss discovers the native inventory rather than rejecting unknown provenance. Host
execution-profile preparation and local launch/dependency resolution remain
separate costs. Native enumeration still has its existing bounds (OpenCode:
30-second native timer and 55-second full probe, plus joined cleanup). Resolving local binaries and checking dependency fingerprints is separate work;
unchanged Codex binary-version facts remain cached independently of catalog TTL.

Both creation/follow-up prompt schemas carry target-routing guidance: explicit
user choices take precedence over general routing guidance and belong under the single Harness key in `create_thread.target`. Moku addresses the receiving Agent
with the actual work and omits only dispatch requirements already fulfilled by
that selection. A target-model choice alone is not a request for a child Agent.
Explicit child-Agent, parallel-work and role requirements, and model names or
quoted instructions meaningful to the task remain part of the assignment.
`send_to_thread` retains the existing target configuration; an unsatisfied routing
choice needs a suitable target or a user-visible explanation, not an instruction
to spawn a replacement child.

This is coordinator guidance across Harnesses, not a semantic runtime guarantee.
The runtime validates native target options and forwards the supplied task text
without model-name or delegation-keyword filtering. It cannot mechanically
distinguish routing intent from task content, and the target's own instructions
or judgment can still cause subdelegation. Existing dispatched tasks and native
histories are not rewritten; updated guidance is injected on session preparation.

## System prompt budget and injection boundary

[DefaultSystemPrompt](prompt.go) names the assistant Chief and covers
coordination, invisible assistant replies and the distinction between information
for Moku itself and information needed by delegated Agent Threads. Count the
complete built-in string by sentence-ending periods, not Go string literals or
lines; it has no abbreviations, URLs or embedded periods.
[Coordinator preparation](coordinator.go) injects that string as its only built-in
`Injection.Instructions` entry, independently of the number of target Harnesses.
`DescribeThreadCreation` supplies tool schemas, not an additional instruction
block or prose target roster. Tool schemas and context remain separate instruction/data boundaries.

The three-sentence budget is **not a cap on the provider's entire model input**:

- In omitted/custom mode, saved `Moku.RoutingGuidance` is appended verbatim as
  user configuration after the built-in prompt and has no sentence cap within its existing settings
  limits; it neither replaces the base nor overrides explicit
  user routing choices.
- Existing tool descriptions and schemas retain their full contracts: exact
  native options and catalog status, routing, worktree naming, Talk/Timer
  limits, note evidence and compare-and-swap rules, and bounded Thread queries.
  Their size is independent of the three-sentence base-prompt budget.
- `ContextEntries` contain session-start workspace context and before-send note,
  directory, telemetry, evaluation and notification context, including runtime
  interpretation/safety guidance and variable user or native text; they have
  their own size limits and no sentence cap.
- Runtime passes the injection through `OpenMokuThread` to the native Harness:
  Codex `composeInstructions`, Claude `systemPrompt`, Pi `bridgeConfig` and
  OpenCode `Configure` compose it with context and, where needed, historical
  seeds or restoration guidance. Depending on the adapter, subsequent context
  travels in messages or native system configuration, so even without routing
  guidance the complete native system/developer payload can exceed three sentences.
- Native engines/providers may supply their own system instructions, workspace
  instructions or session history outside this Moku coordinator budget.

Talk/Timer limits, Note evidence, native options and worktree naming live in
their tool contracts. The three-sentence base prompt does not duplicate those
contracts. Native session preparation injects current guidance; stored native
history retains its original messages.

## Talk and notes

The built-in prompt states that Moku's own assistant replies are invisible.
Visible surfaces remain Talk, Timer, the persistent note and ordinary Agent
Threads, including Moku's delegated instructions; their detailed usage lives in tool contracts. Anything the user needs to know or respond
to must reach a visible surface: Talk for short
immediate answers, questions, confirmations and updates; the note for persistent
milestone recaps; and the relevant Agent Thread for detailed task discussion and
deliverables.

`talk` accepts only nonblank `text`, without NUL, up to **160 Unicode code points**, including whitespace/newlines. Rejection does not truncate or overwrite a successful message. The UI derives display identity from the audited operation, not from arbitrary model prose. Code-point budgets are independent from the UI's four-line reading viewport. Each Talk message bubble is visible to the user for about one minute and automatically hides after 60 seconds. [prompt.go](prompt.go)'s shared `TalkTextPolicy` supplies this visibility guidance to the registered tool and parameter descriptions, the built-in Moku prompt does not duplicate that policy. Use `update_note` for the persistent milestone recap; Talk messages are not copied into the note.

`timer(text)` is an immediate, one-time communication tool alongside `talk`.
It uses the same closed text-only envelope, **160 Unicode code-point** budget,
nonblank/NUL validation, exact-text preservation, and audited completion path.
The tool returns `{ok:true}` after its completion audit commits, without waiting
for a user receipt. Success means the operation was accepted, not proof that a
client displayed it, audio was audible, or the user acknowledged it. Only the UI
can acknowledge; there is no confirmation tool, scheduler, date/duration input,
reminder CRUD or reminder table. The tool describes its audible nature;
ordinary Talk remains silent and expires automatically as before.

The native workspace queues successful Timer operations by owner, Harness,
execution and audit operation identity. Talk cannot replace queued Timers.
The catalog retains a catch-up tail of the latest 256 completed successful Timer
operations across executions, in addition to the usual current-execution preview.
This prevents a rapid successor/coalesced publication from hiding a completed
Timer; it is a bounded projection of existing audit rows, not a durable delivery
queue. See the [native Timer contract](../../../app/macos/Sources/Host/MokuScene/README.md#immediate-timer)
for startup, disconnection and audio limitations.

Talk and note text guidance encourages emoji when they naturally add expression
and suit the context; emoji remain optional and count toward the existing
Unicode code-point budgets.

`update_note` requires `text` and an `expected` basis containing `noteId`,
`revision`, and `readingRevision`; `expected:null` applies only before the first
note. Text allows **1200 Unicode code points**. Exactly `""` clears it; other
whitespace-only or NUL-containing values fail. A matching transaction returns
`{ok:true,state}` with the committed note and evidence. A changed basis returns
`{ok:false,code:"note_state_changed",state}` without writing, so Moku can
reconsider. The owner Thread is fenced in the transaction, including after a
history reset. Host replacement preserves the note and its one exact old-text
exposure; clear revokes exposure but retains the incarnation.

[context.go](context.go) adds a bounded JSON note state before every outgoing
Moku input, including user and task-event paths. An absent or cleared note
is explicit. It carries the current text, basis and at most one exact exposed
earlier version. The evidence is presentation, not approval; useful decisions,
constraints, unresolved work and pending review remain eligible for the recap.
The state is not copied into the transcript. Talk supplies short immediate
updates. The [Dock](../../../app/macos/Sources/Host/MokuScene/README.md) owns
presentation and viewport evidence collection.

## Context

Moku collects registered [Context contributions](../../hosts/contexthost/README.md) at their declared hooks. Harness-native model/account facts retain their owners.

Outgoing workspace context reads the Thread catalog only when a directory tag
needs resolving. Explicit directory mentions and inputs without a directory tag
do not load unrelated Thread histories.

## Durable system notifications

Ordinary Thread terminal transitions write a Moku outbox entry in the same SQLite
transaction as the observation. The coordinator drains it at startup and once per
second, retrying failures before native Send (including unavailable configuration
and pending user interaction). Admission removes the entry durably; metadata
updates do not create duplicate deliveries. Thread deletion and history reset
remove their pending facts. Native admission is not proof of task completion.
When this outbox is available, ordinary terminal commits bypass the in-memory
event queue and its duplicate tracking. Configurations without the outbox retain
the live notification path. Already queued Moku terminal audit settlement stays
local and drains during shutdown.

For an acknowledged user Stop, the terminal notification includes the same
lifecycle `event.source` field as a direct input, with value `user`.
The `thread.interrupt-acknowledged` event identifies the child in
`event.subject.id` and the interrupted execution in `event.data.executionId`.
The terminal observation retains its native status. Without an acknowledged
user Stop, the terminal notification omits this event. A live-only coordinator
receives the same acknowledgement as a separate execution-specific notice.

Direct user input to an ordinary Thread writes a **lazy** system notification in
that input's successful admission transaction. Idle Moku keeps it queued without
starting an execution. The next ordinary Moku input (typed input or a
wake-producing terminal fact) carries pending lazy notifications as separate
system context, preserving the original user input and its transcript. The shared
notification formatter preserves the direct-to-thread warning: the child has
already received this input; Moku must neither resend it nor treat it as a new
request addressed to itself.

While an execution is active, the outbox poll can deliver lazy notifications as
internal follow-ups on Harnesses advertising safe `FollowUpOnly` steering. Codex
supports this. Claude, Pi and OpenCode keep them queued for the next independent
input because their native protocols cannot prove atomic active-only admission. Core rechecks active admission and never reserves a successor
for a lazy-only send, even if native Send reports that the execution just ended.
Such a confirmed unconsumed notification returns to the queue. Waiting-for-user,
configuration and preparation failures also retain pending work. Lazy delivery is
not a wake source; ordinary terminal notifications retain their existing wake
behavior. Production uses the durable outbox rather than the live user-input
subscription, so restart and subscriber timing cannot lose accepted facts.

A transaction-owned sequence orders multiple notifications. Each send captures a
batch; its attempt transaction fences all selected identities, and its admission
receipt removes exactly that batch. Stale polling snapshots cannot resend an
already bundled notification. Inputs committed after the snapshot remain queued
for an active follow-up or the next independently triggered execution. Thread
deletion and full history reset remove queued notifications; changing Moku's
Harness preserves them for its replacement conversation.

Before entering native Send, Runtime persists an
uncertain attempt for the selected batch. A transport
failure or crash in this interval cannot prove whether the provider consumed the
notification, so these entries are retained and never automatically replayed.
A later run failure does not replay an already admitted
notification. Admission proves retention, not that the model read or acted on it. Use authenticated
`moku:deliveries` with no arguments to inspect pending facts. Restart the runtime
to fence the old native workers, inspect the native conversation, then invoke
`moku:resolve-delivery` with one object containing `id` and `decision`:
`retry-confirmed-unadmitted` only after confirming non-admission, or
`acknowledge-confirmed-admitted` after confirming admission. Decisions are audited;
the current runtime cannot reconcile its own uncertain attempts. Exactly-once
provider effects cannot be guaranteed without provider idempotency support.

Uncertainty is operator-visible through the authenticated Runtime command API. It is not published as Talk, a client error
banner or a recovery button, and these commands are not Moku tools. Invoke
`moku:deliveries` with `args: []` to inspect retained entries. After restarting
the Runtime and checking the native conversation, invoke `moku:resolve-delivery`
with `args: [{"id":"<delivery id>","decision":"retry-confirmed-unadmitted"}]`
or the same object with `acknowledge-confirmed-admitted`. Use the normal
authenticated `/invoke/<channel>` transport and durable command receipts; a lost
resolution response is queried by its command ID, not blindly resubmitted.

A confirmed retry only makes the entry eligible again: a lazy entry still does
not wake an idle Moku and needs the next independent trigger or supported active
steering. Acknowledgment retires the entry; it does not prove the model processed
it. If native evidence cannot establish admission either way, retain uncertainty
and escalate for manual inspection. Restart alone does not resolve or replay it.
The old native workers must actually be stopped before reconciliation; a failed
shutdown is not a successful restart. No real-profile reconciliation is performed
as part of local code integration.

Overview directory context carries `directoryScopeId`, the stable host-derived scope identity. Display tags never resolve a selected directory by basename. Explicit directory mentions still take precedence; an unresolved selected scope reads one catalog snapshot and includes only directories in that scope.

A coordinating-Harness change starts its required new native session and preserves the prior session as read-only `mokuHistory`. Its original Harness keeps ownership of the opaque conversation representation; Moku does not merge native formats. An explicit history reset removes the current conversation and these prior sessions.

Cross-Harness memory consists only of the existing note. Replacement copies its
exact state, and the next outgoing input includes it through the ordinary note
context path. Empty notes stay empty. Switching does not request compact or
generate a summary. Runtime requires idle ordinary tasks and Moku both when
saving a different Harness preference and when replacing the native owner;
unrelated configuration edits keep their existing admission behavior.

Notes can contain `[label](mokusei://execution?threadId=THREAD_ID&executionId=EXECUTION_ID)`
to reference one ordinary Agent Thread execution. Moku obtains the two identities
from thread lifecycle reports; this capability adds no query tool or reason to
query proactively. Capability guidance leaves link selection to the model. The
full Markdown URL counts toward the existing 1200-code-point limit.

The `interrupt_thread` tool attempts every supplied Thread ID in order, including
repetitions. Each result carries `threadId` and `ok`. Runtime's acknowledged
stop yields `ok: true` and `status: "cancelled"`. A finished target with no
remaining work, or a stop already in progress, yields `ok: false`,
`status: "stale"` and an explanation. A missing or ineligible Thread and a
native error yield `ok: false` and an error. Batch `ok` is true only when all
attempts succeed. The compact catalog carries this batch acknowledgement.
The dedicated `InterruptThreadFromMokuTool` capability also lets Runtime
retain the exact interrupted execution when observed. User Stop and lifecycle
teardown have their own entry points. [Runtime cancellation](../../core/runtime/README.md)

`grep_threads` is an admitted, audited deterministic read, distinct from the
model-based `ask_thread`. Runtime limits it to current-profile ordinary Agent
Threads, including archived threads by default. It supports literal/RE2 searches,
body/title selection and intersecting thread-ID/Directory-Scope filters. Follow
`nextCursor` even when a page has no hits; missing coverage is explicit and must
not be presented as proof that native history contains no match. Returned snippets
are untrusted conversation evidence and may contain sensitive user-authored text.
See [grep defaults, bounds and pagination](../threadsearch/README.md#moku-deterministic-grep).
It is not a progress-polling capability.
Invalid grep patterns and cursors remain caller-correctable errors through the
existing tool audit/bridge, while cancellation and Runtime faults remain faults.

## Super Thread send source

A user submit may carry `superThreadId`, a document identity, never a client HTML
payload or a replacement destination. The coordinator asks the application host
for `report.context` at admission and still sends to Moku. That snapshot includes
the complete current report, only its same-scope ordinary Thread identities and
workspaces, current execution state and separately resolved referenced execution
facts. Missing facts and legacy binding counts are explicit. Report content and
summaries remain untrusted evidence. Source resolution failure preserves the draft
and prevents a context-free send. Inputs without this identity explicitly clear
previous Super Thread source context; no catalog/history enumeration is added to
ordinary user submits. Lifecycle delivery and model discovery are unchanged.

## Model routing preferences

`routingPreset` selects economy, balanced or performance guidance. Omitted/custom
uses the existing `routingGuidance` unchanged. Explicit custom is persisted even
when empty; without a preset or manual text the balanced base policy applies.
Presets never overwrite the user's
retained manual text or Moku's own execution model. Economy prioritizes
cost-effective models; balanced adds no routing guidance, retaining only the
already-injected three-sentence base prompt and existing tool contracts, as the
default did before routing presets. It neither duplicates the base prompt nor
injects retained custom text. Performance prioritizes frontier capabilities even
for routine tasks. These are general priorities, with
no fixed model mapping, candidate groups or preset-specific admission restrictions.
Native creation schemas and admission still own available model choices.

[routing_preferences.go](routing_preferences.go) generates the guidance solely from
settings. The coordinator appends nonempty guidance after the base prompt with the
`Model routing guidance:` prefix. Explicit user Harness/model/thinking choices
still take precedence through the creation/follow-up tool contracts.

## E2E preparation

The [desktop interaction runner](../../../tools/e2e/README.md) prepares
`E2E-READ-001` by submitting through public `moku:submit`. A deterministic
loopback Responses peer requests the real injected `create_thread` tool through
the real Codex CLI. A fresh profile and usable native model/default directory
are prerequisites; Report/Tag and other Harnesses are disabled through public
settings. Tool admission alone does not establish completion: preparation waits
for the public terminal execution and checks exact output through a scoped
content subscription. `creation.json`, `initial-content.json` and
`initial-oracle.json` retain these facts. This is setup for UI interaction,
not a Moku property suite or evidence of real provider/model behavior.
