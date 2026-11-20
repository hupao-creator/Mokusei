# Foreground Overview Release performance

This boundary measures fixed baseline/candidate product commits on one macOS
arm64 runner with one shared harness. The
[Overview workflow](../../../.github/workflows/overview-performance.yml) calls the
[common performance gate](../../benchmarks/gate/README.md), which fails on a
regression and blocks incomplete, incomparable or noisy evidence. It is an
explicit dispatch workflow; it does not configure remote required checks.

## Workload and sampling contract

The suite ID is `overview-release`; scenario IDs are `R0`, `S4`, `A4`.
All use N=40 with four running 2×1 cards fully visible, fixed camera, dark
appearance, product-owned animation, Reduce Transparency disabled and the
product's default card materials.
The harness gives each probe window a dark appearance and supplies Simplified
Chinese through the locale API exposed by the paired product checkout.
Each fresh process receives 5s load-bearing warmup, 20s formal input and a maximum
5s catch-up tail. There are six adjacent A/B pairs per scenario, 36 fresh-process
observations in total. Three blocks each run R0/S4/A4 in AB order, then A4/S4/R0
in BA order. Compilation finishes before sampling. There are no retries or
outlier exclusions.

| Scenario | Input |
| --- | --- |
| R0 | Four running cards with no new content |
| S4 | Bounded sliding-text replacement, 10 updates/s/card, staggered |
| A4 | Cumulative deterministic text append, 10 updates/s/card, staggered |

Both products use optimized Release Swift objects and `-O -enable-testing` on the
probe; Go uses normal optimized builds with CGO and no race/profiler instrumentation.
The runner copies identical current harness sources into two detached worktrees,
checks clean product inputs before and after, and records full commit/tree,
per-file input hashes and actual probe/Core binary hashes. A signed probe linked
to production objects is a distinct boundary from the signed complete App
[optical suites](../../benchmarks/gate/UX.md).

## Source and clock validity

Source protocol version 2 uses a preallocated 256-entry FIFO. The independent
producer admits event identity/timing on absolute monotonic 25ms deadlines;
S4/A4 supply 1,000 events over warmup plus formal time. Enqueue lateness must be
≤50ms. Queue overflow, missing events, producer errors, incomplete final hashes
or pending/in-flight work beyond the tail invalidate the observation. The worker
performs production Store mutations serially; it is not paced by UI consumption.

Receipts distinguish planned, enqueued, dequeued, sent, storeUpdateStarted and
accepted. They retain queue occupancy/high water, source backlog and coalesced
publication/install observations. These describe the harness queue and observed
model installation, not all production queues or presented pixels. Accepted-to-
publish latency may be negative because committed listeners run before the
Store.Update caller resumes; the original signed value is retained.

Measurement clock version 2 is `darwin.CLOCK_UPTIME_RAW.ns` in both processes.
Fresh UTC/raw brackets retain uncertainty and verify cross-process clock origin;
Dispatch/raw checks and uncertainty must agree within 5ms. UTC values are
metadata, never timing membership. CPU callbacks use a dedicated serial queue
and strict one-shot timers, outside MainActor. Actual CPU boundaries must satisfy
−1ms to +50ms timing offsets; missed reads/cancellation invalidate the run.

## Metrics, expectations and limits

`uiCPUPercent`, `coreCPUPercent` and `totalCPUPercent` use formal user+system CPU
deltas divided by actual monotonic intervals, on a one-core scale. Lower is better.
The current **uncalibrated provisional** tolerance is max(15% of baseline,
2 percentage points) for UI and Core, and max(15%, 3 points) for total. The
[common policy](../../benchmarks/gate/README.md) requires six independent pairs,
95% order-stratified bootstrap excess intervals, both-order agreement and
normalized excess MAD ≤1. Raw values, paired deltas/tolerances and evidence remain
in reports; a noisy same-product comparison blocks instead of silently passing.

MainActor window/footprint/model observations are sampled independently. UI
warmup, formal, tail and source-through-tail CPU windows remain separate; do not
add extra UI windows to Core formal CPU. Model convergence does not prove pixels,
physical FPS, GPU time or energy. No screenshot or profiler capture is part of
this resource-cost matrix. User-visible response is a separate optical boundary.

## Environment, ownership and budget

A real foreground window and all four full card bounds must fit a physical
reported screen. The runner requires macOS 26 arm64, Metal and the
[runner image contract](../../../scripts/ci/self-hosted.md). Optional
`--configure-display` is restricted to disposable GitHub-hosted runners and
chooses an already offered mode ≥1265×800, preferring 1440×900. It records and
restores the original mode. It creates no virtual display. Self-hosted images
must supply the display policy in advance.

The hosted workflow sets Reduce Transparency false only for the disposable
GitHub-hosted account. Self-hosted accounts must already satisfy the transparency
policy.

Power source must be known and stable per process and equal within a pair.
Fixture/window/camera/display identities must match. Foreground, source, clock,
product convergence, runtime identity and cleanup are all prerequisites. One
native lease spans both staged Apps. PID plus executable filesystem identity
fences cleanup; /var and /private/var aliases may resolve to the same binary.
Credentials are excluded from exported ready receipts.

The common command budget is 2,400s inside a 45-minute workflow job. Nominal
warmup/formal sampling is 15 minutes; startup, tail, builds and linking add time.
This is a hang guard, not a statistical acceptance deadline. Timeout or cleanup
failure blocks. Output is a new directory and retains failed observations.

```sh
python3 tools/benchmarks/performance.py run --suite overview-release \
  --baseline FULL_BASELINE_SHA --candidate FULL_CANDIDATE_SHA \
  --output /tmp/overview-performance
```

The root `report.json`/`report.md` is the regression judgment. `overview/` contains
the complete native collection report, runs, command/process/cleanup receipts,
build identities and display observations. Running this directory's `run.py`
directly performs collection validity only; its exit code does not replace the
common gate. The workflow uploads all evidence on success or failure.

## Identity and coverage boundaries

Product-input inventories include tracked macOS Sources/Plugins, Package files,
`internal/`, `cmd/` and Go module files. The aggregate hashes sorted relative
path, NUL, file SHA256 hex and LF; a different inventory algorithm is not an
interchangeable identity. Runtime PID/parent-PID and strict executable file identity
remain prerequisites; aliases must resolve to the same staged regular file before
cleanup may signal an owned process. The source observes public state/command
failures directly and does not depend on private production logs.

The [ordinary CI](../../../scripts/ci/README.md) runs build/static and declared
routine PBT. Those properties do not certify this UX comparison, physical input
or captured appearance. The performance workflow has its own judgment and
artifact records, independent of GitHub's actual required-check configuration.
