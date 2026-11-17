# User experience performance boundary

Benchmarks own response, progress, startup and resource-cost expectations.
Interaction correctness belongs to e2e; Moku/Runtime invariants belong to PBT.
Runtime microbenchmarks are diagnostic support and do not certify UX.

## Signed App scenarios and current budgets

`performance.py run` uses existing independent collectors against two signed
production Release Apps. Six fresh-profile A/B pairs alternate AB/BA. All
required scenarios run once on each side of every pair; a single missing case
blocks the suite. Budget: 3,600s per suite, at most 600s per side; no automatic
retry, pruning or warmup-dependent early stopping. Builds and calibration precede
the campaign. The atomic `/private/tmp/mokusei-ui-verification.lock` directory and native flock
prevent overlap with coordinated e2e/NativeReplay;
an otherwise idle, unlocked Mac and an agreed exclusive desktop slot are required.

| Suite ID | Scenario IDs | Fixed workload |
| --- | --- | --- |
| ux-startup | first-render | 5 prepared cards; 8s formal; 1280×950 window |
| ux-overview | pan, body.pan | 10 prepared cards; 8s formal; 1280×950; sparse output |
| ux-reading | reading.first-open, reading.reopen | 8 KiB settled Markdown reply; 10s formal; existing reading input schedule |
| ux-zoom | zoom, body.zoom | Unsupported: no validated real system pinch injector |

All tolerances are **provisional, not physically calibrated**. Each metric has
lower-is-better direction and 15% relative tolerance; allowed degradation is the
larger of that relative amount and the absolute tolerance below.

| Metric ID | Units / exact observation | Absolute tolerance | Suite |
| --- | --- | --- | --- |
| firstContentSeconds | source/input to recognizable body, lower/upper capture bounds | 200ms startup; 100ms reading | ux-startup, ux-reading |
| responseSeconds | posted drag/scroll to visible displacement, bounded; worst scheduled reader segment | 100ms | ux-overview, ux-reading |
| noProgressSeconds | longest observed input progress gap, bounded; worst reader segment | 100ms | ux-overview, ux-reading |
| appCPUSeconds | App cumulative user+system CPU at formal end since new process birth | 100ms CPU | ux-startup |
| appCPUPercent | identified App CPU delta / sampled interval, one-core scale | 2 percentage points | ux-overview, ux-reading |
| appPeakFootprintBytes | peak of observed App footprint samples | 16 MiB | all three |

The 650ms progress/capture validity budget in the collectors remains a capability
and functional observation constraint. It is **not** the 100ms regression budget.
The gate propagates capture intervals through pair excess and a 95% order-stratified
percentile bootstrap (2,000 resamples, fixed seed 1729). A pass requires the upper
excess bound ≤0; regression requires the lower bound >0; overlap blocks. Both
orders must agree, and normalized excess MAD must be ≤1. Six independent pairs
are the minimum. Finite-sample bootstrap intervals are descriptive uncertainty
estimates, not a calibrated false-positive guarantee; no significance claim is
made. OCR cadence never becomes display FPS.

## Startup and ready definitions

`first-render` stops the owned App and Runtime, then launches fresh processes
against the prepared profile. It is **process-cold, with uncontrolled OS caches
after fixture warmup**. It is neither a pristine-install launch nor a cache-cold
disk/boot experiment. LaunchServices request/return, OS birth identity and capture
attachment are retained. Ready means the first recognizable business title and
body; a later scheduled real drag establishes an independent usability upper
bound. This does not certify every control, composer or every offscreen card.

The first-content interval starts at the last absent capture; if capture attaches
after content already exists, its lower bound is zero and it remains left-censored.
Such uncertainty can block comparison. App CPU includes pre-attachment cumulative
CPU but does not certify pre-attachment memory peaks or descendant cost.

A process-warm reopen/activation retains the same App process. The reading suite
measures that reader reentry separately as `reading.reopen`; it is not App launch.
App warm activation and OS cache-cold startup have no certified timing adapter.
The runner neither clears caches nor reboots or alters system authorization.

## Capability and scope

Both calibration and signed campaigns check the independent collector's existing
Accessibility, event-posting and screen-capture permissions before launching any
control or fixture. `preflight.json` retains the actual host, collector digest and
build; `desktop-lease.json` retains the owner. Missing permission writes
`blocked.json` and returns unsupported/2 with zero measurements. Standalone
reading and Overview commands use the same check. No authorization is requested.
A separate operator/CUA permission does not establish the timed collector's
capability and cannot replace its optical/input calibration.

Every signed trial reanalyzes the sealed original observations and calibration
controls. Pixel control failure, wrong product result, missing source delivery,
changed artifacts, capture/input gaps, invalid ownership and failed cleanup block.
The narrower UX adapter allows only the explicitly identified missing whole-task
exit accounting and native hitch capability; it reports them alongside each row.
It never converts the wider collector's `incomplete` status into a complete-task
claim. Startup additionally retains the known pre-attachment observation gap as
an interval. All other reasons block; unknown reasons cannot silently pass.

Actual display, window, collector/toolchain, native CLI, stable power/thermal
observations before/after each side, sampling schedule,
workload and session identities must match within a pair. Full bundle hashes are
checked before and after collection. Current production bundle provenance records
channel/configuration/input hashes but no Git SHA. `bind-artifact` therefore makes
an **explicit operator-attested revision binding**, preserved in reports, rather
than claiming the signature proves a source commit. Use the build's known revision.

```sh
python3 tools/benchmarks/performance.py bind-artifact --app /path/A.app \
  --revision FULL_BASELINE_SHA --output /tmp/app-a.json
python3 tools/benchmarks/performance.py bind-artifact --app /path/B.app \
  --revision FULL_CANDIDATE_SHA --output /tmp/app-b.json
python3 tools/benchmarks/benchmark.py build --tools /tmp/ux-tools
python3 tools/benchmarks/benchmark.py calibrate --tools /tmp/ux-tools --output /tmp/ux-controls
python3 tools/benchmarks/performance.py run --suite ux-startup \
  --baseline FULL_BASELINE_SHA --candidate FULL_CANDIDATE_SHA \
  --baseline-artifact /tmp/app-a.json --candidate-artifact /tmp/app-b.json \
  --tools /tmp/ux-tools --capabilities /tmp/ux-controls --output /tmp/ux-startup
```

`ux-reading` uses controls from `reading_benchmark.py calibrate`. Private synthetic
profiles stay in temporary storage; exported trial/capability evidence contains
no Runtime connection credentials. Signed GUI suites have no hosted workflow:
they require existing signing artifacts, capture/input permissions and desktop
coordination. `overview-release` is the separate hosted foreground resource gate,
with six pairs of R0/S4/A4; it does not establish optical responsiveness.

## FPS, GPU, energy and zoom

Run `performance.py capabilities --output NEW_DIRECTORY` for raw command receipts
and `capabilities.json`. Missing capabilities return exit 2; installed template
names alone never certify that recording, attribution or calibration works.

| Signal ID | Definition | Current support |
| --- | --- | --- |
| presentedFrameTime | actual presentation timestamps for the product's identified surface; reciprocal intervals can describe delivered FPS | unsupported: no validated presentation trace adapter |
| gpuExecutionTime | owned GPU commands' execution duration, with overlap explicitly handled | no certified App gate; diagnostic traceOwnedGPUActiveSeconds available |
| traceOwnedGPUActiveSeconds | union of target PID Active depth-zero GPU intervals in Xcode 26 Metal trace | diagnostic only; independently exercised with offscreen blit/idle controls |
| energyJoules | physical energy attributable to the product over the defined interval | unsupported: no physical attribution measurement |
| systemEstimatedGPUPower | powermetrics SoC GPU estimated mW | diagnostic only when already permitted; whole-system, not App energy |
| overviewPinchInjection | real macOS magnification input accepted by SwiftUI | unsupported: no validated public injector; modified wheel is ignored by current canvas routing |

Capability receipts identify the actual host, toolchain, templates and devices.
Sandboxed enumeration can hide templates/devices and is not authoritative for
normal-user host support. Template availability is separate from recording,
export, attribution and calibration. Unprivileged powermetrics cannot supply
physical App energy; the command does not elevate privileges or change settings,
signing entitlements or system services.

## Instruments diagnostic collection

The `trace` command records bounded 1–30s Instruments experiments, retains the
raw trace, target identity, command receipts and exported GPU/presentation tables.
The launched control must exit successfully itself; a live/unconfirmed target
blocks completion. `--no-prompt` uses existing authorization only. This path
holds both the performance and native leases and is separate from ordinary
unprofiled measurements. Instrumented data is never pooled with CPU gate samples.

The Xcode 26 GPU parser resolves exported references, filters **only the launched
PID**, requires `Active` state and depth zero, and unions overlapping intervals
across GPU channels. It retains admitted intervals and reports
`traceOwnedGPUActiveSeconds`. No target events yields `incomplete` with null value,
not zero App cost. This is observed GPU activity, not shader utilization, total
command latency, display scan-out or energy. Presentation tables are retained
without an FPS scalar because surface ownership/lifetime calibration is absent.

```sh
xcrun swiftc -O tools/benchmarks/gate/GPUControl.swift -o /tmp/gpu-control
python3 tools/benchmarks/performance.py trace --executable /tmp/gpu-control \
  --seconds 3 --output /tmp/gpu-busy -- busy
python3 tools/benchmarks/performance.py trace --executable /tmp/gpu-control \
  --seconds 3 --output /tmp/gpu-idle -- idle
python3 tools/benchmarks/performance.py trace-analyze \
  /tmp/gpu-busy/metal-gpu-intervals.xml --pid TARGET_PID --output /tmp/gpu-observation.json
```

Trace acquisition deliberately exits 2: a diagnostic recording is not a passing
performance gate. Offline `trace-analyze` exits 0 for an observed diagnostic and
2 when target activity is absent; its output always sets `gateEligible: false`.
The independent control uses completed `MTLCommandBuffer` GPU timestamps as a
separate observation without instrumenting the product. Busy/idle control
artifacts can establish units and target ownership; they do not calibrate product
noise, physical presentation or energy. A missing target event remains null and
incomplete even when other processes have GPU activity.

System traces contain other processes even when a launched target is selected.
They remain local private diagnostic artifacts; no workflow automatically uploads
them. Numerical analysis selects only the declared PID. Signed/hardened product
attachment and presentation ownership have not been exercised here. The available
App Launch/Animation Hitches templates likewise have no certified adapter.

[Apple's Metal tools](https://developer.apple.com/metal/tools/) provide scheduling
traces for supported configurations. They are not automatically an attributable
whole-SwiftUI-window FPS counter. [GPU counter collection](https://developer.apple.com/documentation/xcode/analyzing-apple-gpu-performance-using-counter-statistics)
can serialize work, so instrumented samples cannot be pooled with ordinary CPU
samples. [Power Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)
documents supported mobile devices and relative subsystem power impact; a listed
template does not prove macOS availability or joules. `powermetrics --help` labels
its power as estimated and unsuitable for comparing devices. No CPU proxy,
energy-impact score, optical capture frequency or display-link callback is
reported as physical FPS, App GPU time or energy.

The commands expose collection and analysis capability. Signed production UX,
foreground Overview A/B, App warm activation and physical FPS/energy require
their own actual evidence; command availability and synthetic contract checks are
not passing product performance results.
