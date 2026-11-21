# Workspace ownership

[manager.go](manager.go), [thread.go](thread.go) and [git.go](git.go) resolve thread execution directories, allocate temporary workspaces and own managed Git worktrees. [registry.go](registry.go) records ownership; [recovery.go](recovery.go) reconciles it on recovery. A base project directory and its managed execution worktree are distinct identities.

With `worktree: false`, an absent `cwd` allocates a unique directory under the profile's `tmp-workspaces`; an explicit `cwd` must be an existing usable absolute directory. `worktree: true` requires an explicit committed Git checkout and creates an isolated worktree at detached HEAD under `.<repository>-chief-worktrees`. It does not create a branch. Callers execute in the returned execution directory, preserving the selected subdirectory when the base `cwd` is inside the repository.

Previously owned worktrees in `.<repository>-mokusei-worktrees` retain their
paths. They pass the same private staging, Git registration and persisted
ownership checks for access and removal. Both staging suffixes are recognized
when deriving directory labels or recovering an existing execution workspace.

## Worktree names

An optional nonblank `worktreeName` requires `worktree: true`. Input longer than 64 runes is rejected. Names are normalized with NFKC/NFC; Unicode letters and digits remain, other characters become `-`, and leading/trailing `.` and `-` are trimmed. The sanitized component is capped at 48 runes before collision suffixes. An empty effective label uses generated naming.

Existing directories are never reused. Collisions try `-2` through `-8`, then a random suffix and generated-name fallback. The creation result reports the effective name, `worktreeNameAdjusted` and an explanatory notice when adjusted. A custom directory name does not change the Thread title.

## Discovery and cleanup

[discovery.go](discovery.go) normalizes discovered directories and filters managed temporary/worktree roots. [directorytag](../directorytag/directorytag.go) resolves persistent directory scopes and display labels; temporary tasks belong to Inbox rather than becoming `thread-*` directory filters. Git card observations independently use the actual execution directory, including a managed worktree.

Scope and temporary-workspace checks use host filesystem path semantics. Literal
whitespace and backslashes in macOS filenames remain part of their identity;
the filesystem root is a directory scope, distinct from Inbox.

Removal and recovery validate recorded ownership and filesystem/Git identity before cleanup. Closing a client does not release task workspaces. History/reset cleanup participates in Runtime's drained generation and preserves failure rather than deleting unknown external state.

## Explicit removal

Chief can retire one ordinary Thread's managed checkout. The [workspace manager](remove.go)
resolves the registered root from the Thread's base and execution cwd and its private
ownership proof. A committed rename or removal of the selected execution
subdirectory leaves that root binding intact. The
linked checkout, repository, staging directory, Git metadata pointers and detached
HEAD must still pass managed-workspace inspection.

The manager compares the HEAD tree, stage-zero index entries and the physical
checkout. It hashes regular file bytes and symlink targets and checks Git file
types and the executable bit independently of Git's stat cache. The corresponding
Git objects must exist in shared storage without a lazy fetch. Extra entries,
including ignored files and empty directories, keep the checkout in place.
The private ownership record stores the path and filesystem identity of each
execution-path directory Chief actually creates. A directory whose recorded
identity includes a verifiable birth time can remain empty or contain the rest
of that recorded chain. Its contents are still walked. The manager retains
extra directories when birth time or creation evidence is unavailable.
Masked or unresolved index entries, Git submodules, active checkout conversions
(such as clean filters or explicit EOL conversion) and unknown private Git state
also prevent removal. Inspection leaves the index in place and uses the Git
runner's 10-second and 1 MiB per-command bounds. With `core.autocrlf=false`,
`text=auto` is supported when the physical bytes match the committed blobs.

For files-based Git refs, the manager reads HEAD, ORIG_HEAD, loose private refs
and both endpoints of every private reflog entry. Every ordinary or
`not-for-merge` row of `FETCH_HEAD` must name a verifiable commit. It checks up to 1 MiB of
recovery records. Every commit must be reachable from a direct shared branch,
remote-tracking branch or tag in the surviving repository. Symbolic refs,
alternate object stores and grafted history cannot establish retention.

Runtime drains the idle native handle under the Thread command and cancellation
gates. Workspace creation and removal exclude one another through publication.
Any other public or private session using the checkout or its private Git
directory, including a descendant reached by an alias, keeps it in place.
Independent writers should finish or lock the checkout before cleanup. Git and
the filesystem provide no atomic exclusion against unrelated edits or ref moves.

The manager persists removal intent before ordinary `git worktree remove`.
It checks the base identity, registration, private Git directory and checkout
after Git exits, including on error. If only the registration remains, the same
Thread can retry after access is restored. A persisted intent, matching admin
directory identity and backlinks, unique registration, detached HEAD, clean
remaining index and retained private history are required for the targeted Git
retry. Locks and other workspace users still block it. Once Git unregisters the checkout, the
manager records that stage and Runtime retires the Thread's execution cwd.
Retries can finish outstanding writes after restart. Both directory names stay
reserved for managed allocation until the Thread and ownership updates finish.
If files or a replacement remain, the receipt names the retained path. The
caller can inspect and relocate the remainder and retry the same Thread.
Only confirmed absence and completed ownership cleanup yield success.

[PBT-MOKU-WORKTREE](../../../tools/verification/pbt/README.md) invokes the tool
from a Chief Harness injection against real Git and SQLite in temporary directories.
