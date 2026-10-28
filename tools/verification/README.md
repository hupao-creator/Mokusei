# Functional integration replays

Retained evidence uses neutral `/Users/example` paths and numbered `.worktrees`
directories. Archive owner names are also anonymized. Evidence-file and archive
checksums describe the sanitized copies; measurements and historical build
identities are retained. Repacked archives preserve their member names and order.

`make check-modules` separately runs offline, race-enabled [plugin module tests](../../internal/plugins/README.md), Runtime and Moku tests. It is included in `make check`; the replays below continue to cover cross-module production boundaries.

`make check-swift`, also included in `make check`, runs all Swift tests. Native
cases share process-wide test isolation; display and fixture requirements appear
as explicit skips. See the [Swift failure audit](swift-tests/README.md) for the
baseline comparison, headless admission and the eight XCTest fixture skips.

For real native CLI + mock LLM combinations spanning Moku, child tasks, scoped
Report/Tag, faults, public actions and restart, see [Moku system verification](moku-system/README.md)
and `make check-system` (requires `MOKUSEI_SYSTEM_CODEX`).
`make check-stability` adds real daemon SIGKILL/recovery and a continuous
30-minute, minimum-100-cycle resource gate with owned-process exit checks.
It also requires a new `STABILITY_OUTPUT` evidence directory and is deliberately
separate from the fast checks.

For the sequential release gate runner, retained JSON/log evidence, isolated
headless lifecycle checks and optional installed-CLI mock-provider verification,
see [release runtime health](release-health/README.md).

For shared native loading-cloud motion, see the [Swift cloud replay](cloud-motion/README.md).
For Note viewport evidence and authenticated Swift/Runtime/context round trips,
see the [Note replay](moku-note/README.md). Its native launcher, Talk dismissal
and reading-presentation stage inputs, build artifacts and resources in temporary
workspaces, retain path/PID diagnostics and clean up the owned app on timeout.
Run SwiftPM builds and native replays serially; never grant Desktop access to
work around an incorrectly staged fixture or resource.
For Overview camera input and context-menu absence checks, see the [isolated AppKit replay](overview-input/README.md).
For the research-only comparison removing all Thread-card Liquid Glass, see the [isolated glass benchmark and Chinese report](overview-glass/README.md).
`python3 tools/verification/overview-centering/verify-geometry.py` checks the current
production camera's framing anchor through AppKit without requiring Git history.
Its 90 cases assert the midpoint between fixed toolbar/Dock boundaries, including
translated and overflowing content; `NativeOverviewCenteringTests` separately
covers the mounted workspace's real control geometry.
For script-driven navigation of the real macOS app, protocol validation and seeded
chaos traces, see the [semantic interaction replay](native-interaction/README.md).
For mounted conversation/history controls, disclosure, scrolling and 150-turn
windowing in the same production app, see the [reading interaction replay](thread-interaction/README.md).

Run from the repository root with `./scripts/go.sh`. These executable integration drivers complement the package tests. They exercise production boundaries against fixed protocol fixtures, temporary databases/profiles or loopback model services. Failures return nonzero. Build the runtime with `make runtime` before the native settings launcher.

The runtime-helper replay also keeps a real zombie child unreaped after its
process-group leader exits. It verifies macOS's `EPERM` probe result and calls
production cleanup before and after reaping, alongside the live-descendant
drain scenario. No user runtime or external Harness is used for these fixtures.

Property-based tests complement the executable replays: `make pbt` runs Rapid
with the race detector against Runtime/SQLite admission schedules and Codex
terminal-state transitions. It is included in `make check`. Increase generation
with `make pbt ARGS='-rapid.checks=1000 -count=1'`. Failures print a seed and a
minimized `testdata/rapid` replay file; rerun with the printed `-rapid.seed` or
`-rapid.failfile`. See [the contract](../../internal/plugins/harness/codex/README.md).

| Command after `./scripts/go.sh run -race` | Boundary exercised |
| --- | --- |
| `./tools/verification/transport` | HTTP/NDJSON, identity/privacy, admission, clients, bounded concurrent content, stalled file-worker and admitted-command cancellation with joined shutdown, Overview and host command receipts |
| `./tools/verification/transport -swift-deltas` | Current Go content delta producer consumed by real Swift Core: Unicode, array edits, exact keys and null/absence |
| `./tools/verification/transport -swift-files` | Real Swift file upload/download against Go transport: regular-file symlinks, prompt FIFO rejection and `.partial` basename retention; no GUI |
| `./tools/verification/transport -swift-settings-capacity` | Real Swift cold settings burst through Go's unchanged request limit: four Harnesses/four scopes plus installation reads, command headroom, queued/active cancellation and recovery |
| `./tools/verification/thread-metadata` | Generated titles/emoji, subsequent messages, steer, completion races, timed retries, reopen and cancellation |
| `./tools/verification/runtime` | Health client through production HTTP/NDJSON/SQLite (continuation identity, detached read, stale interaction rejection, interrupt and fork); Runtime/SQLite, bounded projection workers/byte admission and detached cache, execution lifecycle, steering, fork/delete, settings, private sessions, tags, restart/history, Report question reads through Harness and cancellation; production scoped Report runners, evidence/domain isolation, steering, idle disposal and durable recovery |
| `./tools/verification/runtime -swift-voice` | Actual Swift integer JSON encoding → Go DTOs and Runtime thread voice history, prepare, initial poll, SDP start, event cursor, stop; exact integer precision |
| `./tools/verification/runtime-concurrency` | Pending admission/open/fork/delete/interrupt; two-client execution-fenced cancellation and native successor races; thread settings CAS; native settings snapshot convergence, initialized reads, source fences and concurrent saves; first-answer claims; host drain admission |
| `./tools/verification/runtime-helpers` | Pipe-independent descendant drain after leader exit, attachments, environment acquisition, owned process cleanup and detached daemon lifecycle, including failed-shutdown diagnostics and same-profile restart |
| `./tools/verification/runtime-helpers --swift-shutdown` | The same replay plus real Swift status/start/repeated stop through failed shutdown, immediate reopen, replacement-epoch protection and dead/live owner port reuse; private metadata and cancellation stay fail-closed |
| `./tools/verification/console-oauth` | Native Console callback grant exclusion, refresh rotation, account pinning, expiry and concurrency with synthetic facts |
| `./tools/verification/command-boundaries` | Real runtime validation of required fields, nulls, UTF-8 JSON and UTF-16 string bounds; public media URLs, annotation URL normalization through attachment admission, and UTF-8 project-file pagination |
| `./tools/verification/storage-workspaces` | Actual SQLite abort/crash recovery and local Git ownership/write/cleanup fences |
| `./tools/verification/devtools` | Build serialization/cancellation, stale input rejection, running-app installation guard and architecture scan scope |
| `./tools/verification/devtools -swift-offline-client` | Fresh rotation against live production Swift preference/draft writers without a runtime; current/backup, aliases, default Foundation profile, old generations and unrelated profiles |
| `./tools/verification/devtools -swift-concurrent-client` | Deterministic final-scan startup race through production profile leases; both admission orders, shared clients, crash release, observer abort, invalid locks and pre-creation aliases |
| `./tools/verification/maintenance` | Pinned allowance literal extraction without source execution |
| `./tools/verification/git` | Real Git monitor, escaped paths, linked worktrees, files/diff, read-only boundaries, thread-directory membership, stale observations, cancellation and SQLite identities |
| `./tools/verification/applicationhost` | Real Report domain, scopes/receipts, lifecycle and durable reopen |
| `./tools/verification/moku` | Coordinator, saved/applied settings, real runtime/SQLite, public admission-fenced cancellation, tools, and authenticated HTTP → Runtime → coordinator voice envelopes/drain plus synthetic media ownership/takeover/revocation |
| `./tools/verification/claude` | Native protocol fixture and real Go MCP subprocess |
| `./tools/verification/codex` | Codex protocol replay; see its README for the real CLI/local provider mode |
| `./tools/verification/pi -mode all` | Protocol plus real Pi/host extension/read guard with local provider |
| `./tools/verification/opencode` | Settings, credentials, timeout and frozen renderer comparison; see README for native CLI cases |
| `./tools/verification/settings` | Real Swift settings flow against Go daemon and external CLI fixture; workspace prefetch, scope cache, HTTP read coalescing, bounded failure retry, teardown, installation invalidation and reconnect |
| `./tools/verification/settings-shell` | Schema, normalization, CAS, diagnostic bounds and redaction |
| `./tools/verification/artificialanalysis` | [Intelligence Index v5](artificialanalysis/README.md) version/metric contracts, cache isolation, cold/warm cache, detail/provenance matching and output bounds; opt-in live website check |
| `./tools/verification/artificialanalysis/lifecycle` | Independent Context host registration/enablement, runtime catalog/settings/history reset, shared acquisition, cancellation, drain, fallback and bounds |

External CLI versions, optional flags and limits are documented by each Harness runner. Native fixtures do not prove production account authentication, provider billing, microphone/audio hardware or paid service availability. Moku voice uses synthetic voice transports.

The Runtime replay also drives the production Tag and Report participants with
inherited and independent execution profiles. Gated native discovery checks
settings-save conflicts without batch retry consumption, validation of matching
idle-session reuse, unchanged admitted steering and next-batch profile adoption.
It also checks cold Open settlement of an orphan and background work that needs
Close after Interrupt, including native state flushes during cleanup.
