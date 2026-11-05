# Native Git card extensions

[NativeGitService](NativeGitService.swift) reads bounded metadata pages from the built-in [Go Git application](../../../../../internal/plugins/applications/git/README.md). [NativeGitWorkspaceModel](NativeGitWorkspaceModel.swift) shares typed worktree facts with Harness card composers. Git has no separate Overview thread or enablement switch.

The card extension shows changed-file count, signed added/deleted line counts and branch. The snapshot's independent `lineStatsError` survives decoding, caching and Harness projection. Failed line counts display a reason (limit, timeout or unavailable); unknown counts display an unknown label. Neither state displays signed dashes, zeroes or a loading indicator: observations arrive after the bounded statistics attempt. A status/polling failure retains the last successful values with a visible stale label; a line-only failure keeps fresh file counts at full opacity. A confirmed clean result removes the extension. The extension is read-only metadata and has no diff action or dedicated reading route. Clicking the owning task card retains normal Agent navigation.

The native host retains the Git monitor, metadata polling, strict snapshot decoding and Harness card projection. The Go application's `git.files` and `git.diff` queries remain independent on-demand APIs; removing the native panel does not remove those queries or change other diff presentations.

Verification from the repository root:

```sh
MOKUSEI_GIT_CONTRACT_EVIDENCE=/tmp/mokusei-git-contract.json \
  ./scripts/go.sh run -race ./tools/verification/git
MOKUSEI_GIT_CONTRACT_EVIDENCE=/tmp/mokusei-git-contract.json \
  xcrun swift test --package-path app/macos --no-parallel \
  --filter 'GitNativeTests|GitThreadExtensionTests|NativeArchivedThreadsTests|NativeOverviewSearchTests'
```

The Go replay creates disposable repositories. The Swift suites consume its production metadata fixtures and cover card composition and known/unknown/failed/stale statistics in Chinese and English. Set `MOKUSEI_GIT_ARTIFACTS` to retain native card captures.

For the diff-panel removal Sprint, validation is limited to static checks/builds and local diff review. Tests and replays are not run; pointer behavior and accessibility require later interactive acceptance.
