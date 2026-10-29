# Runtime authority

[runtime.go](runtime.go) constructs the state owner from injected Harnesses, store, workspace, attachment and service capabilities. [composition](../composition/bootstrap.go) supplies concrete plugins and attaches the Application host and Moku coordinator. Runtime does not discover plugins through global mutable registration.

## Threads and content

Moku note writes compare the note incarnation, content revision and
`readingRevision` inside the store writer transaction. A mismatched basis returns
the current note/evidence snapshot without changing the note. Full-exposure
receipts accept only the current nonempty incarnation/revision, copying exact
text from the authoritative record. Duplicate and stale receipts make no store
write or notification. Reading evidence changes the Thread catalog revision but
does not change `note.updatedAt`, create lifecycle events or wake Moku.

[threads.go](threads.go) owns thread identity, execution admission and serialized session access. Harness session data remains opaque; each Harness validates it and produces its public observation and renderer projection. Accepted work belongs to the service and survives client disconnection.

Catalog snapshots contain bounded overview projections. [projection_cache.go](projection_cache.go) and [publisher.go](publisher.go) provide revisioned catalog/content publication. Full conversation, turn and execution bodies use independent content subscriptions.
Moku audit previews additionally retain the latest 256 successful completed
`timer` operations across executions so coalesced publication and reconnect can
catch up immediate communication. The Swift workspace owns their transient
queue and acknowledgments; Runtime adds no scheduling or receipt state. Loading a reading page does not reopen a native execution process. A coordinating-Harness change retains the prior Moku record as an archived, read-only `mokuHistory` conversation, including its native state and attachment ownership. These histories cannot be unarchived, forked, reconfigured or executed; native history questions and automatic admission also reject them. The Moku history reader requests pure renderer projections without reopening a native process. An explicit Moku history reset removes them and releases their attachments. Settled execution details are fetched on disclosure; live turns retain the information needed for output and interactions.

Thread enumeration preserves stored order and appends unlisted records with
linear identity reconciliation. Committed-thread subscribers receive owned
records: native state, settings, metadata and transcript bytes are copied without
re-encoding the complete history; the public observation remains deeply detached.

Interaction replies claim their execution/interaction identity durably before
native I/O. Only an explicit adapter guarantee that no I/O began releases that
claim; an uncertain acknowledgement never permits duplicate submission. Public
form preflight passes typed native values through the internal response handoff.

Commands validate their execution/interaction identity before mutation. A follow-up whose reserved execution ended before input was retained may reserve a successor once. A dispatched failure is not automatically resent or used to rewrite an already terminal execution. Cancellation is fenced to its admitted execution, so a late interrupt cannot cancel a successor.

## Settings

[settings.go](settings.go) separates saved settings revision from streaming thread revisions. `app:update-settings` normalizes through the owning Harness and compares `expectedSettingsRevision` in the store transaction. A conflict returns the latest settings; invalid writes leave state unchanged. An unchanged save does not advance the revision.

The [Settings DTO](../model/state.go) contains ordinary Harness defaults, Moku's separate concrete execution profiles, plugin settings and desired plugin enablement. Ordinary thread settings are saved session configuration, not a live reference to global defaults. Thread configuration has its own CAS revision. Moku and background agents retain the configuration of already admitted work; newer saved settings apply at their next admission boundary.

Changing Moku's Harness preference requires idle ordinary Agent Threads and
Moku: running or waiting executions, native background work and pending inputs
reject the save without changing settings. Actual cross-Harness replacement
checks again and reserves the native admission boundary through old-owner
cleanup and durable replacement. Its triggering queued Moku input may proceed
on the new owner afterward. Private Report/Tag executions do not themselves
block switching; an in-flight native admission still does. Unrelated settings
retain their existing save behavior.

Moku rechecks pending configuration before reserving a successor execution,
including when a prepared follow-up races its predecessor's completion. A
confirmed unconsumed input returns to the coordinator for fresh settings,
instructions and context. Uncertain native outcomes are never retried this way.
Background configuration discovery also fences reuse of an existing idle
session. A settings-save race re-resolves the configuration without spending a
batch execution attempt; admitted batches and their retries retain their profile.

Configuration admission uses a cancellable gate. A settings presentation that
leaves its page releases its waiting HTTP request even when another native
discovery still owns the gate; a cancelled waiter never enters the operation.
Nested preparation shares the owning admission context.

Settings presentation and startup recovery discover missing execution profiles
outside that gate. Their short commit merges only changed execution fields,
checking the selected Harness's source rather than unrelated Harness defaults.
An initialized read has no capture to invalidate. Concurrent initializers reuse
an already saved profile and preserve the selected host, even when a late native
reply differs; captures of different Harnesses retain both profiles. A changed
source with no saved execution profile still invalidates discovery. Prompt,
plugin enablement and retained independent edits remain authoritative. An
initialized presentation preserves the stored application JSON when no execution field changes; reordering
JSON keys must not advance the settings CAS revision. User settings saves still
use their original CAS revision and real execution
admission keeps the gate until native acknowledgment.

[configuration.go](configuration.go) initializes missing internal execution profiles from actual native facts. It persists complete choices before use and fences late discovery against newer saves. Background settings select inheritance from Moku or an independent profile. Native credentials and context budgets remain Harness-owned. Moku and background agents use their built-in system instructions; execution profiles do not contain a system-prompt replacement.

Enablement is captured by the composition at startup. Saving desired `harness:`, `extension:`, `context:` or `sidecard:` keys does not change active registrations until the service restarts. Built-in Git has no switch. Client appearance, language, selection and drafts belong to the [native client](../../../app/macos/Sources/Core/README.md).

## Lifecycle and directory scopes

[lifecycle.go](lifecycle.go) records facts in the same transaction as their business change. Subject identity/type and event source are distinct. Retired Moku histories retain their `moku` subject type and are excluded from ordinary-task capabilities, semantic-tag mutation and directory-scope discovery. Durable consumers retain batches, retries, receipts and outcomes; live subscriptions observe new commits without replaying old events. Moku receives ordinary terminal notifications through its durable outbox and direct user-input facts through live subscriptions. Background agents own their own processing queues.

Lifecycle subscriptions skip store revisions that cannot change their input.
Live subscriptions track the event generation; durable subscriptions track the
lifecycle generation and the exact observed private-session record hash, so a
session observation still wakes its runner independently of new lifecycle facts.

[scope_agents.go](scope_agents.go), [background_scope.go](background_scope.go) and [lifecycle_capability.go](lifecycle_capability.go) bind background instances to explicit directory scopes. Inbox is a valid scope, distinct from global authority. Task reads, events and private-session access intersect the owner's binding. Report and Tag use per-directory instances; their native sessions initialize lazily and are disposed when idle.

## Coordination state lifetime

Command locks count both holders and waiters. Only the final lease release
removes a lock, so deleting a thread cannot split concurrent callers across two
mutexes. Cancellation gates retain live-session identity and pending send claims;
a deleted session's gate is reclaimed after its final reference is released.
History reset prunes unreferenced gates after removing durable session records.
Unknown-ID requests do not retain gates. These contracts are exercised by
`make check-modules`, including concurrent waiters and repeated deletion/reset.

## Shutdown and history reset

[service.go](service.go) revokes admission and drains participants and native owners before storage ownership is released. A protocol disconnect alone is not proof that a child process exited. Cleanup errors remain observable and prevent a replacement owner.

History clearing stops participants, restores sessions that require cleanup, drains native owners and rechecks public/private background observations before replacing history in one SQLite transaction. Settings survive a full clear. Failed cleanup preserves history and fences the generation; it does not silently erase uncertain native work or start another owner. Search workers and media participate in the same cancellation boundary.

Verification from the repository root:

```sh
./scripts/go.sh run -race ./tools/verification/runtime
./scripts/go.sh run -race ./tools/verification/runtime-concurrency
./scripts/go.sh run -race ./tools/verification/settings-shell
./scripts/go.sh test -race ./internal/core/runtime
```

The [native settings launcher](../../../tools/verification/README.md) additionally exercises the Swift draft/save path against a real daemon.

Automatic installation discovery uses `harness:detect-installation` with one
Harness ID. Each response is independent and does not refresh the login shell.
Explicit `harness:detect-installations` recovery still refreshes the environment
once before the parallel batch. Neither endpoint interprets installed as
account authentication. Settings telemetry separately measures
`installation`, `presentation.snapshot` and `presentation.native`, with bounded
Harness/owner metadata and no settings or credential values.
