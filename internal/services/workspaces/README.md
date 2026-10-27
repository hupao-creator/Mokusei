# Workspace ownership

[manager.go](manager.go), [thread.go](thread.go) and [git.go](git.go) resolve thread execution directories, allocate temporary workspaces and own managed Git worktrees. [registry.go](registry.go) records ownership; [recovery.go](recovery.go) reconciles it on recovery. A base project directory and its managed execution worktree are distinct identities.

With `worktree: false`, an absent `cwd` allocates a unique directory under the profile's `tmp-workspaces`; an explicit `cwd` must be an existing usable absolute directory. `worktree: true` requires an explicit committed Git checkout and creates an isolated worktree under `.<repository>-mokusei-worktrees`. Callers execute in the returned worktree directory.

## Worktree names

An optional nonblank `worktreeName` requires `worktree: true`. Input longer than 64 runes is rejected. Names are normalized with NFKC/NFC; Unicode letters and digits remain, other characters become `-`, and leading/trailing `.` and `-` are trimmed. The sanitized component is capped at 48 runes before collision suffixes. An empty effective label uses generated naming.

Existing directories are never reused. Collisions try `-2` through `-8`, then a random suffix and generated-name fallback. The creation result reports the effective name, `worktreeNameAdjusted` and an explanatory notice when adjusted. A custom directory name does not change the Thread title.

## Discovery and cleanup

[discovery.go](discovery.go) normalizes discovered directories and filters managed temporary/worktree roots. [directorytag](../directorytag/directorytag.go) resolves persistent directory scopes and display labels; temporary tasks belong to Inbox rather than becoming `thread-*` directory filters. Git card observations independently use the actual execution directory, including a managed worktree.

Scope and temporary-workspace checks use host filesystem path semantics. Literal
whitespace and backslashes in macOS filenames remain part of their identity;
the filesystem root is a directory scope, distinct from Inbox.

Removal and recovery validate recorded ownership and filesystem/Git identity before cleanup. Closing a client does not release task workspaces. History/reset cleanup participates in Runtime's drained generation and preserves failure rather than deleting unknown external state.

Verification: `./scripts/go.sh run -race ./tools/verification/storage-workspaces` and `./scripts/go.sh test -race ./internal/services/workspaces ./internal/services/directorytag`.
