# Profile identity and ownership

`Resolve` derives the discovery paths, workspace root and exclusive TCP guard
from one canonical data directory. On macOS it uses Darwin `realpath`, matching
the Swift client and the filesystem's stored spelling. Existing aliases on a
case-insensitive volume share an identity; distinct directories on a
case-sensitive volume remain separate. Missing suffixes retain their spelling
until creation, with their deepest existing ancestor resolved first.

Call `Refresh` after creating a selected profile, before deriving application
resources. It retains the selected home when rebuilding the workspace identity.
`Acquire` binds the selected guard before preparing metadata, and checks the
path identity both before and after creation. A profile resolved before a case
alias existed can become stale; `STALE_PROFILE` rejects that lease instead of
allowing a writer under another guard. The runtime entry point prepares and
refreshes before constructing its application; the daemon management boundary
refreshes discovery and launch identities too.

`WithExclusiveAccess` holds the same guard for maintenance of an existing
profile. It checks private owner metadata and refuses a live owner, including
one without a GUI. It creates no directory and writes no owner record, so its
callback may rename the directory without weakening `Ownership.Release`.
Missing or changed ownership metadata still fails closed during runtime
release. Port collisions remain ownership failures.

Native clients also retain a shared profile lease before loading preferences,
drafts or other local state. Startup holds the nonblocking exclusive
`admission.lock` while creating the selected directory, resolving its canonical
identity and acquiring the shared lease. The client keeps that lease until its
process exits; runtime shutdown or window dismissal does not release it. Exit
helpers acquire their own lease before accessing profile state.

`WithClientMaintenance` holds the same admission lock for its entire callback,
then acquires nonblocking exclusive leases for the requested canonical profiles.
Repeated identities share one lease. This excludes a late native startup as
well as existing retained writers while maintenance removes or renames a
profile. The development tool holds both current and previous client leases
before acquiring the existing runtime guards or scanning native processes.
Admission, lease and callback failures unwind acquired locks in reverse order.

The shared Go/Swift lock root is `mokusei-profile-leases-v1` under the canonical
directory returned by Darwin `confstr(_CS_DARWIN_USER_TEMP_DIR)`. `HOME`, `TMPDIR`
and `CFFIXED_USER_HOME` never select this root. Profile files are named
`<lowercase SHA256 of the canonical DataDir UTF-8 bytes>.lock`. The root must be
a real directory owned by the current UID with mode 0700. Directory opens use
`O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` and verify the opened identity. Files are
opened relative to that descriptor, with `O_RDWR | O_CREAT | O_NOFOLLOW |
O_CLOEXEC | O_NONBLOCK`, mode 0600, then checked as regular, same-UID, private,
single-link files. Existing entries are checked before opening; after locking,
the descriptor is checked again against the named entry through the directory
descriptor, including device and inode. These files are permanent: release closes descriptors;
it never unlinks or replaces a lock file, including after profile rotation.
`ClientLeasePath` exposes the current canonical lock path for diagnostics and
isolated verification; computing that path grants no authority.

Verification: `./scripts/go.sh run -race ./tools/verification/runtime-helpers`
checks pre-creation identity, concurrent management, discovery and shutdown.
Add `--swift-shutdown` for Go/Swift data-directory and workspace agreement plus
a Swift profile selected before an alias appears. The case-alias branch runs
only when the filesystem confirms both paths are the same file; otherwise the
replay checks separate profiles. The [devtool replay](../../../tools/verification/devtools/README.md)
checks exclusive maintenance and development-profile rotation; its native
writer mode verifies shared leases and startup at the final rotation boundary.
