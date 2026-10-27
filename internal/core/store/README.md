# Go storage contract

`internal/core/store` is the authoritative durability boundary. It uses the macOS
system SQLite library through `internal/platform/sqlite`, a small cgo binding. There is no
Node process, SQLite CLI subprocess, third-party Go driver, or JSON-file fallback.
Building requires cgo, the system SQLite development headers, and a C compiler.

## File ownership and format

The caller chooses the database path under its exclusively owned profile. The
store additionally holds a nonblocking advisory lock on `<path>.lock`, preventing
two store instances from writing the same file. The database is mode `0600`, and
new parent directories are mode `0700`.

The Go format has `application_id = 0x4d4f4b53` (`MOKS`) and `user_version = 1`. Only a completely empty, unversioned
SQLite database can be initialized. Foreign versions, extra schema objects,
altered table definitions, malformed JSON, invalid lifecycle references, and
noncontiguous ordering are rejected at open.

The schema contains:

| Table | Responsibility |
| --- | --- |
| `records` | One UTF-8 JSON BLOB per unique record key, at most 50 MiB each |
| `entity_order` | Unique IDs and contiguous positions for each ordered entity kind |
| `store_meta` | Monotonically increasing committed revision |

SQLite runs in WAL mode with `synchronous=FULL`, an 8 KiB page size for new files,
and a 2-second busy timeout. macOS full fsync and checkpoint full fsync are
enabled. A successful update means that COMMIT has completed, including its
durability work. WAL checkpoint completion is not required for durability.

## Transactions and snapshots

```go
db, err := store.Open(path)
if err != nil { return err }

snapshot, err := db.Update(ctx, func(tx *store.Tx) error {
    var thread Thread
    found, err := tx.Get("thread:"+id, &thread)
    if err != nil { return err }
    if !found { return errNotFound }
    if thread.Revision != expectedRevision { return errConflict }
    thread.Revision++
    thread.Title = title
    return tx.Put("thread:"+id, thread)
})
```

`Update` admits requests into a single FIFO writer. Its callback reads the latest
committed state and must be synchronous; it must not call `Update` or `Close`
recursively. It may read the committed `Store.Snapshot()` without blocking.
Caller-owned slices are copied on write. The transaction becomes unusable when
the callback returns.

The callback can `Get`, `Raw`, `Has`, `Keys`, `Order`, `Put`, `PutRaw`, `Delete`,
and `SetOrder`. A callback error or panic discards every staged write. Validation
and cancellation checks happen before beginning the SQLite transaction. Record
writes, entity ordering, lifecycle events, consumer batches, receipts, outcomes,
and the new revision share one `BEGIN IMMEDIATE` / `COMMIT` boundary.
Lifecycle validation checks changed records against the complete staged view;
unchanged history retains its validation from the committed snapshot. Removing
an event performs a full reference check, so unchanged work and outcomes cannot
be left pointing to a missing fact. Opening a database still validates all records.

Once SQLite starts the transaction, `Update` waits for a definite result even
if its context is cancelled. Successful COMMIT always publishes the new snapshot
and notifies subscribers. Failed SQL statements roll back the transaction and
publish nothing. An uncertain storage error or failed rollback fences further
updates until the store is reopened.

Snapshots are immutable views. `Raw`, `Order`, and JSON decoding provide owned
copies, including input passed to custom `UnmarshalJSON` implementations. Old
snapshots remain valid after later commits. Unchanged byte-identical writes and
unchanged ordering do not increment the revision.

`Subscribe` returns a channel of committed revisions, including the current
revision immediately. Notifications coalesce for slow readers; consumers reread
the snapshot. Durable lifecycle delivery uses persisted events and outcomes,
not this channel's delivery count.
`Snapshot.EventRevision()` changes only for event writes or deletions;
`LifecycleRevision()` also includes work and outcome changes. Consumers can skip
unrelated commits by comparing these markers within the same open store. They
are initialized to the durable revision on reopen and are not persistent cursors.

`Flush` is a queue barrier. The store has no deferred non-durable publication or
automatic token-stream debounce: an owning runtime may collect observations
before submitting them, but it must pass a durable transaction boundary before
admitting native work which depends on those observations.

`Close` rejects new work, drains admitted requests, closes SQLite, and then
releases ownership. Repeated calls return the same result. On a storage/close
failure, the file lock remains held; the process owner must retain profile
ownership and surface the error instead of starting a replacement writer.

## Key layout and model ownership

The store has no dependency on the application model. Runtime code supplies its
typed domain validation and uses keys such as:

- `thread:<id>`, ordered under `thread`;
- `application-record:<collection>:<id>` and collection metadata;
- `private-session:<id>`;
- `settings`, `settings-revision`, `moku-applied-settings`, `tags`, and tag metadata;
- `event:<id>`, `lifecycle-work:<consumer>`, and
  `lifecycle-outcome:<consumer>:<event>`.

The store validates JSON and storage invariants, while the runtime validates
thread identity, expected revision, settings shape, collection schema, access
scope, lifecycle fact generation, and other product rules inside the transaction.
Order updates and referenced records must be submitted together. The generic
store deliberately does not infer record keys from an order kind.

## Lifecycle delivery and idempotent effects

`Tx.AppendEvent` appends a validated `store.Event` in the same transaction as the
business change. Events use the existing lifecycle event names, millisecond
timestamps, subject `{kind, id, typeId}`, source, and JSON data. Event IDs cannot
be reused for different facts.

`Tx.SetWork(consumer, expectedBatchID, work)` starts a batch with an empty expected
ID or updates the matching active batch. Updates merge event IDs and preserve
existing receipts. Missing events, duplicate IDs, already acknowledged events,
stale batch IDs, and invalid retry fields are rejected.

`Tx.SettleWork` atomically removes active work and records `processed` or `failed`
for every event in the batch. Acknowledgements remain independently of active
work, including across application restarts.

`Tx.ApplyReceipt` checks the consumer/batch/key fence, returns an existing result
when present, or executes a business effect in an isolated child transaction.
Its result and business writes commit together. If the effect fails, none of its
staged writes enter the parent transaction. `ReadReceipt` and `RecordReceipt`
also support callers implementing their own domain transaction composition.
Receipts deduplicate transactional state changes; an irreversible external side
effect still requires its own idempotency mechanism.

`Snapshot.Events`, `Pending`, `Work`, and paged `History` support restart recovery
and consumer processing. Events sort by creation time and then ID. Pending
queries exclude acknowledged events and apply optional scope filters; history
includes per-consumer outcomes. Scope authorization remains the caller's job.

## Source and verification

[store.go](store.go) owns admission and transactions, [sqlite.go](sqlite.go) owns schema and durable writes, [snapshot.go](snapshot.go) owns immutable reads, and [lifecycle.go](lifecycle.go) owns events, work and receipts.

Run `./scripts/go.sh run -race ./tools/verification/storage-workspaces` from the repository root. Runtime domain validation is also exercised by the [runtime and application-host replays](../../../tools/verification/README.md).
