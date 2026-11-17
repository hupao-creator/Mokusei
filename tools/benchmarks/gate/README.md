# Performance boundary infrastructure

The normative expectations below accompany the checked-in catalog. All initial
thresholds are **provisional engineering budgets, not physically calibrated
limits**. A passing screen means only that the recorded metrics satisfy this
policy. It does not establish statistical significance or typical user latency.
The [specification](SPEC.md) records scope and design decisions; the
[report schema](report.schema.json) defines machine-readable output. The shared
[boundary contract](../BOUNDARY_CONTRACT.md) defines lifecycle and exit semantics.

The primary user-experience suites and capability definitions are in [UX.md](UX.md).
Runtime measurements below are diagnostics, not a substitute for those boundaries.

## Documented suite expectations

`runtime-boundaries` uses the six production API scenarios documented in
[Runtime performance](../../verification/runtime-performance/README.md):
`store-noop`, `store-lifecycle-append`, `store-work-read`, `runtime-list`,
`runtime-notify`, `application-list`. Each process uses 1,000 records, 100 measured
operations, one warmup, one sample and GOMAXPROCS=2. Six adjacent pairs per scenario
alternate AB/BA. Builds precede measurements. The whole run has a 900s default
budget, each process at most 120s; budget exhaustion blocks, never passes.

| Required metric ID | Unit | Direction | Relative tolerance | Absolute tolerance |
| --- | --- | --- | --- | --- |
| nsPerOperation | ns/op | lower | 15% | 5,000 ns/op |
| bytesPerOperation | bytes/op | lower | 15% | 1,024 bytes/op |
| allocsPerOperation | allocations/op | lower | 15% | 8 allocations/op |

`overview-release` retains the exact existing [Release probe](../../verification/overview-ci-performance/README.md):
`R0`, `S4`, `A4`, N40/K4, 5s warmup, 20s formal, six opposite-order pairs.
Its 2,400s command budget is inside a 45-minute job budget. These six pairs use
the same paired interval policy as the signed UX suites. The existing source, clock, window, product convergence,
power and owned-process cleanup checks remain prerequisites.

| Required metric ID | Unit | Direction | Relative tolerance | Absolute tolerance |
| --- | --- | --- | --- | --- |
| uiCPUPercent | one-core percentage points | lower | 15% | 2 pp |
| coreCPUPercent | one-core percentage points | lower | 15% | 2 pp |
| totalCPUPercent | one-core percentage points | lower | 15% | 3 pp |

`external-overview` and `external-reading` register the signed production App
collectors and their existing scenario IDs. They remain **measurement-only**:
their current descendant/exit accounting is incomplete and native hitches are
unavailable. The gate entrypoint returns unsupported (2); it cannot reinterpret
partial resource numbers as a passing whole-application comparison. Existing
build/calibrate/run/analyze commands remain available. Their plans, optical
latency bounds, CPU/footprint units and capability budgets are documented in
[Overview](../README.md) and [reading](../reading/README.md). No FPS/GPU/energy
metric or implicit threshold is invented. The `ux-startup`, `ux-overview` and `ux-reading` adapters separately certify only
the narrower pixel/identified-App scope documented in [UX.md](UX.md).

## Judgment, sampling and noise

For each prescribed pair, retain b, c, c−b, relative change (null when b=0),
direction, allowed degradation `max(absolute, relative*b)` and signed excess.
No metric may be absent, null, boolean, negative or nonfinite. A regression
requires the 95% paired excess interval entirely above zero and positive excess
medians in **both** orders. A pass requires the interval upper endpoint ≤0 and
both order medians ≤0. Opposite order classifications block as
inconclusive. Normalized excess MAD >1 also blocks. These are provisional noise
budgets. The order-stratified percentile bootstrap uses 2,000 resamples and seed
1729; observation bounds propagate through both interval endpoints. At least six
independent pairs are required. Raw ranges and all pairs remain visible.
No outlier trimming, optional stopping or hidden reruns. Fresh processes are the
sampling units; the 100 operations within one Runtime process are not 100 pairs.

Catalog metric policies must be objects and numeric inputs must be finite and
bounded. Invalid configuration, including oversized JSON integers, exits 2;
it is not an established performance regression.

Suite/workload version, catalog digest, collector/harness digest, full baseline
and candidate revision, binary hashes, host session, hardware, OS, toolchain,
instrumentation and pair-specific comparison identity are mandatory. Different
hosts, sessions, workloads or collector versions cannot silently compare. Policy
changes require a new campaign. SHA approval chooses a product revision, never a
pool of old samples. The `baselines/` measurement artifacts are not registry entries.

## Lifecycle and evidence

The common runner prepares immutable inputs, holds a nonblocking host benchmark
lease, builds both products with one harness, executes serially, collects raw
JSON/command receipts, validates, judges, cleans up and writes JSON plus Markdown.
Owned process groups are terminated on deadline/interruption; temporary products
and fixture data are removed; failures are retained. A lease coordinates these
drivers, not unrelated compilers: reserve an otherwise idle machine. GUI probes
also keep the existing native foreground lease. No production logs are needed.

Evidence hashes detect edits, not authorship. Only measurement/command artifacts
are public; user profiles, connection credentials and environment secrets are
excluded. Reports reference relative paths within a movable bundle. CI uploads
on failure as well as success. A killed host may leave partial receipts and no
final report: that is an incomplete attempt, never success.

## Commands

```sh
python3 tools/benchmarks/performance.py list
python3 tools/benchmarks/performance.py run --suite runtime-boundaries \
  --baseline FULL_SHA --candidate FULL_SHA --output /tmp/runtime-campaign
python3 tools/benchmarks/performance.py run --suite overview-release \
  --baseline FULL_SHA --candidate FULL_SHA --output /tmp/overview-campaign
python3 tools/benchmarks/performance.py judge /tmp/runtime-campaign
python3 tools/benchmarks/performance.py promote /tmp/runtime-campaign \
  --output /tmp/approved-baseline.json --reviewer NAME --reason REASON
python3 tools/benchmarks/performance.py run --suite runtime-boundaries \
  --baseline-manifest /tmp/approved-baseline.json --candidate FULL_SHA \
  --output /tmp/next-campaign
python3 tools/benchmarks/gate/verify.py --output /tmp/performance-contract-evidence
```

`--catalog` selects an explicit reviewed policy file; its digest is retained.
`judge` uses the campaign's snapshotted catalog and rechecks retained evidence.
Promotion rejudges those inputs, requires passed, records reviewer/reason/report
hash, and creates a new file exclusively. It never changes a repo ref or overwrites
a prior baseline. Compare full explicit SHAs to bootstrap an A/A baseline.

Portable CLI PBT/e2e runs in `performance-contract.yml`. Runtime A/B and Overview
A/B have explicit dispatch workflows; a nonzero judgment fails their job. These
files do **not** configure GitHub required checks. Integrators must inspect current
rules before making a merge claim. Synthetic verification certifies gate
mechanics only. GUI capture/signing and physical noise calibration are separate
capabilities; unavailable experiments must be reported as unrun.

The portable verifier records its actual generated CLI groups, seed and exit
status in `verification.json`; it does not measure product performance or
calibrate thresholds. Native optical UX and foreground Overview judgments require
their own valid signed/captured campaigns. Noise or uncertainty in an A/A campaign
blocks judgment just as it does in an A/B campaign.

All optical entrypoints perform no-prompt preflight before any control/fixture
App is created. Missing collector Accessibility/input/capture permissions produce
unsupported/2 with raw receipts, not a product performance judgment. Desktop
contention refuses entry; normal SIGTERM unwinds the caller's lease cleanup.
