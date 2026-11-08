# Native runtime client

[RuntimeClient.swift](RuntimeClient.swift) owns connection authority and public state. [RuntimeProtocol.swift](RuntimeProtocol.swift), [RuntimeCommands.swift](RuntimeCommands.swift), [RuntimeState.swift](RuntimeState.swift) and [JSONDelta.swift](JSONDelta.swift) mirror the [Go protocol](../../../../internal/platform/transport/README.md). [JSONValue.swift](JSONValue.swift) preserves integer tokens separately from floating-point values, including cursors and revisions sent to Go integer DTOs.

Connection epochs and host identities fence callbacks. The client hydrates from a complete snapshot, applies valid deltas, and obtains a fresh snapshot after gaps. Catalog data is separate from [RuntimeContent](RuntimeContent.swift) subscriptions for full conversations, turns and execution bodies. A released ready subscription may remain live for 30 seconds in the bounded
[reading retention cache](RuntimeReadingRetention.swift) (four entries, 8MiB
accounting budget); the consumer ID retires immediately and its live wire can
transfer to a fresh reader. Idle entries continue receiving patches and expire on
stream retirement/reset, errors, gaps or budget pressure. Pending reads never
transfer. Connected reads await fresh snapshots; persisted content is an offline
fallback. Route-owned prefetch uses the same production subscription path; opening a reading view does not start an agent process.

Catalog arrays are admitted once into [persistent ordered records](RuntimeRecordCollection.swift).
An ordinary upsert copies logarithmic index paths and retains earlier event
snapshots without copying unrelated records. `JSONValue.catalog` is an internal
representation: equality, hashing and wire/cache encoding retain ordinary JSON
array semantics. A remove and upsert for the same ID in one mutation preserves
its order slot and resets the revision fence only for the first upsert. Deleting
an ID in one transaction and recreating it later appends a new slot. Explicit
ordering remains authoritative and validates the supplied complete order; full
snapshots/reconnects still validate every identity. Whole-array readers materialize
only when they request the collection. Native catalog preparation consumes the
accepted mutation identities and decodes only changed envelopes. Activity-only
mutations advance the stream revision without rewriting the offline state cache.

[RuntimeSettingsReads](RuntimeSettingsReads.swift) admits settings presentation
and single-Harness installation reads before they open HTTP connections. At most
four discovery reads run per client, with one per global Harness (or Thread
editor) and FIFO admission among eligible keys. Cold defaults/Moku/application
prefetch therefore leaves room in the host's unchanged 16-request pool for ordinary commands.
Cancelled queued reads never reach HTTP; active reads cancel their HTTP request.
Single-Harness detection is read-only and retains no uncertain write receipt.

A failed content release retires its owning stream so server demand cannot leak;
the reported failure retains the underlying transport code and message.

[RuntimeProcessManager](RuntimeProcessManager.swift) manages a local profile and its owned service. Start waits for an already-stopping owner to retire (up to two minutes), then reuses normal exclusive launch admission; a completed cleanup error does not permanently block reopening. [RuntimeTransport](RuntimeTransport.swift) authenticates the client over loopback.

Discovery retains private-file and profile identity checks. A failed health
probe for a dead recorded owner is stale discovery, including typed HTTP errors
from a reused port. Live-owner errors and task cancellation remain visible.
Profiles selected before directory creation compare discovery against the
directory's current canonical spelling.

[RuntimeProfileClientLease](RuntimeProfileClientLease.swift) admits a native
client before it reads retained preferences, drafts, caches or window state.
A private OS-user lock directory lives outside the selected profile and is
independent of `HOME`, `TMPDIR` and Foundation home overrides. A short exclusive
admission lock serializes path creation/canonicalization with fresh rotation;
the client then retains a shared canonical-profile lock for its whole lifetime.
Fresh takes exclusive locks for current and previous while holding admission.
All acquisitions are nonblocking, so a competing startup fails before reading
old state rather than waiting while holding another authority.

App startup retains this lease through process exit, including asynchronous
work and atexit cleanup. The exit helper and Probe acquire their own leases;
failed helper admission writes only stderr, never profile diagnostics. All
retained paths come from the lease's canonical profile. Multiple clients may
share a profile normally. Kernel descriptor locks release on abnormal exit;
the lock files themselves are never removed or replaced during cleanup.

[RuntimeOfflineStore](RuntimeOfflineStore.swift) and [RuntimeOfflineRecovery](RuntimeOfflineRecovery.swift) keep profile-local cached reading data, drafts and uncertain command identity. Offline reading/editing does not queue automatic sends or cancellations. On reconnect, a mutation with an uncertain response is checked by its original receipt identity; a newer draft cannot be consumed by an older completion.

Execution continuation uses `invoke(... retainingReceipt: true)` with an explicit
command ID. A successful result remains in the durable command journal until
its caller consumes the matching draft. Acknowledgement waits only for that
receipt's own active command; unrelated reads/writes do not prevent cleanup.
After an accepted continuation consumes its draft, cleanup failures are logged
without presenting a send error. The retained operation and durable receipt still
block new input until cleanup succeeds on the next send attempt; no input is
replayed by cleanup. `resolveCommandReceipt` is query-only:
unknown, pending, expired and indeterminate outcomes never fall back to invoke.
This is deliberately distinct from explicit same-ID invoke retries, which the
general client API can admit after an unknown receipt.
Unconsumed fork/follow-up identities block different fork/follow-up request keys,
including while the first command is active. The admission check is synchronous
on the client actor, closing a multi-window check-then-invoke race. This is a
conservative client-scoped barrier, retained in the profile journal; unrelated
Thread work on that client can be paused too. It is not a cross-process lock.
Reopening without the original continuation context never guesses a new target
from catalog state. Receipt lookup/retention cannot establish exactly-once native
effects after a host crash or expired outcome; the UI keeps the draft and blocks.

[RuntimeHostFiles](RuntimeHostFiles.swift) owns authenticated upload/download and host-file capabilities. Files are selected on the Mac or transferred through the local service. Arbitrary client filesystem paths are not interchangeable with approved host references.

Uploads open without blocking and validate the file descriptor before copying,
so special files cannot trap a cancelled import. Regular-file symlinks remain
supported; identity and modification checks reject replacement during copying.
Downloads retain the validated host basename, including `.partial`.
Directory-list entries use their own host, target and entry name for UI identity,
so distinct symlinks to the same target retain stable labels after redraws.

Client appearance and language preferences live in [DesktopPreferences](../Host/Shell/DesktopPreferences.swift); navigation and drafts belong to their native workspace. They remain separate from Runtime execution settings. Host-facing generated-output locale synchronization is also separate from those settings.

Verification: Core Swift tests, `./scripts/go.sh run -race ./tools/verification/transport -swift-deltas`,
`transport -swift-files`, `runtime-helpers --swift-shutdown` and `runtime -swift-voice`
from the repository root on macOS. The file interop replay uses the real Swift
client without GUI: regular and symlink uploads, prompt FIFO rejection, and
`.partial` downloads retain their validated bytes and basename.

`NativePerformance.recordTextCache` accumulates hit/miss integers per surface in
its current recorder, rather than allocating an event for every size proposal.
At each existing 250ms writer drain, `text.cache` records carry `queries`, `hits`
and `misses`; their timestamp is the drain time, not an individual probe time.
Summary `count` remains the number of queries, with hit/miss totals alongside it.
Pending counters are limited to 256 contexts and overflow increments the existing
dropped counter. Reconfiguration and normal finish drain the owning recorder;
counts never cross recording sessions. JSON encoding and file IO stay off the
main actor. Other metrics retain their existing event/span semantics.
