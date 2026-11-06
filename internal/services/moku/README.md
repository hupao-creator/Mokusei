# Moku coordination

[coordinator.go](coordinator.go) owns Moku's conversation, admission queue, saved/applied execution configuration and native handle. [ports.go](ports.go) declares injected Runtime capabilities. Ordinary tasks remain Runtime-owned; Moku coordinates them through admitted tools and lifecycle facts.

Startup recovery prepares native configuration without reserving the settings
admission gate. Runtime verifies the captured source and settings revision before
applying it, so slow catalog discovery does not block a prompt save and a newer
edit wins a recovery race. User input retains the full admission gate through
native acknowledgment; recovery itself never submits a task.
The coordinator's serial queue observes cancellation while waiting, so abandoned
input and voice preparation release their claims before a slow owner finishes.
Cancellation of a waiter does not interrupt the admitted owner.

If an execution ends while preparing its follow-up, Runtime checks saved versus
applied settings before admitting a successor. The coordinator prepares fresh
settings, instructions and context once when Core confirms that no input was
consumed. This covers typed, lifecycle-event and durable outbox inputs. An exact
native `ErrExecutionEnded` can provide that guarantee; wrapped or uncertain
native failures cannot authorize replay or clear an uncertain outbox attempt.

## Tools and creation

[tool_schema.go](tool_schema.go) composes tool schemas from Harness declarations. Inclusive property hints expose choices from closed union branches without replacing their exact validation. [schema_validation.go](schema_validation.go) and each Harness validate the actual request before execution.

Fixed tool schemas compile once per installed binding and are reused for that
configuration generation. Dynamic target schemas remain freshly discovered and
validated at creation admission.

[tools.go](tools.go) implements `list_threads`, `create_thread`, `describe_native_harness`, `get_thread_status`, `send_to_thread`, `interrupt_thread`, `read_thread`, `talk`, `timer` and `update_note`. Tool calls and results are audited under the owning Moku execution; cancellation follows the captured owner. Creation success means the target input was admitted, not that its work has completed. Listing and reads retain bounded, explicit public access.

Production tools also use the shared [private invocation journal](../../platform/diagnostics/README.md).
Transcript operations keep host `callId`/`id` meanings and additionally carry
`invocationId` and `harnessCallId` for correlation. Callback-entry failures before
transcript insertion are journaled, with explicit coverage and payload limits.
Journal retention/redaction is independent of conversation history.

Moku guidance defaults to managed `worktree:true` for tasks in a committed Git workspace, even without parallel tasks. It reserves `false` for tasks without an eligible Git workspace, explicit requests for the existing checkout, or tasks requiring its uncommitted changes or live state. Moku creates the managed worktree through `create_thread` rather than delegating worktree creation to the Agent. This is model guidance, not an enforced boolean default.

Every `create_thread` call supplies `worktree` as a boolean. `false` uses an explicit existing directory or allocates a temporary workspace. `true` requires an explicit committed Git workspace. The result distinguishes base `workspace.cwd` from execution `workspace.worktreeCwd`. Optional `worktreeName` is a directory label, never the task title; [workspace rules](../workspaces/README.md) define validation, normalization, collisions and reported adjustments.

Ordinary tasks require the target Harness's explicit model/thinking choices. Codex also requires service tier. All built-in targets expose their native options in the initial creation schema; Moku does not need an on-demand discovery call to compare Harnesses. Cached discovery is not admission authority. Moku's own concrete execution profile is independent of ordinary task defaults.

Every new Moku task requires a complete, nonempty model inventory from **every
selected target**, before the native model receives the input. Target discovery
runs concurrently (at most four probes) during session preparation, including
asynchronous startup recovery. It does not use the configured default model as an
availability gate. Missing, disabled, failed, empty or incomplete targets block
preparation with a named error; they are never silently removed from routing.
Each native schema has a 1 MiB budget; size/validation failures block preparation
instead of truncating the inventory. Large complete catalogs increase input tokens. Automatic deliveries remain pending and user submissions receive the
failure; no task input is sent on that attempt.

Harnesses attach `x-mokusei-model-catalog` as internal completeness evidence to
creation schemas, using `plugin.ModelCatalogSchema` only after a full native read.
Moku requires that evidence. The complete model inventory is also serialized in
the standard schema description, so native serializers cannot drop it as an
unknown extension. The extension is removed when composing the actual tool schema.
Inventory includes models with unknown thinking controls or known restrictions;
creation branches remain limited to supported choices. Partial **capabilities**
are distinct from a partial **inventory**, which cannot start a task. Native
catalogs cannot prove provider credentials, quota or future execution success.

Before each new task, configuration fingerprints and adapter TTLs govern
cache reuse. This implementation refreshes expired entries and blocks on failure;
it does not use expired fallback entries, even though an intact older directory
would be permitted. There is no persisted catalog fallback across app restarts.
A changed configuration requires its own complete catalog. Changes to selected
Harnesses, tracked native files or enablement during discovery reject the result.
Changed schemas reopen the native session with preserved history; failed refresh
never authorizes a new task through the old session. Running work retains its
admitted configuration, including steering within that execution. Native voice validates catalogs before input admission and
uses the confirmed-unconsumed reconnect path for changed tools; active native work
blocks reconfiguration rather than allowing new input with changed catalogs.

Creation resolves the actual destination workspace, discovers its schema again,
validates exact options and performs Harness-native admission. Keychain, remote
account and untracked include-file changes may remain invisible until TTL expiry,
manual native-settings refresh or live admission. These limitations do not turn
an unknown/empty directory into a complete one.

OpenCode cold preparation waits for the complete shared catalog/account-filter
flight: native discovery has a 30-second cancellation timer, the whole probe a
55-second budget, and cleanup is joined. This can delay first input; application
startup itself does not synchronously wait. Fresh five-minute entries and in-flight
warmups are reused. The four Harnesses are read concurrently, not serially. Model
inventory and creation rules stay in tool schemas, never in Moku, Tag or Report
system prompts or dynamic system instructions.

Both creation/follow-up prompt schemas carry target-routing guidance: explicit
user choices take precedence over general routing guidance and belong in the target's `harnessId`/`options`. Moku addresses the receiving Agent
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

[DefaultSystemPrompt](prompt.go) contains exactly three English sentences covering
coordination, invisible assistant replies and the distinction between information
for Moku itself and information needed by delegated Agent Threads. Count the
complete built-in string by sentence-ending periods, not Go string literals or
lines; it has no abbreviations, URLs or embedded periods.
[Coordinator preparation](coordinator.go) injects that string as its only built-in
`Injection.Instructions` entry, independently of the number of target Harnesses.
`DescribeThreadCreation` supplies tool schemas, not an additional instruction
block or prose target roster. No removed instructions are relocated into context,
tool descriptions or another Agent's prompt.

The three-sentence budget is **not a cap on the provider's entire model input**:

- Saved `Moku.RoutingGuidance` is appended verbatim as user configuration after
  the built-in prompt and has no sentence cap within its existing settings
  limits; it neither replaces the base nor overrides explicit
  user routing choices.
- Existing tool descriptions and schemas retain their full contracts: exact
  native options and catalog status, routing, worktree naming, Talk/Timer
  limits, note evidence and compare-and-swap rules, and bounded Thread queries.
  Those contracts already existed separately and are unchanged by this budget.
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
  instructions or session history; separate voice frontend/relay instructions
  are also outside this Moku coordinator budget and remain unchanged.

Detailed wording about character budgets, emoji, Talk expiry and layout, note
compaction/evidence, native options and worktree names is no longer duplicated
in the base prompt; its existing tool contract remains authoritative. The base
omits detailed channel selection, target routing, worktree rules, dispatch
confirmation, terminal-event waiting and the reminder that Runtime handles voice
delivery; existing tool guidance is unchanged, not expanded to absorb removals.
Tag, Report, ordinary Agent instructions and shared Harness serializers are unchanged.
Updated guidance takes effect when a Moku native session is prepared; existing
native histories are not rewritten.

## Talk and notes

The built-in prompt states that Moku's own assistant replies are invisible.
Visible surfaces remain Talk, Timer, the persistent note and ordinary Agent
Threads, including Moku's delegated instructions; their detailed usage is no
longer enumerated in the base prompt. Anything the user needs to know or respond
to must reach a visible surface: Talk for short
immediate answers, questions, confirmations and updates; the note for persistent
milestone recaps; and the relevant Agent Thread for detailed task discussion and
deliverables. Runtime voice delivery remains separate.

`talk` accepts only nonblank `text`, without NUL, up to **160 Unicode code points**, including whitespace/newlines. Rejection does not truncate or overwrite a successful message. The UI derives display identity from the audited operation, not from arbitrary model prose. Code-point budgets are independent from the UI's four-line reading viewport. Each Talk message bubble is visible to the user for about one minute and automatically hides after 60 seconds. [prompt.go](prompt.go)'s shared `TalkTextPolicy` supplies this visibility guidance to the registered tool and parameter descriptions, including coordination reached through voice; the built-in Moku prompt does not duplicate that policy. Use `update_note` for the persistent milestone recap; Talk messages are not copied into the note.

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
Moku input, including user, task-event and voice paths. An absent or cleared note
is explicit. It carries the current text, basis and at most one exact exposed
earlier version. The evidence is presentation, not approval; useful decisions,
constraints, unresolved work and pending review remain eligible for the recap.
The state is not copied into the transcript. Talk supplies short immediate
updates. The [Dock](../../../app/macos/Sources/Host/MokuScene/README.md) owns
presentation and viewport evidence collection.

## Context and voice

Moku collects registered [Context contributions](../../hosts/contexthost/README.md) at their declared hooks. Harness-native model/account facts retain their owners.

Outgoing workspace context reads the Thread catalog only when a directory tag
needs resolving. Explicit directory mentions and inputs without a directory tag
do not load unrelated Thread histories.

[voice.go](voice.go) owns media leases and device/owner fencing. A Codex Moku uses its native voice capability and fails if unavailable; it does not fall back to a relay. Other hosts use the Codex relay with their normal target admission. Preparation adopts a saved host preference first; its own service admission is not treated as competing work for that replacement. Ending Moku media leaves already admitted task work running. Typed dispatch and accepted handoffs fence old delivery; caption fragments do not create a new task generation. See [Codex voice](../../plugins/harness/codex/README.md#voice) and the [native media client](../../../app/macos/Sources/Voice/README.md).

Relay requests still waiting for target admission belong to the media lease and
leave the queue when that lease ends. Once admission begins, the service owns
the request independently of media cancellation.

Relay media belongs to the Moku conversation and survives same-owner model,
routing and target-schema changes. Reopening the task engine retains the media
identity and exact spoken-result ownership. Native media belongs to its native
handle; replacing the Moku Thread or explicitly stopping voice still retires
media and waits for cleanup.
Before reopening a same-owner handle, Moku captures pending terminal replies
from that handle. Delayed terminal handling can therefore deliver the exact
native reply after replacement, rather than losing it or substituting a summary.

Native voice does not admit a new task with pending execution configuration.
The authenticated owner can continue its existing call through configuration
reconnection. A captured handoff is eligible for automatic resubmission only
when the adapter confirms that no Core execution or injected tool was admitted
and the retired native process has drained. Cleanup failure, explicit media stop
or lost ownership revokes that recovery. Unknown native failures remain errors,
never permission to repeat a potentially consumed request.
Native Moku speech waits for the same device's delivery-ID readiness receipt
before producing audio. Duplicate receipts cannot replay the reply, and media
stop/generation retirement cancels waiting speech. This handshake gives the
client a playback boundary without guessing ordering between sideband polling
and WebRTC events; relay and private-discussion speech keep their existing path.

Verification: `./scripts/go.sh run -race ./tools/verification/moku` and `./scripts/go.sh test -race ./internal/services/moku` from the repository root. The runner also exports production-shaped Talk/dispatch/note records for native UI replays.

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

Direct user input to an ordinary Thread writes a **lazy** system notification in
that input's successful admission transaction. Idle Moku keeps it queued without
starting an execution. The next ordinary Moku input (typed, relay voice, or a
wake-producing terminal fact) carries pending lazy notifications as separate
system context, preserving the original user input and its transcript. Native
voice syncs the same context before admitting its next execution. The shared
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

Before entering native Send or syncing native voice context, Runtime persists an
uncertain attempt for the selected batch. A transport
failure or crash in this interval cannot prove whether the provider consumed the
notification, so these entries are retained and never automatically replayed.
For native voice, context sync alone is not a receipt: removal follows Core
execution admission. A later run failure does not replay an already admitted
notification. Admission proves retention, not that the model read or acted on it. Moku
reports `moku-delivery-uncertain` with the recovery command. Use authenticated
`moku:deliveries` with no arguments to inspect pending facts. Restart the runtime
to fence the old native workers, inspect the native conversation, then invoke
`moku:resolve-delivery` with one object containing `id` and `decision`:
`retry-confirmed-unadmitted` only after confirming non-admission, or
`acknowledge-confirmed-admitted` after confirming admission. Decisions are audited;
the current runtime cannot reconcile its own uncertain attempts. Exactly-once
provider effects cannot be guaranteed without provider idempotency support.

Uncertainty is currently operator-visible through the Runtime diagnostic log
(`moku-delivery-uncertain` under the profile's `runtime/debug-logs`) and the
authenticated Runtime command API. It is not published as Talk, a client error
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

The `interrupt_thread` tool uses the dedicated `InterruptThreadFromMokuTool`
capability so Runtime can retain exact execution provenance after successful
interruption. `CancelTarget` (user Stop) and `Cancel` (lifecycle teardown) retain
their separate capabilities and never supply tool provenance. Batch attempts and
ordered per-thread success/error results retain their existing semantics.

`grep_threads` is an admitted, audited deterministic read, distinct from the
model-based `read_thread`. Runtime limits it to current-profile ordinary Agent
Threads, including archived threads by default. It supports literal/RE2 searches,
body/title selection and intersecting thread-ID/Directory-Scope filters. Follow
`nextCursor` even when a page has no hits; missing coverage is explicit and must
not be presented as proof that native history contains no match. Returned snippets
are untrusted conversation evidence and may contain sensitive user-authored text.
See [grep defaults, bounds and pagination](../threadsearch/README.md#moku-deterministic-grep).
It is not a progress-polling capability.
Invalid grep patterns and cursors remain caller-correctable errors through the
existing tool audit/bridge, while cancellation and Runtime faults remain faults.
