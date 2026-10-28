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
not read a user's profile. Run `make check` first; the launcher uses its current
Swift build.

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
- Public `thread:follow-up` admissions from conversation/browser sidecards reach
  the real Moku native handle as internal coordination events. SQLite event IDs,
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
- Core tools and their audit records, required native creation options, terminal
  notifications, follow-ups, clear, cancellation before and during admission,
  configuration revision-conflict retries, and retirement of old settings and
  target-catalog tool bindings.
- Execution ownership: an interleaved terminal commit cannot recreate a stale
  tool scope or cause a read against a delegated model after cancellation.
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
  events and the durable outbox. Unknown/wrapped admission failures retain the
  uncertain delivery instead of automatically replaying it.
- Same-owner relay media and exact spoken-result identity across model, routing,
  target-selection and target-catalog changes; retired tools, host replacement
  and failed cleanup still enforce their ownership boundaries.
- Native voice configuration reconnection, preserved unadmitted handoffs,
  settings reverted after a reconnect token, retained device ownership,
  Stop/cleanup-failure rejection and slow settings admission without blocking
  media polling. Pending speech prevents premature reconnection.
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
- A cancelled submission and a stopped voice preparation release their queue
  waiters while an unrelated native admission still owns the coordinator gate.
  The native owner remains admitted, and cancelled media never reaches prepare.
- Ending relay media releases eight observed admission waiters before the held
  native owner completes. The owner still commits and retired requests do not.
- Outbox-backed ordinary terminal notifications bypass the ephemeral queue;
  the fallback path still delivers once. Metadata updates do not redeliver, and
  shutdown drains Moku's queued tool/assistant settlement after cancelling an
  earlier coordination input.
- Sending without a selected directory, or with an explicit directory mention,
  avoids a full Thread read. Selected-scope resolution still reads one snapshot and retains
  its workspace hint and failure behavior, excluding another directory with the same basename.
- Shared fixed tool schemas preserve concurrent validation, caller errors and
  completed audit rows. A deferred target's current native schema is discovered
  again for each creation, even within one tool binding generation.

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

Direct-user notifications reuse `thread.input-accepted` with `source=user`.
Only the public follow-up command assigns that source; Moku tools and background
work retain `source=application`. Moku subscribes to newly committed lifecycle
events and queues them through the same settings/context/native `SendMokuThread`
path as terminal events, including steering a busy Moku. The notification tells
Moku to respect the child's direct user instructions and not resend the input.
Attachments are described by canonical metadata, not inspected by Moku. Input
payloads over 64 KiB use a UTF-8-safe preview, event/execution identifiers and an
explicit truncation flag; the child and durable event keep the complete input.

The voice sidecard is a read-only discussion and does not submit child tasks.
Native interaction responses and interrupt/archive commands are outside this
follow-up notification path. Historical direct-user input notifications are
not replayed on coordinator restart; this path still uses an in-memory queue
without durable retry if Moku admission fails. Terminal completion notifications
use a separate transactional outbox with admission receipts, safe retry and
explicit uncertain-admission reconciliation; see the
[Moku recovery procedure](../../../internal/services/moku/README.md#durable-completion-notifications).
Deleted/deleting
targets are skipped. User-send success means the child admitted the input,
independent of later execution or Moku delivery failure. Repeated explicit user
submissions remain distinct admissions; this does not add transport idempotency.

For a compile/static check without executing the fixtures:

```sh
go build -o /tmp/mokusei-moku-replay ./tools/verification/moku
go vet ./tools/verification/moku
```

The coordinator replay also blocks a deferred native Target catalog while admitting
the Host first message, then checks on-demand `describe_native_harness` and exact
creation validation (including rejection of empty and invalid options).

Target discovery gates prove concurrent Probe/Describe, stable configured schema
and error order under reversed completion, and cancellation/Stop joining every
native cleanup. Workspace-purpose checks use all four real Harness adapters and
reject any environment/executable/account discovery attempt.

The creation-contract replay checks explicit `worktree` selection across native and
deferred native branches against both JSON Schema and
the runtime parser. Missing, null and non-boolean values fail; false remains
valid without cwd; true requires cwd. The runtime replay creates a committed Git
fixture, uses the returned `workspace.worktreeCwd`, verifies edit isolation and
rejects a non-Git cwd for true.
