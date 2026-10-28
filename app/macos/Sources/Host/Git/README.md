# Native Git reader and card extensions

[NativeGitService](NativeGitService.swift) reads bounded metadata pages from the built-in [Go Git application](../../../../../internal/plugins/applications/git/README.md). [NativeGitWorkspaceModel](NativeGitWorkspaceModel.swift) shares typed worktree facts with Harness card composers. Git has no separate Overview thread or enablement switch.

The card extension shows changed-file count, signed added/deleted line counts and branch. The snapshot's independent `lineStatsError` survives decoding, caching and Harness projection. Failed line counts display a reason (limit, timeout or unavailable); unknown counts display an unknown label. Neither state displays signed dashes, zeroes or a loading indicator: observations arrive after the bounded statistics attempt. A status/polling failure retains the last successful values with a visible stale label; a line-only failure keeps fresh file counts at full opacity. A confirmed clean result removes the extension. Clicking it opens [NativeGitReadingPage](NativeGitReadingPage.swift) through the ordinary reading navigation. The detail model selects observed worktrees and files and requests diffs on demand.

[NativeGitDiff](NativeGitDiff.swift) parses patch data and [NativeGitSyntax](NativeGitSyntax.swift) supplies bounded lexical highlighting outside the main actor. Native text is selectable/copyable with line numbers and synchronized horizontal scrolling. The reader limits display to 12,000 patch lines and 32,768 UTF-16 units per line, in addition to the backend's patch limit. Binary, conflicts, submodules, empty and oversized content have explicit states. Navigation cancellation rejects late results. There is no merge editor or Git write command.

Verification from the repository root:

```sh
MOKUSEI_GIT_CONTRACT_EVIDENCE=/tmp/mokusei-git-contract.json \
  ./scripts/go.sh run -race ./tools/verification/git
MOKUSEI_GIT_CONTRACT_EVIDENCE=/tmp/mokusei-git-contract.json \
  xcrun swift test --package-path app/macos --no-parallel \
  --filter 'GitNativeTests|GitThreadExtensionTests|NativeArchivedThreadsTests|NativeOverviewSearchTests'
```

Git line numbers follow LF physical lines. Inline Unicode line/paragraph and
control separators render as visible single-unit glyphs within their source row;
copy uses the original text, including those separators, rather than the display
substitution. Native fixtures verify row geometry, tail visibility and exact copy.

The Go replay creates disposable repositories. The Swift suites consume its production query fixtures; native UI execution requires macOS.
The replay includes a linked worktree with 3172 ignored cache files, tracked
ignored paths, nonignored additions, line-budget failure, deadline failure and
recovery on the same file set. Swift checks failure fixtures from Go and renders
known/unknown/failed/stale card states in Chinese and English, including the
normal diff action. Set `MOKUSEI_GIT_ARTIFACTS` to retain native captures.
