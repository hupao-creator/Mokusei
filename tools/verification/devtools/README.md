# Development tooling replay

Run from the repository root:

```sh
./scripts/go.sh run -race ./tools/verification/devtools
```

The replay calls production `devtool.Run`, `WatchMain`, `FreshDevelopmentData`
and profile ownership APIs with disposable profiles, a temporary Git checkout
and self-exec compiler/application fixtures. It does not compile the native app
or launch a GUI.

It checks serialized build admission, cancellation while waiting for a lease,
source-change rejection preserving the previous artifact, and the running-app
installation guard through a symlink alias. Compiler fixtures leave descendants
that ignore SIGTERM, close inherited pipes and write a heartbeat. Cancellation
must stop them before the next compiler enters; successful leader exit must
join them before publication. A nonzero compiler preserves its exit status and
the previous artifact. The watcher case runs a nested production devtool build
to check that cancellation waits for the inner tool's independent compiler group.
Each heartbeat is written and closed in a temporary file in the same directory,
then renamed over the published value. Killing the fixture during its next write
therefore preserves the previous complete receipt. Directly truncating the
published file could leave it empty after correct cleanup, making the later
nonempty-receipt check impossible to satisfy. PID-stop checks, the ten-second
receipt deadline and the unchanged-heartbeat comparison remain in force.

Profile checks hold real owners of the current profile and its previous backup
without a GUI and require fresh rotation to preserve both directories and owner
metadata. Rejections retain the typed ownership error and name the blocked
current or backup profile with its cooperative stop command. They also hold
exclusive maintenance while attempting runtime acquisition, exercise callback failure,
then verify rotation and reacquisition after release. A missing current profile
must preserve its backup. See [profile identity](../../../internal/platform/profile/README.md)
for the separate cross-language and case-alias replay.
An aliased profile uses its canonical ownership guard while rotation preserves
the selected symlink and backup-path behavior. Two aliases of the same profile
reuse one guard. Missing-backup checks race production profile acquisition with
rotation and require the selected data and acquired ownership to survive.

Native-process fixtures also check bundle defaults, the runtime-exit helper,
an unrelated raw executable, invalid bundle metadata and removed executable
images. A live native candidate remains excluded when inspection fails; an
unlinked non-native process must not block fresh. These fixtures check process
admission, while the Swift replay below proves actual offline persistence.

The additional offline-client replay links the production native preference
writer and the current compiled Core draft store into a controlled executable:

```sh
make check
./scripts/go.sh run -race ./tools/verification/devtools -swift-offline-client
```

It requires Apple Silicon macOS and the current `app/macos/.build/debug` Core
objects. The replay compiles `DesktopPreferences.swift` with a small stdin-driven
Swift launcher and links `MokuseiCore`; it does not duplicate either persistence
implementation or open a GUI. Two executables named `Mokusei` live in temporary
paths representing different checkouts and fast generations. Their native
`--data-dir` arguments contain spaces. Initial records and later edits all use
the production setters and `RuntimeDraftStore.save`, followed by production reads.
The writer first acquires `RuntimeProfileClientLease`, uses its canonical profile
and retains the shared lease until process exit. No preference or draft object
is initialized if admission fails.

With no runtime owner, a live writer using current or previous must cause fresh
to return the native-client rejection with `profile.ErrClientLeaseBusy` and
preserve both profiles byte for byte. Checking the lease cause prevents the
older process scan from hiding a Go/Swift lock-identity mismatch.
Each case also runs through a canonical symlink alias. The same process then
continues saving preferences and drafts after rejection. Only after cooperative
exit may fresh rotate current to previous and a replacement client initialize a
new current profile. A writer for an unrelated profile must allow rotation and
can keep writing without changing either new current or previous. Fresh runs in
a separate Go subprocess with a disposable HOME; writer acknowledgements and
process exit are bounded, and emergency cleanup targets only fixture PIDs.
The stdout reader joins the child with `Cmd.Wait`, which also owns closing its
stdin pipe. A controller close after a fast acknowledged exit may observe
`os.ErrClosed`; that is harmless, but every other close error and the actual
child exit status still fail the replay. A closed pipe never replaces the
cooperative acknowledgement or joined-exit assertion.

Before starting a writer without `--data-dir`, the same Swift executable runs
two read-only Foundation home probes: a temporary HOME with CFFIXED_USER_HOME
removed, then a different HOME with CFFIXED_USER_HOME set to the temporary home.
Only the two resolved paths are reported. The default writer runs only after
the second probe confirms the temporary canonical home. It uses Foundation's
home and its fixture bundle's `MokuseiDataDirectoryName`, matching native default
directory selection, and must also block fresh while retaining real preferences
and drafts. The probe branch creates no persistence objects or records; the
real user's home is never used for fixture writes.

The deterministic concurrent-start replay adds the opposite admission ordering:

```sh
./scripts/go.sh run -race ./tools/verification/devtools -swift-concurrent-client
```

It calls production `FreshDevelopmentDataWithObserver` with a bounded observer
after the final process scan and before the first remove/rename, while all
admission, profile and runtime guards remain held. Only then does it launch a
new Swift writer for current, previous, a canonical symlink alias or the bundle
default. That writer must report `PROFILE_MAINTENANCE` and exit before its
production state-read acknowledgement. Both profiles stay byte-for-byte intact
until the controller releases fresh. A replacement then reads empty current
state through production preference/draft APIs and saves its own generation.
Aborting the observer must preserve data and release every guard.

The suite also requires the current built `app/macos/.build/debug/MokuseiProbe`
and `Mokusei` executables; a missing executable is a build prerequisite failure,
never a reason to substitute a mock. The actual Probe runs with `--duration 0`
inside the maintenance gate and must return its failure JSON before changing
either profile. The raw application's headless `--finish-runtime` entry point
must acknowledge that admission is busy, leave both profiles unchanged while
waiting, and exit successfully after the controller releases fresh. Its new
current directory must remain empty, without old preferences, drafts or shutdown
diagnostics; previous must still contain the original current bytes. Helper
output stays in private pipes, with bounded waits and fixture-PID-only cleanup.
The replay never starts `WorkspaceApp` or a GUI.

The same replay admits two Swift shared owners concurrently, kills one with
SIGKILL while the other keeps saving, then verifies recovery after the final
owner is killed. The surviving owner calls production `retainForProcess()` in a
short function and returns only its `RuntimeProfile`; preference/draft construction
and continued writes happen after the last local lease reference is gone. This
exercises the App/Probe process lifetime rather than a retained test-local lease.
Go's production exclusive-lease API checks these locks directly,
without a process scan. Initially missing case aliases must select one lock on
case-insensitive filesystems and distinct locks on case-sensitive filesystems.
Unsafe-lock cases place symlink, hard-link, public-mode and inaccessible files
only at never-admitted, unique temporary profiles' production lease paths. Swift
and Go must fail without changing user records or replacing those files. The
fixture removes only its own invalid entries; it never changes the admission
lock, lease namespace permissions or an established production lease file.

For baseline evidence, archive the pre-lease Swift writer and use a Go overlay
to select that source together with the old rotation path plus the same read-only
observer. A late `ready` response makes the replay continue through rotation,
replacement initialization and another real write from the old process. It
fails with `CONCURRENT_START_REPRODUCED` only after observing both replacement
preference and draft bytes overwritten. Compilation failures are not race
evidence. Normal verification always compiles the current leased writer.

Process assertions inspect only fixture PIDs and heartbeat files. Emergency
cleanup runs after those assertions, so it cannot supply the production cleanup
being tested. Fixtures remain in their assigned process groups; deliberate
detachment into a new group or session is outside this ownership contract.
