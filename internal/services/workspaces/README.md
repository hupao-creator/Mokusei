# Workspace ownership

[manager.go](manager.go), [thread.go](thread.go) and [git.go](git.go) resolve thread execution directories, allocate temporary workspaces and own managed Git worktrees. [registry.go](registry.go) records ownership; [recovery.go](recovery.go) reconciles it on recovery. A base project directory and its managed execution worktree are distinct identities.

With `worktree: false`, an absent `cwd` allocates a unique directory under the profile's `tmp-workspaces`; an explicit `cwd` must be an existing usable absolute directory. `worktree: true` requires an explicit committed Git checkout and creates an isolated worktree at detached HEAD under `.<repository>-mokusei-worktrees`. It does not create a branch. Callers execute in the returned execution directory, preserving the selected subdirectory when the base `cwd` is inside the repository.

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
ownership proof. The selected execution directory can be below that root. The
linked checkout, repository, staging directory, Git metadata pointers and detached
HEAD must still pass managed-workspace inspection.

Removal checks the whole checkout, including staged, unstaged, untracked and
ignored files. Hidden index entries (assume-unchanged or skip-worktree) and
in-progress Git operations can prevent removal. Inspection uses the workspace
Git runner’s 10-second and 1 MiB per-command limits. The detached HEAD and commits in
its HEAD reflog must be reachable from a branch, remote-tracking branch or tag.
Git performs the final lock and cleanliness checks with ordinary
`git worktree remove -- <root>`. Independent writers should finish their work
or lock the checkout before requesting cleanup. Git and the filesystem provide
no atomic exclusion against an unrelated process that edits the directory during removal.

Runtime drains an idle native handle, fences admission and checks other workspace
users before removal. New Thread registration and removal are mutually exclusive.
Another Thread whose base or execution directory uses the checkout keeps it in
place, including an archived Thread. The [Runtime](../../core/runtime/worktree.go)
records the former execution cwd on the same Thread and then retires its ownership
proof. If Git succeeds before the Thread write, a retry can finish recording absence
once the proven root and its registration metadata are both gone. A replacement
directory must pass the original identity checks.

[PBT-MOKU-WORKTREE](../../../tools/verification/pbt/README.md) invokes the tool
from a Chief Harness injection against real Git and SQLite in temporary directories.
