# Moku fixed replay

Run from the repository root:

```sh
go run -race ./tools/verification/moku
```

`./scripts/go.sh run -race ./tools/verification/moku -swift-note-exposure`
starts a temporary authenticated Runtime and launches the production macOS
note presentation. The Swift viewport tracker must send its receipt through
`RuntimeClient`; Go then checks the exact persisted version/text and the next
fake Harness Moku context. This mode needs a macOS graphical session and does
not read a user's profile. Build current Debug modules first with
`xcrun swift build --package-path app/macos`; the launcher reuses that build.

The command exits nonzero if an expectation fails or Go reports a data race.
Successful execution ends with `PASS all Moku fixed replays`. It needs the
repository's Go toolchain and the native build dependencies used by its SQLite
binding. It does not need Node, external Harness CLIs, credentials, a microphone,
or a model-service connection.

All persistent scenarios use newly created temporary directories and actual
SQLite stores. The fixtures never open an existing Mokusei profile. They close
their runtimes and remove their temporary data on completion. Timing checks use
explicit admission and contributor signals; short deadlines verify that a
blocked operation remains blocked. Native messages, model replies, SDP and
media events are fixed local fixtures.

## Coverage

- Actual `SendMokuThread` admission: the sender waits for its admission callback,
  and user input is committed before the native tool executes.
- The in-memory fallback fixture sends public `thread:follow-up` admissions to
  the real Moku native handle as internal coordination events. This fixture
  does not establish the production durable lazy-delivery path described below.
  SQLite event IDs,
  user source, target thread, execution receipts, original child instructions,
  canonical attachments and browser annotations survive delivery. Running
  steering and new executions both notify; failed sends, repeated admission
  callbacks, unrelated revisions, Moku/tool sends and restart history do not
  produce duplicate user notifications. Large Unicode inputs retain their full
  durable payload and deliver an explicitly truncated preview.
- Actual `create_thread`: requested settings resolve against the allocated
  temporary workspace, and the returned workspace matches persisted state.
- Harness configuration envelopes must be projected to thread defaults before
  host selection or delegated-thread resolution; the native fixture rejects
  unprojected envelopes.
- Three-sentence built-in Moku instruction injection without a per-target prose
  appendix, covering coordination, reply invisibility and information routing
  while retaining detailed tool contracts.
- Core tools and their audit records, required native creation options, terminal
  notifications, follow-ups, clear, cancellation before and during admission,
  configuration revision-conflict retries, and retirement of old settings and
  target-catalog tool bindings.
- Execution ownership: an interleaved terminal commit cannot recreate a stale
  tool scope or cause a read against a delegated model after cancellation.
- Out-of-order commit delivery: a note snapshot from a completed execution
  arriving after its successor cannot cancel the successor's in-flight read or
  revoke its next tool call. A delayed first terminal notification still settles
  that older execution's pending audit without taking the successor's scope.
- Context timeouts, cached telemetry, discarded results from retired generations,
  and shutdown waiting for a contributor that has not yet released its work.
- Real configuration admission locks, deferred settings while running, idle
  snapshot adoption, and distinct saved/applied settings after SQLite reopen.
- Cross-Harness selection rejects active Moku and running, waiting, pending or
  native-background ordinary tasks, while unrelated settings remain editable.
  Replacement rechecks work admitted after the save and fences concurrent native
  admission. The new Harness receives the exact note on its next input; switching
  back preserves an empty note without an extra model request.

- Successor configuration adoption when terminal publication races context
  collection or a native follow-up rejection, across typed inputs, lifecycle
  events and the durable outbox. Pending settings reject new executions while
  native background work remains active. After it drains, explicit typed retry,
  a new fallback lifecycle event, or the retained durable notification starts
  one successor with the new model, context and instructions. The no-outbox
  fallback does not establish durable retry; production supplies the outbox.
  Unknown/wrapped admission failures retain the uncertain delivery instead of
  automatically replaying it.
- Same-owner relay media and exact spoken-result identity across model, routing,
  target-selection and target-catalog changes; retired tools, host replacement
  and failed cleanup still enforce their ownership boundaries.
- Native voice configuration reconnection, preserved unadmitted handoffs,
  settings reverted after a reconnect token, retained device ownership,
  Stop/cleanup-failure rejection and slow settings admission without blocking
  media polling. Native admissions carry the media session's voice scope, as
  real Codex admission does. Pending speech prevents premature reconnection;
  pending settings with live background work reject new native foreground
  input without reserving an execution or committing user audit.
- Readable initial Moku shells even when native Probe/Describe fails or blocks,
  restoration of an unapplied shell, atomic configured replacement, and restart
  settlement of unfinished tool and assistant audit entries.
- Actual history reset, including draining native background work before deletion,
  replacement of the old audit and tool authority, and fresh admission afterward.
  Configured host replacement can preserve the prior native session as read-only
  history; the replay checks native byte retention, note separation, execution
  and unarchive rejection, and history-reset cleanup.
- Native voice and relay command protocols: context synchronization before
  durable admission, owner/execution/generation checks, typed-input fences,
  cancellation, retired polling, teardown ownership and visible cleanup failure.
  Stopped preparation identities remain revoked; fresh attempts reach the
  injected native failure and stop-before-session-ID cancellation boundaries.
- A cancelled submission and a stopped voice preparation release their queue
  waiters while an unrelated native admission still owns the coordinator gate.
  The native owner remains admitted, and cancelled media never reaches prepare.
- Ending relay media releases eight observed admission waiters before the held
  native owner completes. The owner is held after its admitted callback commits
  user audit; its native tools still finish, and retired requests do not enter.
- Outbox-backed ordinary terminal notifications bypass the ephemeral queue;
  the fallback path still delivers once. Metadata updates do not redeliver, and
  shutdown drains Moku's queued tool/assistant settlement after cancelling an
  earlier coordination input.
- Sending without a selected directory, or with an explicit directory mention,
  avoids a full Thread read. Selected-scope resolution still reads one snapshot and retains
  its workspace hint and failure behavior, excluding another directory with the same basename.
- Shared fixed tool schemas preserve concurrent validation, caller errors and
  completed audit rows. Every target's current native schema is discovered
  before routing and again for each creation, even within one tool binding generation.

These are runnable integration replays, not unit-test files. They validate real
coordinator/runtime/storage behavior against controlled native boundaries. They
do not validate external CLI compatibility, live provider authentication or
models, audio hardware, WebRTC transport, or macOS visual layout. Those require
separate integration or application checks. The optional measurements below use
controlled local workloads and do not predict live-provider latency.

## Controlled performance measurements

Build the replay once, then run the same executable arguments against each
revision. Do not use `-race` for allocation/latency comparisons; run the normal
race-enabled replay separately for correctness.

```sh
./scripts/go.sh build -o /tmp/mokusei-moku-replay ./tools/verification/moku
/tmp/mokusei-moku-replay -performance -samples 5 -iterations 20 -threads 64 -thread-bytes 32768
```

`-performance-case context`, `tools`, or `queue` selects one group; `all` is the
default. Output is newline-delimited JSON, one object per case and sample. Each
context/tool sample reports fixed operation count, summed operation latency,
nanoseconds per operation, allocated objects/bytes and their per-operation
values, plus full Thread-read count. Compare identical dimensions and multiple
samples in an otherwise idle process. Allocation counters are process-wide.

The context cases drive the real coordinator through injected native admission
fixtures and read seeded ordinary Threads through actual `Runtime.Threads` and
the immutable SQLite store snapshot. Native history payload size and Thread
count stay fixed. Cases cover no directory selection, an explicit directory
mention overriding the selected tag, and a tag requiring snapshot resolution.
Initialization and warmup are outside measurement. The coordinator's fixture
audit and sent-input history are cleared between operations, without decoding
or re-encoding records, so conversation growth does not change the workload.

The tool cases call the production `talk` binding with valid or rejected
arguments, including its audit writes and result handling. They warm up the
binding once and reset retained fixture audit rows between operations. This
measures steady-state tool invocation, not isolated schema compilation or SQLite
write latency; both revisions use the same native/store-port fixtures.

Queue samples report `releasedBeforeOwner`, cancellation latency and an explicit
250 ms controlled observation window. They always release the native owner and
join both callers afterward, so the old mutex implementation produces a usable
`false` baseline rather than hanging. Its reported cancellation latency includes
that intentionally held-owner window; it is not a production latency estimate.
The `submit-precancel` and `voice-prepare-precancel` cases cancel before gate
acquisition. The corresponding `*-queued-cancel` cases release the final fixture
adapter and keep the waiting request's context alive until its named fixture
goroutine is observed blocked inside the production queue. `queueWaitState`
records the stack witness (`select` or the baseline's `sync.Mutex.Lock`). Stack
inspection happens before cancellation and outside its timed interval; there
are no production test hooks. This distinguishes cancellation during waiting
from a pre-cancelled request even under delayed scheduling. The voice cases use
the real Runtime/SQLite fixture and a gated media teardown.
The voice pre-cancel latency includes its deliberate 100 ms teardown hold,
reported separately as `mediaHoldWindowNs`; it starts at the initial stop request.

Performance mode does not assert that the implementation is already optimized.
The default replay enforces prompt queue cancellation, exact lazy-read counts,
schema validation behavior, and notification/settlement ownership.

## Direct-user notification ownership

Direct-user notifications reuse `thread.input-accepted` with `source=user`.
The public follow-up command assigns that source; Moku tools and background
work retain `source=application`. Production composition supplies the durable
outbox. The input admission transaction stores a lazy notification alongside its
lifecycle event. Restart retains pending notifications; they do not wake idle
Moku. Its next independently triggered input bundles them as system context.
An active Harness advertising `FollowUpOnly` can receive them without starting
a successor; currently Codex advertises this capability, while Claude, Pi and
OpenCode wait for the next independent input. The direct-to-thread warning tells
Moku that the child already received the input and must not be sent it again.

Attachments use canonical metadata. Inputs over 64 KiB use a UTF-8-safe,
explicitly truncated preview; the child and lifecycle event keep the full input.
The source formatter is shared with the in-memory fallback exercised by
`user_thread_input.go`. That fallback subscribes only to new events when durable
ports are absent; its immediate-send/restart assertions do not certify lazy
production delivery. Runtime's durable implementation is in
[`moku_delivery.go`](../../../internal/core/runtime/moku_delivery.go), selected by
[`composition/moku.go`](../../../internal/core/composition/moku.go).

Admission removes the captured outbox batch durably. Uncertain native outcomes
remain fenced and require explicit reconciliation; see the
[Moku recovery procedure](../../../internal/services/moku/README.md#durable-system-notifications).
Deletion/history reset retire pending facts. User-send success means the child
admitted the input, independently of later Moku delivery. Voice discussions,
interaction answers and interrupt/archive commands do not submit child input
through this path. Repeated explicit submissions remain distinct admissions.

For a compile/static check without executing the fixtures:

```sh
go build -o /tmp/mokusei-moku-replay ./tools/verification/moku
go vet ./tools/verification/moku
```

The existing cold-target replay holds the native catalog and requires the first
Host message to wait. After release it checks the complete initial inventory and
exact creation validation, including rejection of empty and invalid options.

Target discovery gates prove concurrent Probe/Describe, stable configured schema
and error order under reversed completion, and cancellation/Stop joining every
native cleanup. Workspace-purpose checks use all four real Harness adapters and
reject any environment/executable/account discovery attempt.

The creation-contract replay checks one named Harness under `target`, per-Harness
field visibility, exact native choices and rejection of cross-Harness fields,
empty/multiple/unknown selections and the removed `harnessId`/`options` envelope.
Both target orders run through the production schema and Claude wire schema;
the parser independently checks the envelope and preserves native settings for
admission. The replay also checks explicit `worktree` selection across native and
deferred targets against both JSON Schema and the runtime parser. Missing, null
and non-boolean values fail; false remains
valid without cwd; true requires cwd. The runtime replay creates a committed Git
fixture, uses the returned `workspace.worktreeCwd`, verifies edit isolation and
rejects a non-Git cwd for true.

The old `MOKU_TALK_NATIVE_FIXTURE` Talk/dispatch export and its consumers were
removed with the deleted scroll-view fixture. The regular backend Talk schema,
Coordinator, audit and create-thread checks remain in this command; note and
status fixture exports remain active.
