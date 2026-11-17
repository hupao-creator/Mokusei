# Native Git card extensions

[NativeGitService](NativeGitService.swift) reads bounded metadata pages from the built-in [Go Git application](../../../../../internal/plugins/applications/git/README.md). [NativeGitWorkspaceModel](NativeGitWorkspaceModel.swift) shares typed worktree facts with Harness card composers. Git has no separate Overview thread or enablement switch.

The card extension shows changed-file count, signed added/deleted line counts and branch. The snapshot's independent `lineStatsError` survives decoding, caching and Harness projection. Failed line counts display a reason (limit, timeout or unavailable); unknown counts display an unknown label. Neither state displays signed dashes, zeroes or a loading indicator: observations arrive after the bounded statistics attempt. A status/polling failure retains the last successful values with a visible stale label; a line-only failure keeps fresh file counts at full opacity. Known added/deleted totals of zero remove the entire extension before card composition, even when changed files or HEAD exist. Binary-only, pure rename, mode-only and empty-file changes have no exception; nonzero added or deleted totals still show the extension. Unknown/failed statistics retain their existing file-count/error presentation rather than being interpreted as zero. Hidden Git contributes no placement, footprint or structural-key segment; other extensions compose normally. The extension is read-only metadata and has no diff action or dedicated reading route. Clicking the owning task card retains normal Agent navigation.

The native host retains the Git monitor, metadata polling, strict snapshot decoding and Harness card projection. The Go application's `git.files` and `git.diff` queries remain independent on-demand APIs; removing the native panel does not remove those queries or change other diff presentations.

Verification from the repository root:

```sh
MOKUSEI_GIT_CONTRACT_EVIDENCE=/tmp/mokusei-git-contract.json \
  ./scripts/go.sh run -race ./tools/verification/git
MOKUSEI_GIT_CONTRACT_EVIDENCE=/tmp/mokusei-git-contract.json \
  xcrun swift test --package-path app/macos --no-parallel \
  --filter 'GitNativeTests|GitThreadExtensionTests|NativeArchivedThreadsTests'
```

The Go replay creates disposable repositories. The Swift suites consume its production metadata fixtures and cover host admission, all four Harness projections, zero-line footprint removal, and known/unknown/failed/stale statistics in Chinese and English. For headless-only work, select the four non-display methods in `GitThreadExtensionTests`; its display/animation methods are separate GUI validation and are not covered by that selection. Set `MOKUSEI_GIT_ARTIFACTS` to retain native card captures.

Default CI generates the Git contract with the other Go fixtures before the
windowless Swift run. Missing evidence fails `GitNativeTests` explicitly. For a
local `make check-swift`, generate the evidence with the command above and export
`MOKUSEI_GIT_CONTRACT_EVIDENCE` into that invocation as well. Passing without
reading the Go output is not contract coverage.
