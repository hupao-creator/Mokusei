# External Overview rendering benchmark

This Python CLI runs against a **built, signed production Release `.app`**. It
builds only its independent macOS collectors and control app. An XCTest UI
target is built only for an explicitly requested native-hitch diagnostic.
It never imports product modules, reads Overview types or writes product
persistence. Copy this directory outside the repository to run it independently.
Python 3.10+, macOS 26 and Xcode 26 are required for live collection; conformance
and offline analysis use the Python standard library on Linux or macOS.

The [Agent Thread reading extension](reading/README.md) shares these collectors,
public fixture/lifecycle boundaries and evidence contracts. It separately measures
existing-document entry, reopening, bidirectional scrolling and reading during
meaningful Agent output. Its workload varies single-reply length: 8 / 32 KiB by
default, with an explicitly selected 128 KiB stress workload.

The current scope is rendering under fixed total counts **5 / 10 / 20**, including
controlled body output through the native agent runtime.
There is **no layout score**, visible-card quota,
onscreen/offscreen attribution or occupancy comparison. These are complete-app
scenarios, not exclusive CPU attribution to a rendering module.

## Run

```sh
python3 tools/benchmarks/benchmark.py conformance
python3 tools/benchmarks/benchmark.py build --tools /private/tmp/overview-tools
python3 tools/benchmarks/benchmark.py calibrate \
  --tools /private/tmp/overview-tools --output /private/tmp/overview-controls
python3 tools/benchmarks/benchmark.py run \
  --app /absolute/path/Mokusei.app --tools /private/tmp/overview-tools \
  --capabilities /private/tmp/overview-controls \
  --output /private/tmp/overview-run --count 5 10 20 \
  --scenario first-render idle.completed idle.active pan body body.pan
python3 tools/benchmarks/benchmark.py analyze /private/tmp/overview-run/n-5/04-body
```

Outputs must be new directories. Live experiments need Screen Recording,
Accessibility and system input permission in the invoking context, an unlocked
visible desktop and exclusive use of the foreground window during each trial.
The default build/calibration/run path does not launch XCTest, Instruments,
`sudo`, or an authorization dialog. Read-only permission probes fail before
fixture launch if the invoking context lacks an existing desktop permission.
The CLI never changes Developer Tools authorization or system security settings.
`--native-hitches` explicitly opts into the separate XCTest diagnostic for
`build`, `calibrate` and `run`. It requires Developer Tools authorization already
enabled and fails preflight otherwise; no interactive authorization is requested
by the CLI. This extension is not needed to collect the default resource/pixel
baseline. Default reports retain native hitches as unavailable, never zero or
passed; optical progress/stall estimates are not native frame-hitch metrics.
The collector records foreground loss, missed input deadlines and capture gaps.
Response/stasis estimates retain sampling bounds. A bound that straddles the
declared progress deadline is incomplete evidence; only a lower bound beyond
the deadline establishes overload. Missing recognized body checkpoints are an
observation gap, not proof that the content froze.
Do not run two GUI experiments together. Exit 2 means incomplete/unsupported
measurement, not a statistical performance regression. The current unprivileged
process sampler always exposes incomplete descendant/exit accounting.

`--mode minimal` collects resource/input observations without continuous capture
or hitches. It cannot prove responsiveness. Calibration includes an observed /
minimal control pair to expose probe cost; it does not subtract that cost from
product measurements. WindowServer/OS services are shared and not attributed to
the product. Source, collectors, App, Runtime and discovered helpers have
separate accounting roles.

All measured scenarios begin with the entire fixed card set **already existing**.
Fixture creation and metadata settling happen before timing. No timed scenario
creates/deletes cards or deliberately reveals them one at a time. First rendering
reopens the already-populated profile. Before/after public card IDs, titles and
counts are retained and checked; a changed set cannot produce a passing outcome.
Before timing, one public Accessibility observation locates a mouse-down gap
outside exposed card/control rectangles. A separate system-wide AX hit-test
checks the selected point's complete ancestry, owner and unchanged window,
rejecting cards and interactive controls. A semantic canvas hit is accepted;
SwiftUI may instead return only full-window anonymous hosting groups under the
public `workspace` window. That specific bounded container chain is accepted
as a candidate inside the independently observed canvas bounds, not as proof
that a gesture was accepted. Unknown/smaller containers and other windows fail.
Virtualized cards need not all appear in the AX tree; the fixed existing card
set is checked separately through public fixture/UI identities. This is input preparation, not a
layout score or visible-card quota. Missing geometry or a blocked point cannot
be interpreted as a frozen canvas. First-render probes reuse geometry observed
before the restart. AX bounds are not gesture-acceptance receipts: a completely inert
product probe reports unknown input acceptance/responsiveness, never a pass.
The raw observation and selected point are retained, and the full mouse trajectory
remains fixed. No full accessibility/semantic snapshot is polled while measuring.
The final trajectory endpoint is delivered as a drag before mouse-up: SwiftUI
does not promise an `onChanged` event for mouse-up. The independent SwiftUI
control checks this input path alongside the AppKit controls.

## Scenarios and metrics

| Scenario | Work and evidence |
| --- | --- |
| `first-render` | Construct existing fixture outside measurement, join shutdown, launch a new App process; first recognizable title **and body**, then a scheduled interaction probe. Probe time is an upper bound on usability, not the exact earliest usable instant. |
| `idle.completed` | Completed tasks, no formal text/input traffic; tail pan probes continued responsiveness. |
| `idle.active` | All tasks running at a gated local provider, no formal body packets; terminal reply and tail probe follow. |
| `pan` | Fixed absolute-clock OS down/drag/up trajectory; match business-title displacement throughout direction/reversal/settling. |
| `body` | Fixed active count, scripted reasoning chunks and completed progress messages through the native Harness; tail pan probe. |
| `body.pan` | Same source schedule during system mouse dragging. |
| `zoom`, `body.zoom` | Declared but **unsupported** until a public system magnification injector is validated. Command-wheel is not silently substituted for a macOS pinch. |

The default run selects the six supported scenarios. Unsupported zoom cases
are reported only when explicitly requested.

Resource reports contain cumulative CPU deltas, single-core CPU percent,
**sampled** physical-footprint peaks and final samples for warmup, formal, tail
and whole observation. Peaks are not allocator maxima. Missing short-lived
children, reparenting uncertainty and absent exit CPU prevent a complete task
cost claim. Startup resource sampling starts immediately when the OS returns the
new launch owner, independently of window discovery/capture. It retains the
post-attachment interval separately. `startupApplication` reports cumulative App
CPU since the verified new process birth through the formal-end sample, its
actual timestamp and the sampled footprint peak; it does not invent a zero
pre-attachment memory peak or claim whole-process-tree launch cost.
The launch receipt checks birth against request/return wall times. Pre-attachment
pixels and hitches remain unobserved; the first captured content may be only a
left-censored upper bound. Reports retain these gaps.

`proc_pid_rusage` CPU counters are Mach absolute ticks. The native sampler
converts them with the host's timebase before emitting `cpuNS`. Every collector
build links the real sampler into a busy-process check against the independent
`CLOCK_PROCESS_CPUTIME_ID` clock and retains `cpu-clock-check.json` (also embedded
in `build.json`). This validates units, not a performance threshold or complete
descendant accounting. Collectors before this correction mislabeled ticks as
nanoseconds: their absolute CPU seconds and single-core percentages are invalid
on non-1:1 timebases. Keep their sealed evidence intact; any derived correction
must name the old collector and use that run's recorded timebase explicitly.
The observation declares `cpuTimeUnit: nanoseconds`; the analyzer withholds CPU
metrics when that declaration is absent or unsupported, retaining footprint data.

Pixels are sampled continuously at 5 Hz by default using ScreenCaptureKit's
screenshot API. Request/return timestamps bracket capture uncertainty; they are
**not WindowServer presentation timestamps or physical FPS**. PNG/OCR processing
cost belongs to the collector; OCR runs after collection. Raw screenshots remain
available for review. Business anchors can be any observable fixture card.
Absence of useful anchors is a measurement limitation, never a layout failure.

Hitch collection subclasses the native `XCTHitchMetric` to retain its lifecycle,
copying and raw measurements, with original identifiers, values, units and
monotonic timestamps. XCTest's discarded iteration does not dispatch workload.
It attaches to a unique existing PID + birth/launch identity and retains the
`.xcresult`; it never launches or activates the product. Its sandboxed runner
uses authenticated loopback coordination, without broader signing entitlements.
Normal, real main-thread stall and wrong-owner controls must establish capability.
If pixels freeze while hitches remain zero, the metric is **unsupported** for
responsiveness conclusions. Zero is never substituted for unavailable data.

## Controlled fixed-count output

Public `moku:submit` invokes real `create_thread` tools through a deterministic
loopback Responses provider. Public `thread:follow-up` starts the fixed set of
active tasks. The framework records the **actually selected native CLI** path,
version and digest; it does not spoof a discovery version or claim an environment
variable pins discovery. Background Tag/Report agents are disabled using public
settings with the real revision. Production embedding remains enabled.

The App's explicit `--benchmark-scenario overview` entry requires the isolated
`--data-dir` and automation socket. It records onboarding completion before the
ordinary workspace is constructed, requests a 1280 × 820 window at a fixed
initial position and disables scene restoration for this explicit scenario. This scenario preparation is the only product
hook; the renderer and business data paths remain production paths.

Each active case admits one execution per existing card before timing. Titles
stay stable, the task stays running through output, and it completes once at
the end. A completed commentary message is not a completed task. Usage is sent
only in the final response, using fixed protocol-fixture values; it is neither
a high-frequency input nor a measurement of real token consumption. Actual load
is recorded as source bytes/messages. No completion-status or title toggling
is a rendering workload. Returning from a Thread to Overview is outside this suite.

Text describes inspecting settings, checking response and cancellation behavior,
comparing results and preparing review notes. The default `--pacing sparse`
sends 2 reasoning packets/s/card: with 64-byte chunks and 512-byte messages this
means one progress-message boundary every 4 seconds in an 8-second window.
Each card has a deterministic phase within one packet interval, so independent
tasks do not all flush at the same artificial instant. Changing N preserves
every card's packet/byte budget. No card creation or staggered card appearance
is involved.

`--pacing sustained` (8 packets/s/card) and `--pacing burst` (the same bytes in
20 packets/s bursts) are explicit **stress loads**, not the default.
`--chunk-bytes` and `--message-bytes` are retained in plans. All rates are
controlled synthetic inputs, not frequencies certified from production traces.
Workload schedule version 2 records the load kind and card timing; old synchronized
workloads and the removed `return` case are not silently reinterpreted by current
analysis. Retain their evidence and original analysis identity separately.

Absolute deadlines drive output independently of UI responsiveness. The source
ledger records intended and actual sends, bytes, payload hashes and every card's
completion. Progress messages finish at the declared message boundaries without
ending the task; their bytes and send times and the terminal messages are recorded separately from reasoning
chunks. Visible CHECK markers identify those boundaries. App
coalescing and excerpt clipping are allowed; a frame per fragment is not
required. Checkpoint latency is source-flush to captured appearance, including
transport, model projection and rendering—not a renderer-only timer. Final
public execution IDs, terminal results and stable titles provide a separate
business oracle. A single immediate post-window observation checks that work
finished within the declared catch-up tail; a later eventual result cannot erase
backlog beyond that boundary. Full semantic snapshots are not polled during timed windows.
Moku can preempt its own telemetry responses when new lifecycle notifications
arrive. Those control-request disconnects are retained separately. Card/metadata
transport errors and missing planned body delivery still invalidate the run.

## Evidence and status

Each trial retains its plan, process identities, input/source ledgers, phased OS
samples, PNGs, OCR, clock brackets, public outcome, cleanup and hitch result.
SHA-256 manifests detect edits or missing evidence; they authenticate neither the
host nor third-party authors. Analysis never reseals evidence. Preparation and
source failures retain their error and do not seed later supposedly comparable
trials. Profile/provider artifacts are private synthetic data and are retained
locally; do not publish native profiles or Runtime connection tokens.

Reports separate **measurement** (`valid`, `invalid`, `incomplete`, `unsupported`),
**product** (`passed`, `unknown`, `overloaded`, `wrong-result`, `timeout`, `crash`)
and **comparison**. A terminal business result does not prove smooth rendering.
Offline analysis re-evaluates the retained calibration controls against the
collector/toolchain/OS identity instead of trusting capability booleans. A passing
product observation requires established pixel sensitivity; observed motion with
incorrect displacement is reported separately from an actual progress stall.
Incomplete measurements cannot produce a passing comparison. No statistical
regression gate, formal A/B inference, physical FPS, energy or GPU claims are
made. Fixed-count summaries permit inspection of scaling of individual observed
metrics with their coverage limitations.

The retained [2026-11-13 observation](baselines/2026-11-13.md) and
[machine-readable data](baselines/2026-11-13.json) preserve the original
incomplete 5/10-card measurements. N=20 is explicitly unmeasured; the user
stopped further collection. This snapshot is not a regression gate and belongs
to the original collector configuration, not the later default without XCTest.

The [runtime-clock optimization observation](baselines/2026-11-13-runtime-clock.md)
uses the later default collector for two 10-card scenarios. It records signed
before/after artifacts and App CPU samples, while retaining incomplete process
coverage and unavailable hitch status. It is not a statistical regression result.

## Verification boundary

`conformance` exercises the real parsers, source schedules and offline scorer
with synthetic adversarial evidence; it cannot certify a macOS collector. Hosted
Linux CI runs it. `calibrate` uses separate normal/frozen/wrong/delayed-motion,
main-thread-stall, SwiftUI drag and short-lived-child controls with the same collectors.
Its default wrong-owner control rejects a mismatched birth identity before any
input/capture; it is separate from the opt-in native hitch ownership control.
Signed production GUI experiments remain local because CI has no production
signing credentials. See [verification policy](../../scripts/ci/verification-policy.md).

The older `overview-ci-performance` and
[Overview performance probes](../verification/overview-performance/README.md)
remain diagnostics with separate baselines. Do not pool their results with these
external measurements. [Implementation references](REFERENCES.md) document the
pinned Swift open-source projects and the practices adopted here.
