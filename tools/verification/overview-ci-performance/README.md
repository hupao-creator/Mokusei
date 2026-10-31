# Foreground Overview Release measurements in CI

This verification runner measures two fixed product commits on **one macOS arm64
runner**, with one shared harness and two opposite-order pairs per condition. It
does not need a developer Mac or a local measurement agent. The
[Overview performance workflow](../../../.github/workflows/overview-performance.yml)
is independent of ordinary build/test/WindowServer-capture CI; it never cancels or
replaces that verification.

## Measurement contract

Both products use `swift build --configuration release -Xswiftc -O -Xswiftc
-enable-testing`. The probe itself also uses `-O -enable-testing`, links the
corresponding Release product objects, and carries the packaged product
resources. `-enable-testing` exposes existing verification seams identically on
both sides. Core uses ordinary optimized `go build`, without `-race`. There is no
diagnostic build, sampling profiler or screenshot capture in the CPU matrix.

Each invocation receives full baseline and candidate commit SHAs. The runner
creates detached worktrees and copies the **same current Swift/Go/Python harness
sources** into both. Product source, plugin and module files must remain unchanged.
It builds each side once, then launches a fresh application/Core process per run.
The source-event clock belongs to the Go Core host, not the UI consumer. Updates
travel through the production store, publication, HTTP/NDJSON and Overview model.

All conditions use N=40, four running 2×1 cards fully visible in the foreground,
fixed camera, dark appearance, glass, and enabled motion/transparency. Each run
has five seconds of load-bearing warmup and twenty seconds of formal supply.

| Condition | Content input | Source rate |
| --- | --- | --- |
| R0 | Four running cards; no new content | 0/s |
| S4 | Replaces a bounded sliding text window; this is rewrite, not cumulative streaming | 10/s/card, 40/s total, staggered |
| A4 | Strict cumulative append of a deterministic text fixture | 10/s/card, 40/s total, staggered |

Order is `R0 A→B`, `S4 A→B`, `A4 A→B`, then `A4 B→A`, `S4 B→A`, `R0 B→A`.
There are twelve independent process runs. No N100/N500, hidden/background or
occluded CPU scenarios are included. A real foreground failure is recorded as an
invalid run; it is not silently replaced by a better-looking repeat.

UI and Core CPU use their own `getrusage` user+system deltas divided by actual
monotonic wall intervals. Percentages use a **single-core scale**. Warmup, formal
and tail counters are separate. Final model sequence/hash convergence is not
proof of presented pixels; a tail stability observation is not queue drain time.
Publication wire bytes count NDJSON encoding, not confirmed socket delivery.

The UI process schedules its `warmupStart`, `formalStart` and `formalEnd` CPU
reads together, before the source warmup starts, on a dedicated serial Dispatch
queue with one-shot strict dispatch timers and zero requested leeway, avoiding
`asyncAfter`'s deadline-dependent coalescing allowance. Strict timers are still
best effort: the actual readings must satisfy the unchanged tolerance. Each
callback only captures process `getrusage` and monotonic timestamps;
it never awaits or dispatches through the MainActor. MainActor resumption reads
the saved values, so a busy Overview cannot move the next CPU boundary. The
original boundary tolerance remains −1 to +50 milliseconds. A missed boundary,
failed CPU read or cancellation invalidates the run. Completion and cancellation
share a mutex-protected, exactly-once result; cleanup cancels pending reads, whose
later callbacks do no work, and retains already captured or failed receipts.
There is no fallback to a late MainActor CPU read.

`clock` retains planned, requested, callback and actual CPU sample uptime,
corresponding Unix times, read duration and boundary offset. The 1 Hz window,
footprint and model/counter checks still run on the MainActor and retain their
own planned/start/end times and lateness under `mainActorObservations`,
`windowSamples[].observationTiming` and `counters.observationTiming`. These checks
describe the state at their actual observation times; a delayed check does not
prove the intervening window state or make its footprint an exact CPU-boundary
measurement. MainActor observation lateness is distinct from CPU sampling error.

`ui` remains the formal CPU window. `uiWindows.tailObservation` measures from the
independent formal-end sample to a new independent read immediately requested
when the existing final-model stability observation finishes.
`uiWindows.sourceThroughTailObservation` measures from the independent source
warmup-start sample through that same tail-end read. The tail request and read
times are retained, and the same 50 ms lateness limit applies. No source events
or observation periods are extended: the tail still requires ten stable 50 ms
observations within its five-second budget. Pending installations, actual
formal-end sequences and post-formal receipts remain visible; saturating one
core while consuming fewer publications is not evidence of equal work.

The two additional windows include observation overhead and, when present,
post-supply backlog. They are not queue drain durations or isolated per-event
costs, and must not be added to Core's formal-only CPU. Source-through-tail
comparisons require identical accepted inputs and final sequence/hash state.
Environment subprocesses, fetching the complete Core report, final hashes and
full JSON receipt encoding happen after the tail-end CPU sample. Source supply
remains five seconds of warmup plus twenty seconds of formal input in every run.

## Display and environment validity

Four 2×1 cards at the production minimum camera scale cannot fit a 1024-point-wide
hosted screen. The probe must observe a real sufficiently large window and all
four full card bounds. It may not create an offscreen oversized window or reduce
the camera below the product's valid range to pass visibility.

With `--configure-display`, only on a disposable GitHub Actions runner, the driver
enumerates **existing** CoreGraphics display modes. If necessary it chooses an
offered mode of at least 1265×800 logical pixels, preferring 1440×900, and records
the original/selected/actual modes. The change uses a session-scoped CoreGraphics
configuration transaction so it survives the setup helper's exit; a second
process confirms the mode before builds. It restores the original mode in cleanup.
It does not create a virtual display. A 1280×800 mode is admissible: the actual
window is constrained to the screen, and four-card plus whole-window containment
is the final criterion. A runner without a suitable mode fails
with capability evidence before product builds or CPU claims.

The workflow enables motion/transparency only for its disposable account. The
probe records actual window activation, visibility, screen geometry, refresh
information and thermal/power state. The Python driver records machine, Xcode,
Swift, Go, display and power observations, including power before and after every
run. Unknown or changed power sources invalidate that process. A/B power sources
and stable fixture/window/camera/display identities must also match within each
pair. Source errors,
rejected/missing events, invalid foreground conditions and missing CPU receipts
cannot become valid pairs.

## Running and reading results

The workflow runs on opening, code synchronization and reopening of relevant
pull requests whose head branch begins with `perf/overview`, including drafts.
Changing a draft to ready does not repeat the matrix solely for that metadata
event; use explicit fixed-SHA dispatch when a new base comparison is needed.
A is that PR event's base SHA; B is its head SHA. The harness
checkout is also recorded separately, since GitHub's PR checkout is a merge tree.
`workflow_dispatch` accepts explicit `baseline` and `candidate` SHAs for future
comparisons. Both revisions must be available in the checkout's full Git history.

On a Mac with an already adequate display:

```sh
python3 tools/verification/overview-ci-performance/run.py \
  --baseline <full-baseline-sha> --candidate <full-candidate-sha> \
  --output /tmp/overview-performance
```

The hosted workflow adds `--configure-display` and a 1500-second experiment
budget inside a 30-minute job timeout. Nominal measured time is five minutes;
startup, settlement, tail, two Release builds and linking account for the rest.
A cold build or unavailable runner capability may exhaust this budget; that is
an incomplete experiment, not evidence that either product is faster.

The artifact `overview-release-performance-<run>-attempt-<attempt>` retains:

- `report.md`: complete standalone report, every raw formal run, opposite-order
  paired deltas, source accounting, per-card convergence, memory and environment.
- `report.json`: machine-readable aggregate with original UI/Core results.
- `runs/<id>/`: original UI/Core JSON and logs, native launch/process receipts,
  before/after machine observations and owned-process cleanup evidence.
- `builds/A/`, `builds/B/`: commands, logs, product-file inventories, harness digest,
  actual commit/Git tree, signed probe SHA256 and Core executable SHA256.
- Display capability/restore records and retained failure diagnostics.

Temporary runtime authentication data is not part of the report. Ready receipts
retain only process identity and the loopback control endpoint after shutdown.
The fixed synthetic text is harness-owned; no developer conversation is needed.

Core identity keeps the PID and parent-PID checks. On the runner, reported and
staged executable paths must strictly resolve to regular files with the same
device and inode, so `/var` and `/private/var` aliases identify the same staged
binary without relaxing ownership. `runtimeIdentity` retains raw/resolved paths
and file identity. Cleanup checks both the launch receipt and the current `ps`
executable against that same staged file before signaling an owned process.

Product-input hashes include tracked files under macOS Sources/Plugins, Package
files, `internal/`, `cmd/` and Go module files. The inventory stores every file's
SHA256; its aggregate is SHA256 of sorted relative path, NUL, file SHA256 hex and
LF. These hashes have an explicit algorithm and must not be equated to a hash
from an older harness with a different inventory/algorithm.

A green performance job means the prescribed runs completed with valid
measurement conditions. **It does not assert a CPU improvement.** Deltas are B−A;
negative percentage-point deltas mean lower CPU. Relative reductions are positive
when B is cheaper. Both opposite orders must be inspected; these two pairs are
an initial screen, not a confidence interval. Do not pair percentages from
different CI machines or combine these values with historical local M1 results.
Regressions remain visible in the report instead of being hidden behind a pass
threshold. Ordinary CI still owns functional and true WindowServer-pixel checks.
