# Git worktree extensions

Git is built into agent thread cards. It has no separate overview card, archived
thread, directory-filter member, or plugin switch. Implementation lives in [monitor.go](monitor.go), [client.go](client.go), [domain.go](domain.go) and [line_stats.go](line_stats.go).

The runtime reads current ordinary thread execution directories (managed
`worktree.cwd` when present, otherwise `cwd`), including archived threads, about
every five seconds. The project base directory is not used for a managed-worktree
thread. It resolves each directory to its canonical
Git worktree, deduplicates worktree status reads, and shares the complete state
with every thread in that worktree. Subdirectories and symlinks resolve to the
same identity; linked worktrees remain independent. Only worktrees referenced by
current thread directories are observed. Directory changes, task deletion and
confirmed missing/non-Git paths remove obsolete associations. There are no retained
discovery seeds or automatic sibling-worktree scans.

Each reconciliation uses an attempt timestamp after the latest persisted
attempt, including after a monitor restart or wall-clock rollback. This keeps
fresh observations and deletions moving forward while rejecting late batches
from earlier attempts.

The extension displays only the changed-file count, signed added/deleted line
counts and branch name. It has no Git title/logo, repository name/path, category
counts or upstream row. Numbers reuse the token count's rolling-digit animation;
health is available through opacity and accessible help.

Line counts use a net tracked diff against the observed HEAD plus current
untracked text. Binary files contribute no text lines; submodule contents are
excluded. Unborn worktrees compare current files against an empty baseline.
Statistics use numstat rather than patches, a three-second shared deadline and at
most 256 individual untracked/unborn paths. Unavailable, bounded-out or ambiguous
index-deleted/untracked replacements retain null totals and a `lineStatsError`
(`too-large`, `timeout`, `unavailable` or `inaccessible`), rather than partial or
repeated totals. Added/deleted counts are always both known or both unknown;
an error cannot accompany numeric totals. File counts remain fresh if only line
statistics fail. Each monitor observation publishes status and the completed
statistics attempt together, so missing totals are unknown/failed, not pending.
The native card shows the failure reason or an explicit unknown label, and
retains signed zeroes for known binary/empty/mode-only changes.

File membership follows Git's ignore rules; generated files are not heuristically
filtered by the monitor. This repository ignores root `.scratch/`, where native
replays and local compiler caches write disposable artifacts. Other untracked
files and already tracked paths under ignored directories still count normally.

The extension appears only for changed files, conflicts, or locally known
ahead/behind commits. Clean worktrees, non-Git directories, initial failures and
unknown upstream comparisons alone do not create extensions. A transient read
error retains the last successful status and marks it stale. Git results do not
change thread order, tags, filter counts or archive state. Visibility changes use
the same card composition and overview layout transitions as other extensions.

Clicking the extension opens the existing native diff reader, with normal back
navigation, staged/unstaged/untracked/conflict categories, file selection,
repository switching among observed worktrees, refresh, selectable source,
copying, line numbers and syntax annotation. Clean observations stay available
while a reader is open. No historical patches are retained.

The service uses internal application-domain collection/query infrastructure,
without registering a Git thread type. Its built-in manifest is always enabled
and excluded from the user plugin catalog. Current observations are stored in
`git.worktrees`; the native host polls bounded metadata pages and injects typed
Git facts into every shipped Harness's shared card composer. Diffs remain
on-demand external queries rather than catalog contents.

Git commands remain read-only, cancellable, timeout/output limited, with a shared
concurrency limit of two. No fetch, index write, commit, checkout or reset feature
is exposed. Paths are authorized against fresh NUL-framed status, use literal
pathspecs, and disable external diff, text conversion and fsmonitor hooks.

See the [native reader](../../../../app/macos/Sources/Host/Git/README.md).

Verification: `./scripts/go.sh run -race ./tools/verification/git` from the repository root. This exercises disposable repositories and the real process capability, application host and SQLite store.
