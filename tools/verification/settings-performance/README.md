# Harness settings read performance

This work is based on `a4e7db866883bada3b94ba771c93ba574188ecf7` (the Overview
camera fix) in a detached worktree. It changes settings acquisition, not Report
prompts or the separately developed Settings Map. The base checkout and shared
branch refs are not operated on; integration belongs to the caller.

## Design and boundaries

The expensive work was repeated native acquisition, not JSON decoding:

- Automatic installation polling refreshed the login shell and executable cache
  every 15 seconds and returned only after every Harness finished. The client now
  requests each installation independently; automatic reads reuse a five-minute
  environment snapshot. Explicit batch recovery refreshes it once. A fast,
  selected host can render while another installation is still checking.
- Claude's cold catalog had no in-flight sharing. Codex shared its catalog but
  opened separate servers for execution defaults and auto-review. Both now use
  cancellation-safe shared discovery. Codex reads native configuration and
  capabilities on the same server, reuses its resolved CLI version, and caches
  successful version facts by binary generation.
- Pi keyed flights by `needCatalog`; concurrent basic/full probes could duplicate
  processes, and a late basic reply could replace a complete catalog. Full
  readers now upgrade/join the same flight. A too-late upgrade retries only after
  the first process drains. Independent model/thinking RPCs run concurrently.
- OpenCode initial execution capture invalidated all catalogs, and presentation
  waited for optional account leases and billing. Initial capture now shares
  discovery. Presentation receives immutable native facts first, marked
  `accountCheckPending`; exact validation still waits for the filtered result.
  The account phase is bounded and SettingsAPI-owned, with cancellation/drain on
  Close. The Swift editor shows uncertainty and makes bounded, non-forced rereads.

Refresh supersedes only the matching source; concurrent forced refresh readers
join. Old flights cannot publish over a replacement, including when the newer
refresh fails. Each caller can cancel without aborting other readers; the last
reader cancels unfinished acquisition. Native cleanup failures survive the reader
and Close, and prevent replacement discovery in the shared cache/Pi owner.

Keys include adapter-owned settings/cwd, native environment and relevant native
configuration file metadata. OpenCode additionally includes ConfigurationCWD.
Claude's replay changes both profile path and a native configuration file and
checks the actual returned catalog. Codex/OpenCode reject a source change during
native acquisition. Existing settings CAS and execution-profile source fences
remain authoritative; discovery never writes a replacement model or user draft.

Successful catalogs retain their existing five-minute horizon. Failed refreshes
do not renew old success; last-good cache entries are retained without being
returned as a fresh authentication verdict. Existing native editors keep usable
values while a reload is pending, and retain their existing failure presentation.
The connected workspace now revalidates retained presentations every five minutes,
independently of installation changes. No disk cache, credential persistence,
new built-in model list, live-runtime pool or extra per-execution remote check is
introduced. File fingerprints are not a complete native configuration watcher:
keychain changes, transitive includes and remote account changes still rely on
TTL/manual refresh and native execution authority.

## Reproduce measurements

```sh
python3 tools/verification/settings-performance/measure.py \
  --ref a4e7db866883bada3b94ba771c93ba574188ecf7
python3 tools/verification/settings-performance/measure.py
```

The script reads baseline Go files with `git show` and builds using Go's temporary
source overlay. It never switches HEAD or edits another worktree. Each sample
runs a fresh verifier process with isolated fixture homes, eight simultaneous
readers, a cold phase and an immediate warm phase. Native processes use the real
production pipe/RPC adapters. Codex/Claude inject 200 ms native startup work; Pi
injects 200 ms per state response (the native startup also reads state). There
are no generated model requests or real accounts. Reported milliseconds exclude
Go compilation but include native startup, RPC, projection and process cleanup.

Measurements were taken on Apple Silicon macOS with Go 1.27.3 and Swift 6.3.2,
without the race detector for timing. Three sequential samples per Harness and
revision are retained in [baseline.txt](baseline.txt) and
[optimized.txt](optimized.txt). These are fixture measurements, not installed-CLI
or real-network performance claims. Scheduler variation matters below 1 ms.

| Harness / phase | Baseline median ms | Optimized median ms | Native process starts in that phase (before → after) |
| --- | ---: | ---: | --- |
| Claude cold | 252.93 | 243.49 | 8 → 1 |
| Claude warm | 0.20 | 0.64 | 0 → 0 |
| Codex cold, catalog + defaults | 236.31 | 236.39 | 5 → 1 |
| Codex warm, catalog + defaults | 219.54 | 0.16 | 4 → 0 |
| Pi cold, state + catalog | 431.01 | 428.39 | 2 → 1 |
| Pi warm, state + catalog | 0.79 | 0.42 | 0–1 → 0 |

Cold wall time remains dominated by the deliberately delayed native fixture;
reducing concurrent process count is not equivalent to the same latency speedup.
Claude warm reads add approximately 0.44 ms in this sample because they fingerprint
the source instead of accepting a path-only hit. Pi's baseline has one warm sample
that launches another process (419.77 ms): a competing state-only result can evict
the full catalog. The new mixed-reader replay asserts one process for both phases.
The raw outputs are authoritative for exact samples.

The OpenCode slow-account regression holds the native account endpoint behind a
barrier: presentation must return native models with uncertainty while exact
validation remains blocked, then the complete result must apply credential
filtering without mutating the earlier projection. The existing subprocess
settings replay also drops from four to three process starts/exits after removing
the initialization invalidation. Installation tests prove eight automatic reads
perform no forced environment refresh, and that one slow Harness does not block
an independent fast response. Resolver tests prove warm environment reuse,
explicit refresh and TTL expiry with a real fixture login-shell process.

## Fixed upstream implementations inspected

- [T3 Code managedProvider.ts at d145077](https://github.com/pingdotgg/t3code/blob/d145077b4f7dc9e476bacf346e3f2c04cc141d6d/packages/provider-core/src/server/managedProvider.ts): initial snapshot is created before a scoped background check; enrichment uses generation fences, while settings/interval refreshes are separately owned. Adopted the separation and publication fences. We do not infer all drivers' TTLs from this helper.
- [T3 Code ClaudeDriver.ts at the same commit](https://github.com/pingdotgg/t3code/blob/d145077b4f7dc9e476bacf346e3f2c04cc141d6d/apps/server/src/provider/Drivers/ClaudeDriver.ts): per-instance capabilities cache uses binary/resolved HOME identity; fresh usage receives five minutes, failures/fallbacks do not. Adopted source isolation and success-only freshness, not its account probe contract.
- [T3 Code providerStatusCache.ts at the same commit](https://github.com/pingdotgg/t3code/blob/d145077b4f7dc9e476bacf346e3f2c04cc141d6d/apps/server/src/provider/providerStatusCache.ts): schema-checked disk helpers, atomic writes, instance/driver correlation and current custom-setting precedence are present. Disk snapshots were not adopted: cross-launch account validity and complete native configuration identity need a larger contract. We did not establish that these disk helpers precede checks in every current driver; the directly verified startup ordering above is the managed-provider path.
- [Cezar v0.16.1 RunnerModelCatalog, c78ef048](https://github.com/open-mercato/cezar/blob/c78ef04887301651ec234e772350cb76b4745f96/packages/cezar/src/core/runner-model-catalog.ts): real implementation has a shared in-flight promise, five-minute refresh horizon, background renewal and last-good/failure-source reporting. Adopted deduplication and separating visible facts from renewal. Its runner-only key and one-hour usable horizon are not appropriate for this project's cwd/config/account-sensitive execution settings.

These references were fetched through the GitHub connector at fixed commits.
The web tool could not retrieve the GitHub API URLs; the connector did. No issue
comment or unverified documentation was used as evidence of current runtime
behavior. In particular, this report does not claim to have audited all Cezar
provider-status/admission paths or all T3 driver TTLs.

## Changed ownership boundaries

| Area | Production files |
| --- | --- |
| Shared probe ownership and identity | `internal/platform/discovery/{cache,identity}.go` |
| Environment / independent installation command / stage tracing | `internal/platform/environment/resolver.go`, `internal/core/runtime/{commands,settings}.go`, `internal/core/model/{commands,command_validation}.go` |
| Native catalog acquisition | `internal/plugins/harness/claude/{harness,settings}.go`, `codex/{adapter,catalog,executable,transport}.go`, `pi/{adapter,settings}.go`, `opencode/{catalog,settings}.go` |
| Workspace acquisition and partial state | `app/macos/Sources/Host/Settings/{NativeSettingsModel,NativeMokuSettings}.swift`, `Host/Shell/{NativeWorkspaceModel,NativeWorkspaceSettingsPrefetch}.swift`, `Host/HarnessHost/NativeHarnessHost.swift`, `Plugins/Harnesses/OpenCode/OpenCodeSettings.swift` |

## Validation and handoff

Passed on this implementation:

- `make check ARGS=`: formatting, architecture/static registration/no-Node,
  Go vet/build, Swift build/tests, concurrency properties, module tests (including
  discovery/environment race tests) and directory-tag checks.
- `./scripts/go.sh run -race ./tools/verification/codex`
- `./scripts/go.sh run -race ./tools/verification/claude`
- `./scripts/go.sh run -race ./tools/verification/pi`
- `./scripts/go.sh run ./tools/verification/opencode -case settings`
- `./scripts/go.sh run -race ./tools/verification/runtime-concurrency`
- `./scripts/go.sh run -race ./tools/verification/settings-shell`
- `./scripts/go.sh run -race ./tools/verification/command-boundaries`
- Rebuilt `.build/go/mokusei-runtime`, then ran
  `./scripts/go.sh run ./tools/verification/settings`: real Swift/Go/SQLite
  settings flow, prefetch/retry/source changes, installation invalidation,
  reconnect, draft/save/conflict and diagnostic redaction; no model calls.
- `xcrun swift test --package-path app/macos --filter NativeSettingsDiscoveryTests`:
  fast row publishes while the slow row remains pending, late retirement replies
  are fenced, and saved settings stay unchanged.
- `./scripts/go.sh test -race ./internal/plugins/harness/opencode -run
  TestSettingsPresentationDoesNotWaitForAccount -count=1 -v`: native presentation
  returned in **4.46 ms** in the local HTTP fixture while the account RPC remained
  held. Full validation waited for release and then removed the credential-less
  paid route. This is a barrier regression, not a real billing latency benchmark.

Shared discovery tests cover independent waiter cancellation, final-reader
cancellation, Close/drain, refresh versus old completion (including failed
refresh), failure retention, deadline publication rejection, configuration/profile
identity, and cleanup-error fencing. The existing runtime concurrency replay
covers newer user saves, initialized profiles and independent application edits.

The first `make check` inherited `ARGS=-fresh` from the environment and failed
at the property-test invocation; `make check ARGS=` is the reproducible command.
Initial sandboxed Go tests could not bind loopback ports; reruns used approved
local execution. The native settings replay initially exposed an outdated proxy
fixture: it modified the batch installation response but not the new single-row
response, causing simulated paths to oscillate. The proxy now treats both
interfaces consistently, preserving the installation invalidation/reconnect test.

Not run: installed-CLI full settings latency against the user's accounts, paid
model requests, real remote billing latency, or long-duration UI idle measurement.
The five-minute periodic path is compiled and shares the replayed prefetch/source
lifetime machinery; it is not claimed as a five-minute wall-clock soak test.

Deliver the detached commit to the integration thread. Before applying it, that
thread must inspect the base checkout's current uncommitted work and merge with
any intervening changes. This task leaves base refs/checkouts untouched and keeps
`a4e7db866883bada3b94ba771c93ba574188ecf7` as an ancestor.
