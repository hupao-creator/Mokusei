# Attachment storage

The repository stages path, byte and streaming imports through one bounded
writer. It normalizes the stored display name and basename together, removing
leading dots and unsafe characters. A single-segment dotfile has no separate
extension: `.env` becomes `env`, `.gitignore` becomes `gitignore`, and
`.config.json` becomes `config.json`. Normalization never duplicates an extension.

Thread ownership retains admitted files independently of temporary composer
chips. Preview and cleanup validate that ownership and the immutable content.
The real import, retention, preview and cleanup boundaries are exercised by
`./scripts/go.sh run -race ./tools/verification/runtime-helpers`.

`NewWithClientStorage` binds the production repository to the same local profile
as the native client. A staged file records the importing process's private
`client-attachment-leases/<UUID>.lock`. The client holds its kernel lock through
process exit, including late import results and accepted-command receipts.
Disconnecting a socket or restarting the daemon does not end that owner. Internal
service imports instead have an in-memory handoff owner until retention/discard
or repository retirement. Active streaming writers remain separately protected.

Restored in-memory drafts and pending submissions hold independent tokens in the
process's `<UUID>.refs.json` aggregate. A second window, replacement draft or
disposed composer cannot retire another token. The existing command journal also
stores each submission's attachment IDs before HTTP dispatch, so an uncertain
receipt continues to own its files after the submitting process exits. Consuming
or explicitly acknowledging that receipt releases those references.

`RuntimeDraftStore` version 2 records `attachmentIDs` in the same atomic document
as the opaque client draft value. Collection reads these references directly;
there is no second draft-owner index or age limit on saved user input. The client
releases its staging pin only after consuming/saving the draft. `RetainInput`
adds Thread ownership without removing the client's pin, because native Open or
input admission can still fail afterward. Forks and private sessions retain
independent Thread references.

Deleting an owner and discarding a staging pin collect files with no remaining
Thread, saved-draft, command-receipt, live-process or active-writer reference. Startup and history
reset also collect after reconciling retained Thread/private-session identities.
Unreadable, old-version or invalid ownership documents stop collection without
deleting files; startup logs that failure and remains available for recovery.
Dead process lock files are removed only while their kernel lock is acquired.
No timer or socket-disconnect heuristic decides that a persistent draft expired.

The permanent `ownership.lock` serializes collection with short client ownership
updates. Draft read-and-pin and atomic draft/reference writes hold shared locks;
collection and journal delta read-modify-write hold exclusive locks. No client
network call or async suspension occurs under this gate. Collection classifies
live staging leases before reading durable references, so process exit during a
Stage-to-draft handoff cannot create a gap between those two owners. Collection
also removes unowned payload-only and metadata-only crash remnants.

`./scripts/go.sh run -race ./tools/verification/attachment-lifecycle` exercises
real Runtime/SQLite deletion and restart, fork/private owners, failed admission,
saved drafts, a process-held lease and streaming cleanup. The default runtime CI
group runs it; `transport -swift-files` verifies the actual Swift lease header and
atomic draft record against the production repository on macOS.
