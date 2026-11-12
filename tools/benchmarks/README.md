# External Overview rendering benchmark

This Python CLI runs against a **built, signed production Release `.app`**. It
builds only its independent macOS collectors, XCTest UI target and control app.
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
real active-agent body output. There is **no layout score**, visible-card quota,
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
  --scenario first-render idle.completed idle.active pan return body body.pan
python3 tools/benchmarks/benchmark.py analyze /private/tmp/overview-run/n-5/05-body
```

Outputs must be new directories. Live experiments need Screen Recording,
Accessibility and system input permission in the invoking context, an unlocked
visible desktop and exclusive use of the foreground window during each trial.
The collector records foreground loss, missed input deadlines and capture gaps.
Response/stasis estimates retain sampling bounds. A bound that straddles the
declared progress deadline is incomplete evidence; only a lower bound beyond
the deadline establishes overload. Missing recognized body checkpoints are an
observation gap, not proof that the content froze.
Do not run two GUI experiments together. Exit 2 means incomplete/unsupported
measurement, not a statistical performance regression. The current unprivileged
process sampler always exposes incomplete descendant/exit accounting.
Repeat entries such as `--scenario return return return` to observe successive
returns in one existing profile; each has a separate plan and evidence directory.

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
outside the existing card/control rectangles. This is input preparation, not a
layout score or visible-card quota. Missing geometry or a blocked point cannot
be interpreted as a frozen canvas. Entry probes reuse geometry from the preceding
Overview. AX bounds are not gesture-acceptance receipts: a completely inert
product probe reports unknown input acceptance/responsiveness, never a pass.
The raw observation and selected point are retained, and the full mouse trajectory
remains fixed. No full accessibility/semantic snapshot is polled while measuring.

## Scenarios and metrics

| Scenario | Work and evidence |
| --- | --- |
| `first-render` | Construct existing fixture outside measurement, join shutdown, launch a new App process; first recognizable title **and body**, then a scheduled interaction probe. Probe time is an upper bound on usability, not the exact earliest usable instant. |
| `idle.completed` | Completed tasks, no formal text/input traffic; tail pan probes continued responsiveness. |
| `idle.active` | All tasks running at a gated local provider, no formal body packets; terminal reply and tail probe follow. |
| `pan` | Fixed absolute-clock OS down/drag/up trajectory; match business-title displacement throughout direction/reversal/settling. |
| `return` | Open a real thread outside measurement; system Command-K returns to Overview; content appearance and scheduled pan probe are separate. |
| `body` | Fixed active count, meaningful cumulative reasoning-summary chunks and natural message boundaries through real native Harness; tail pan probe. |
| `body.pan` | Same source schedule during system mouse dragging. |
| `zoom`, `body.zoom` | Declared but **unsupported** until a public system magnification injector is validated. Command-wheel is not silently substituted for a macOS pinch. |

Resource reports contain cumulative CPU deltas, single-core CPU percent,
**sampled** physical-footprint peaks and final samples for warmup, formal, tail
and whole observation. Peaks are not allocator maxima. Missing short-lived
children, reparenting uncertainty and absent exit CPU prevent a complete task
cost claim. Startup resource sampling begins after the OS returns the launch
owner; pre-attachment XCTest hitches are unavailable. Reports retain these gaps.

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

## Realistic fixed-count output

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

Titles stay stable. Text describes inspecting settings, checking response and
cancellation behavior, comparing results and preparing review notes. Defaults:
64-byte chunks, 512-byte messages, 8-second windows. `--pacing sparse` sends 2
reasoning packets/s/card; `sustained` sends 8; `burst` sends the same 8 packets and bytes
per second in a 20 packets/s burst. `--chunk-bytes` and `--message-bytes` are
explicit and retained in plans. These are experimental workloads, not claims
about average real model rates. Changing N keeps per-card work constant.

Absolute deadlines drive output independently of UI responsiveness. The source
ledger records intended and actual sends, bytes, payload hashes and every card's
completion. Completed progress notes summarize each natural message boundary; their bytes
and send times and the terminal messages are recorded separately from reasoning
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

## Verification boundary

`conformance` exercises the real parsers, source schedules and offline scorer
with synthetic adversarial evidence; it cannot certify a macOS collector. Hosted
Linux CI runs it. `calibrate` uses separate normal/frozen/wrong/delayed-motion,
main-thread-stall and short-lived-child controls with the same collectors.
Signed production GUI experiments remain local because CI has no production
signing credentials. See [verification policy](../../scripts/ci/verification-policy.md).

The older `overview-ci-performance` and
[Overview performance probes](../verification/overview-performance/README.md)
remain diagnostics with separate baselines. Do not pool their results with these
external measurements. [Implementation references](REFERENCES.md) document the
pinned Swift open-source projects and the practices adopted here.
