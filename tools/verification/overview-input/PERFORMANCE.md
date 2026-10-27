# Glass world paired performance replay

This benchmark compares only the production Thread outer shell controlled by
`glassWorld`. It shares `glass-fixture.swift` with the four-way screenshot replay:
five Codex/Claude/Pi/OpenCode/Report cards, fixed content, plans, badges, Follow-up,
top tag bar and the stationary production Moku Dock. Inner glass remains enabled. It starts no Runtime,
reads no user profile, changes no user preference and sends no model requests.

## Controlled launch and failure handling

Prefer preparing before the quiet interval and then running the exact bundle:

```sh
python3 tools/verification/overview-input/run.py --glass-performance /absolute/new/run --build-only
python3 tools/verification/overview-input/run.py --glass-performance /absolute/new/run \
  --run-built /private/tmp/mokusei-overview-.../OverviewInputReplay.app
```

`--run-built` verifies the executable hash, signature and measurement-source
hashes, refuses a started bundle, and performs no compilation. A process-scoped
lock prevents concurrent instances of this benchmark. Before launching any
window, the driver requires 30 consecutive checks with session input idle for
at least 30 seconds and no busy compiler/native replay. If this cannot be
established within 180 seconds, it preserves `prelaunch.json` and stops without
opening a window. It then makes one ordinary LaunchServices launch, with no
extra app activation call; the app rechecks input idleness before showing its
content. It never reactivates after losing foreground ownership. If initial
focus is not granted within five checks, it stops without a retry.

Once focus has been established, loss during readiness stops the trial. All
warmups are retained separately. A contaminated warmup or measured segment is
written before the app exits; the driver does not continue filling the matrix
after failure and never retries segments. The external monitor recognizes
truncated `ucomm` names such as `ReadingPresenta` and `OverviewInputRe`, and
requests only its own fixture to stop when build/replay interference appears.
Replay identities are retained even below the monitor's 5% CPU reporting floor:
an idle test window can still affect rendering or wake between snapshots.
No foreign process is signalled. Existing timing/load/thermal gates remain.
The monitor also checks session input age throughout the trial, covering keys
and clicks that do not move the pointer. It records only age, never input content.

Analysis now fails unless the exact condition identities, chronological AB/BA
order, action/heartbeat counts, segment lengths, warmup coverage, recorder
health, successful native/driver completion and pair oracles all pass. Formal
success requires all 32 conditions and 16 valid pairs. A power-source change invalidates the trial. Partial/invalid
summaries and charts are explicitly diagnostic, even when collection finished.

The retained run-3's first six conditions were valid. At 13:38:32 it lost active/
key state; all remaining 26 conditions were affected. Three also had pointer
movement over the window and three exceeded the host-load gate. No compiler/
replay overlap was found in its monitor. The old driver continued despite the
loss and the old analyzer returned success for an invalid comparison. These
control-flow defects are fixed; the retained raw measurements are unchanged after
path and archive-owner anonymization. The old foreground owner cannot be inferred
retrospectively.

The analysis regression replays real retained data, missing/duplicate conditions,
unequal action counts and changed chronological order against the production CLI:

```sh
python3 tools/verification/overview-input/verify-performance-analysis.py
```

## Commands

```sh
# Optional first-run validation (~1–2 minutes after building); never use its results as the benchmark.
python3 tools/verification/overview-input/run.py \
  --glass-performance /absolute/new/smoke --performance-smoke

# Release build, isolated temporary bundle, and ~10-minute visible-window run.
python3 tools/verification/overview-input/run.py \
  --glass-performance /absolute/new/run
python3 tools/verification/overview-input/analyze-performance.py /absolute/new/run
# Requires matplotlib; install it in a disposable virtual environment if needed.
python3 tools/verification/overview-input/plot-performance.py /absolute/new/run
```

The output directory must be new. `--build-only` prepares the same isolated app
without launching; it prints the app and private result location. Partial data is
retained on failure. The normal launcher has a 20-minute bound and stops only the
PID whose launch record identifies its newly created bundle. No installed app is
stopped. Keep the display awake and visible. Run serially with other native UI
replays/builds and avoid moving, covering or interacting with this window. The
fixture never posts global input or changes power/display settings.

## Controlled comparison

The driver builds this checkout with SwiftPM `-c release -Xswiftc -enable-testing`
and links the fixture with `-O`. Testable access exposes production internal
components; it does not select Debug code paths. Both states and all repetitions
use the same executable/PID and mounted views. `build.json` contains the revision,
source-file hashes, diff hash, executable SHA-256, exact build/link commands,
Swift/OS/hardware facts, power source and available Instruments templates. This
is an optimized production-component harness, not a benchmark of a packaged app's
Runtime, networking or startup. The existing signed-app settings/restart replay
separately verifies persistence; bypassing that UI here avoids measuring Settings.

The own-process window is 1200×760 logical points at the fixed automatic fit,
then switches to manual camera ownership. Cloud and Moku motion are disabled.
Light and dark use the same layout and card count. `metadata.json` records scale,
actual backing pixels, display geometry, accessibility settings and fixed frames.
Nominal display refresh is metadata, **not measured rendering FPS**.

Before warmup, the visible fixture requires 30 consecutive one-second checks with
key/active/visible window, unchanged pointer, host CPU busy ≤40% and thermal state
below serious. It allows at most 180 one-second checks, retains `readiness.json`, and fails
if it cannot obtain that interval. It never repeatedly reactivates itself when
another application takes focus. This is a readiness check, not measured data.
Readiness and the first focus loss in a segment record the frontmost app's bundle
identifier/PID, without window titles or content. This identifies the observed
foreground owner; it does not prove whether a person or automation changed focus.

Each of four repetitions covers light/dark × static/pan-zoom × on/off. Adjacent
material pairs use AB, BA, AB, BA order; appearance and scenario order also reverse
on alternate repetitions. Both materials receive an initial dynamic warmup.
Every condition then gets 2 seconds settling, 4 seconds scenario warmup, camera
reset, 250ms settling and 12 seconds measured activity. Toggle/theme work is outside
the measured interval. The static case includes a 20Hz lightweight scheduling
probe; it is not a completely uninstrumented idle-energy measurement.

The dynamic case delivers exactly 720 manual camera updates on an absolute 60Hz
schedule. The production `setManualTransform` path uses ±24pt horizontal, ±16pt
vertical and ±3.5% scale sinusoidal requests with a four-second period, ending at
the original camera. Each condition gets identical logical actions; this is not
physical gesture recognition. Late wakeups can compress subsequent actions,
which is why raw lateness and disrupted-scheduling rejection are mandatory.
Start/end and sampled actual camera transforms, mounted IDs, appearance counts,
layout snapshot count and window frame must match within each pair. Conditions
also verify that material changes never remount content or change placement.

## Metrics and validity

- Process CPU: delta of `getrusage(RUSAGE_SELF)` user + system seconds divided by
  the actual monotonic interval. 100% means one logical CPU core. It excludes
  WindowServer, GPU and Runtime CPU.
- Memory: `TASK_VM_INFO` current resident size and physical footprint at about
  4Hz. Report segment median and sampled peak, not cumulative `ru_maxrss` as
  current memory. The process is intentionally shared across conditions; caches
  and allocator residency can carry over. AB/BA limits but does not remove this.
  These are task-accounted memory counters, not total WindowServer/GPU allocation.
- Host load: delta of `HOST_CPU_LOAD_INFO` ticks, busy fraction across all cores;
  raw external `ps` samples every two seconds identify other busy processes.
  `ps` CPU is the OS's rolling estimate, not an interval-attributed CPU metric.
- Responsiveness proxy: actual MainActor resumption minus the requested absolute
  `Task.sleep` deadline, with per-segment p95/max, over-one-period and >50ms counts.
  This includes scheduler/timer behavior. It does **not** measure frame rendering,
  scan-out, dropped frames, FPS, or a Core Animation hitch.
- `NativePerformance` runs in summary mode for both states. Scenario spans aid
  correlation; the analyzer checks final dropped/truncated/write-error counters.
  This recorder's enum names alone do not establish a renderer measurement.
- GPU time/utilization attributable to the fixture, rendered frame time/FPS,
  presentation hitches and energy are not collected by this counter replay.
  Inspect each run's actual `build.json` template inventory: the integrated
  `8dac39dec` run lists Metal System Trace and Animation Hitches, unlike the
  earlier handoff's capability report. A listed template alone does not establish
  a usable recording or attribution. Collect and inspect any instrumented trace
  separately; do not mix its overhead into this uninstrumented paired trial or
  substitute a system-wide GPU counter for this app's work.

All raw samples survive exclusions. The analyzer excludes a whole pair if either
condition loses key/active/visible window state, changes display/window/layout,
moves the pointer over the window, fails the pair oracle, encounters serious/critical thermal state, has average
host CPU busy above 40%, overlaps another busy native replay/test or compiler,
or has any scheduling lateness over 250ms / more than 5% wakes over one requested
period. These thresholds were chosen before the formal run. Occlusion state does
not prove pixel-by-pixel unobscured visibility. `ps` may miss short interference;
background apps and WindowServer remain uncontrolled sources of noise. No system
processes are stopped to manufacture a quiet result.

`summary.json` and `samples.csv` retain every condition, rejection reason and
paired median/range. `summary.md` is the compact result table. Four standalone
SVG/PNG plots show connected adjacent pairs; rejected pairs are red/dashed.
With only four pairs, interpret direction and range as local exploratory evidence,
not a population effect or an equivalence claim. Inspect paired deltas and host
load before making a recommendation. If pairs are invalid, retain them and rerun
in a new directory after interference ends; do not silently trim outliers.

## Validation

Run `make check`, the normal Overview input replay, fixed glass screenshots and
Overview mounting replay after changes to this shared fixture/build driver:

```sh
make check
python3 tools/verification/overview-input/run.py
python3 tools/verification/overview-input/run.py --glass-world /absolute/new/captures
python3 tools/verification/reading-presentation/run.py --overview-mounting
```

The performance smoke and full run additionally exercise counter collection,
Release linking, deterministic camera motion and analysis on the actual native
components. `--capture-transitions` continues to use its original fixture and
Debug configuration; no production source is modified by this tool.
