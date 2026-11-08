# Attachment ownership lifecycle replay

Run from the repository root:

```sh
./scripts/go.sh run -race ./tools/verification/attachment-lifecycle
```

The replay uses the production attachment repository, Runtime and on-disk SQLite.
Each restart closes Runtime and SQLite, then constructs a new store, repository
and Runtime over the same profile. This retires the repository's in-memory pending
imports instead of mistaking them for durable owners.

It covers:

- Deleting the last ordinary thread removes its files and manifests without an
  explicit collector call; a production `ForkThread` and a persisted private
  session retain independent ownership across deletion and restart.
- A Runtime restart collects both metadata-only and payload-only remnants of an
  interrupted removal. A surviving thread keeps its diagnostic manifest when
  its payload is missing; deleting that last owner also collects the manifest.
- An unsent v2 client draft remains canonical and readable across process-style
  restart. `Discard` cannot revoke that draft; removing its last reference allows
  collection. The fixture writes the shared envelope atomically, including its
  `attachmentIDs` and opaque composer value in the same record.
- A second live client restores the old importer's draft after that importer
  exits, publishing its own `<lease>.refs.json` before clearing durable draft
  references. Its exact process references retain the file across Runtime
  restart; clearing them permits collection even while that client remains alive.
- The durable command journal preserves uncertain inputs without any surviving
  process lease or draft. `awaitingReceipt`, `pending`, `unknown`, `indeterminate`,
  `accepted` and `rejected` records each retain attachments across restart until
  the records are removed. A follow-up successor with optional `forkReceiptID`
  retains its own inputs after its fork receipt has been consumed; replacing an
  old record releases only that old record's attachments. Missing `attachmentIDs`,
  null, malformed, self-referencing or wrongly routed fork lineage, and unknown
  journal fields block collection and report a startup error rather than being
  interpreted as an empty reference set.
- A real `SendThread` reaches `RetainInput` and then fails at native `Open`.
  Deleting that thread and discarding its chip still preserve the persisted draft.
- A separate child process holds a real `flock` on the client's UUID lease file.
  Collection and daemon restart preserve the Stage-to-draft handoff; SIGKILL and
  `Wait` release the lock without removing its file. Restart then collects
  abandoned staging, and the dead lease cannot admit another import.
- Three deterministic save/exit races let a child perform real Stage, atomically
  save its v2 draft and exit while collection is paused at its first cancellation
  check. The collector resumes only after the child has been reaped. The saved
  file must survive even though its process lease has ended; reading draft
  ownership before checking the lease fails this replay. This one negative-order
  fixture deliberately publishes without the shared writer gate to keep that
  ordering observable; ordinary fixture writers use the real ownership lock.
- A real streaming writer blocks on `io.Pipe` while collection completes. The
  partial file survives, the finished file stays owned until handoff/Discard,
  and content/hash validation succeeds after the writer resumes.
- Corrupt JSON and v1 draft records stop collection, retain the unowned files,
  and surface the startup collection error while Runtime remains available.
  Removing the unreadable record makes the next startup collect the orphan.

The Harness fixture rejects native opening and provides idle fork projections;
it does not emulate a native engine or make a model request. Private session
retention is seeded through its durable SQLite snapshot, while fork and failed
send run through production Runtime methods. Native draft UI and transport lease
propagation have separate Swift/transport coverage.

Draft, process-reference and journal fixture writes hold a shared kernel lock on
`client-attachment-leases/ownership.lock`; production collection takes the
exclusive lock. Restoring and pinning a draft occurs within one shared lock.

Use `-case last-owner|crash-artifacts|fork-private|draft-restart|restored-process-refs|command-journal|corrupt-journal|draft-exit-race|failed-send|crashed-staging|stream-collection|corrupt-draft|v1-draft`
for a focused run. Fixtures use private temporary profiles, explicitly kill/join
their lease children, and close Runtime/SQLite before removing their directories.
The ordinary CI runtime replay group owns this check.
