# Agent reader: 8 KiB performance investigation

The first 2026-11-12 experiment uses the existing single-reply external benchmark.
Baseline source is local `b8dd7f5`; the retained signed Release application was
built at `fbec437`, with identical production sources at that baseline. The
candidate changes only native viewport sizing; it does not simplify the corpus,
remove rendered blocks, virtualize text or change animation durations.

## Workload and collection

Both applications receive the same 8 KiB target fixture: 8,552 UTF-8 bytes in
seven mixed Markdown sections, including seven code blocks and seven two-column
tables with three data rows each. This is a repeatable mixed-content workload,
not a measured distribution of users' replies or a table-only stress test.

The window is 1280 × 820 points. The four scenarios are first opening an existing
reply after application restart, reopening in the retained process, alternating
scroll gestures, and scrolling during one subsequent execution's output.
Each formal window lasts ten seconds. Input, screenshot cadence (5 Hz), resource
sampling (10 Hz), warmup and tail are unchanged. Native input/visible-motion
controls are reused from `/private/tmp/mkr-cal-04` with the same collector.

Separate diagnostic runs enable the existing native performance trace and take
two ten-second `sample` captures while opening and scrolling the same reply.
Those captures are not pooled into the external benchmark timings or CPU data.

## Finding and change

The baseline parses Markdown once in 5.59 ms across two visits. Each visit
creates 156 native text views and performs one actual text layout per view;
the existing text-width caches already prevent repeated glyph layout.

The main-thread samples instead repeatedly enter SwiftUI's platform-view fitting
path, then AppKit's `systemLayoutSizeFittingSize` and recursive constraint
collection over the reader's descendants. The outer panel and retained
execution-handoff container had no explicit sizing response, despite their
width and height already being determined by workspace geometry.

Both bridges now return a finite parent proposal directly. Unspecified or
unbounded proposals retain default sizing. The panel's manually framed
`NSHostingView` also disables content-derived sizing constraints, as the retained
handoff seats already do. Content still receives its actual viewport width and
performs its existing layout; selection, copying, scroll ownership and animation
admission keep their existing implementation.

This uses Apple's documented
[`NSViewRepresentable.sizeThatFits`](https://developer.apple.com/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:))
boundary and the fixed-frame optimization supported by
[`NSHostingView.sizingOptions`](https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions).

## Diagnostic results

| Observation | Baseline | Candidate |
| --- | ---: | ---: |
| First opening: `reading.prepare` | 421.95 ms | 122.25 ms |
| Second opening: `reading.prepare` | 433.78 ms | 108.80 ms |
| First sample: main-thread samples containing AppKit fitting | 1,616 / 6,412 | 10 / 6,515 |
| Second sample: main-thread samples containing AppKit fitting | 1,911 / 7,406 | 13 / 7,799 |
| Markdown parsing across both visits | 1 call, 5.589 ms | 1 call, 5.591 ms |
| Native text creation / actual text layout across both visits | 312 / 312 | 312 / 312 |

Fitting samples count a stack only once, excluding nested occurrences of the
same fitting function. They are sampled stack observations, not exact call
counts or a conversion to CPU milliseconds. The preparation spans are existing
instrumented native phases, not the external entry-to-visible-content endpoint.
The diagnostic evidence is retained as `mkr-prof-base` and `mkr-prof-candidate`.

## External 8 KiB results (CPU units corrected)

The first report mislabeled `proc_pid_rusage` CPU ticks as nanoseconds. A native
process-clock control subsequently reproduced the error: 200,013,000 ns of CPU
versus 4,800,598 reported "ns". All eight runs recorded a Mach timebase of 125/3.
The CPU values below are derived corrections using that factor; they are not new
captures. The original sealed reports retain the erroneous absolute CPU values
for audit. Same-host percentage reductions are unchanged. Opening/scroll timing,
native diagnostic spans and footprint values use independent units and are
unaffected by this correction.

One formal trial per build and scenario was collected. Both builds passed all
four product outcomes and visible-motion checks. Every prepared reply retained
the same corpus SHA-256
`0dc5f366d8085d430c4e176418849da400ab99b3cda972dfd4085e6e9ef58496`.

The following is **observed application-process CPU time in each ten-second
formal window**, not elapsed opening time, complete process-tree cost or a
statistically established regression threshold:

| Scenario | Baseline CPU | Candidate CPU | Observed reduction |
| --- | ---: | ---: | ---: |
| First opening | 5.003 s | 3.649 s | 27.1% |
| Reopening | 4.941 s | 3.458 s | 30.0% |
| Steady scrolling | 6.414 s | 4.387 s | 31.6% |
| Scrolling during output | 9.911 s | 8.640 s | 12.8% |

First recognizable content remained in the same sampled interval: 0.562–0.820 s
before and 0.565–0.820 s after. Reopening changed from 0.761–1.017 s to
0.566–0.821 s, with overlapping intervals. These observations do not establish
an end-to-end opening-latency improvement. The diagnostic preparation saving
does not directly translate into that external endpoint; panel travel and
content admission still participate in the complete opening path.

Steady-scroll response bounds overlap (maximum upper bound 0.260 s before and
0.267 s after); output-scroll bounds also overlap (0.258 s and 0.262 s).
The reduced sampled CPU cost does not establish smoother display-frame pacing.
All scripted gestures still produced the required visible movement. Sampled
peak footprint was mixed rather than improved: respectively 95.95/102.11/100.95/
112.00 MiB before and 93.09/103.58/103.45/115.38 MiB after in table order.

The original sealed reports, captures and resource observations are retained as
`mkr-perf-baseline-01` and `mkr-perf-candidate-01`, alongside the calibration,
diagnostic captures and replay logs in the local main checkout's
`.scratch/reader-8k-performance-20261112/`. No benchmark or oracle changes were
needed for this optimization.

## Interpretation limits

These are local Release observations, not a performance gate or statistical
population estimate. Screenshot intervals bound when recognizable content or
scroll movement appeared; they do not measure display FPS. The collector's
native hitch positive control and complete descendant/exit-CPU coverage remain
unavailable, so the original reports retain `measurement: incomplete` and
`comparison: not-comparable`. Any CPU comparison is restricted to the observed
application process during the declared formal window, not complete task cost
or renderer-only attribution. No hitch count or score is certified by this work.

## Validation of viewport sizing

The final production source passed the signed Release build and these existing
native integration replays, run serially before the external candidate capture:

- `--markdown`: 11 tests, including content growth/shrink, window resizing,
  selection/copy, table geometry and footnote return.
- `--thread-send-feedback-native`: 5 tests, including retained reader handoff,
  final viewport widths, reduced motion, cancellation and resident editor focus.
- `--moku-landing`: 10 tests, including actual Agent/Report panels, workspace
  resizing, input admission and Close/return geometry.
- `make lint` and whitespace/local-document-link review passed.

Two initial build attempts rejected relocated Clang/Metal module caches copied
from another local checkout. Those generated caches were removed from this
worktree. A subsequent build correctly rejected a README edit made during
compilation; rerunning against the settled inputs produced the verified signed
bundle. No production or replay failure was bypassed.

Delivery is explicitly local-main only. Hosted CI, the full Swift suite and the
full `make check` were not run; the scoped replays above are the executed checks.
The read-only remote rule snapshot had no required status checks and no PR for
this branch. No remote mutation or temporary protection exemption was used.


## Follow-up: block-local selection and deferred rendering

The user explicitly accepted removing cross-paragraph selection. Native Select
All, drag selection and copy now stay within one paragraph, code block or table
cell. The document context menu still copies its complete Markdown source.
The shared selection registry, cross-view responder ownership and custom
cross-block mouse tracking loop are removed. Execution capsules use native
attachment-click delegation and retain keyboard/accessibility activation.

Completed replies with a reading viewport now defer top-level blocks through
`LazyVStack`. Nested list/quote content and atomic code/table blocks keep their
existing layout. Footnote documents retain eager native anchors, exposure-tracked
notes retain exact geometry, and streamed page admission remains unchanged.
Offscreen native views can be retained at their old size; entering the viewport
must reflow them at the current width. This is visit-local SwiftUI state, with
no global native-view or cross-document height cache.

Ordinary inline text also drops its empty SwiftUI help wrapper. Image failures
set the existing native text view's tooltip and accessibility help instead.
The mixed successful-image/missing-file fixture requires the failure hint, while
image-only paragraphs require no hint.

The new native viewport replay verifies that the last of 60 paragraphs is not
mounted initially, reaches it and copies its text, narrows the window from 700
to 350 points, and revisits top/bottom/top requiring actual text reflow. Existing
execution-link coverage now traverses all 200/220 uniquely numbered paragraphs
through each of the four production Harness readers, requiring exact complete
sets instead of assuming every native paragraph is mounted simultaneously.

The first version of the viewport replay invoked responder-chain scrolling on
a SwiftUI scroll bridge and hung/crashed. It now uses the same native clip-view
scroll operation as existing replays. Subsequent diagnostics showed visible
paragraphs correctly reflowed while deferred hidden views retained old widths;
the final replay requires both ends to reflow on return. The old all-mounted
and whole-document-selection expectations were updated for the explicitly
changed contract, without skipping content, click or navigation checks.


### Follow-up measurement method

This round uses signed Release applications from `b6877d3` (viewport sizing
already fixed) and the deferred-rendering candidate, with the same 8,552-byte
corpus and input/capture schedules. Both use the corrected collector, whose
independent CPU-clock ratio was 1.000068 on this host. Fresh normal, frozen,
reverse-direction, delayed-input and real main-thread-stall controls all produced
the expected reading outcomes, matching both native input receipts and pixels.

The baseline is recaptured for first opening and steady scrolling; the candidate
runs all four scenarios. Reopening and output-scrolling have no fresh baseline
in this round and are reported without a new percentage comparison. There is
one formal trial per listed build/scenario, with the same process-tree and
hitch limitations described above. Original pre-correction reports are preserved;
`cpu-unit-correction.json` beside the original evidence records explicit derived
values and the SHA-256 of each original report and timebase record.

These measurements compare the combined selection, deferred-block and native-help
change. They do not separately attribute CPU savings to each of those changes.


### Follow-up external results

All six trials passed product outcomes and visible-motion checks. The table
reports observed **application-process CPU seconds in each ten-second formal
window** and sampled peak physical footprint; it is not opening latency or
complete task cost.

| Scenario | Baseline CPU | Candidate CPU | CPU reduction | Baseline / candidate peak footprint |
| --- | ---: | ---: | ---: | ---: |
| First opening | 3.570 s | 2.401 s | 32.8% | 95.39 / 82.35 MiB |
| Steady scrolling | 4.345 s | 2.617 s | 39.8% | 100.35 / 88.25 MiB |
| Reopening | Not recaptured | 2.239 s | — | — / 87.69 MiB |
| Scrolling during output | Not recaptured | 5.442 s | — | — / 98.42 MiB |

First recognizable content was bounded by 0.766–1.024 s before and
0.565–0.815 s after; the intervals overlap, so this trial does not establish
an end-to-end latency improvement. Steady-scroll response bounds also overlap
(maximum upper bound 0.2605 s before and 0.2579 s after). CPU and footprint
savings therefore do not certify smoother display-frame pacing or an FPS gain.

The corrected fresh baseline is consistent with the earlier derived correction
(3.570 versus 3.649 s for opening; 4.345 versus 4.387 s for scrolling). No old raw
report or capture was rewritten to obtain the new results.

The candidate's steady-scroll trace additionally records the `MokuseiEmbedding`
helper disappearing after about three formal seconds. Its exit CPU is unavailable;
that trace therefore retains the explicit missing-root/incomplete accounting
reason. The application process is present in all 141 samples, so the table is
restricted to that observed process and makes no aggregate helper/runtime claim.


### Follow-up diagnostic and validation evidence

Separate two-visit diagnostic captures use the same reply and scroll script,
with native tracing and `sample`; their timings are not pooled into the formal
resource measurements.

| Observation | Viewport-sizing baseline | Deferred candidate |
| --- | ---: | ---: |
| Native text views created before each sampled scroll visit | 156 / 156 | 25 / 25 |
| Native text creation / actual text layout across both visits and scrolling | 312 / 312 | 88 / 88 |
| Markdown parse across both visits | 1 call, 4.553 ms | 1 call, 4.646 ms |
| Main-thread stacks containing `NSHostingView.layout`, visits 1 / 2 | 991 / 1,024 | 525 / 736 |
| Main-thread stacks containing panel hit testing, visits 1 / 2 | 492 / 497 | 122 / 186 |

The sampling runs contain 9,243/9,339 main-thread samples before and 8,599/9,470
after. Counts describe sampled stacks, not exact call counts. This locates a
reduction in native views and layout/hit-testing work; parsing remains unchanged.
The native preparation phases do not show a further consistent improvement,
so no additional preparation-latency claim is made.

The production candidate passed a signed Release build and 32 native integration
tests: 12 Markdown, 3 local-image, 12 execution-link and 5 completion-handoff
methods (parameterized methods cover multiple cases). The shared benchmark
passes 67 contract controls and the reading extension passes 23 scorer/provider
controls. Native CPU units and all five reading-input controls passed. Static
lint, diff review and local document links are checked before local-main merge.
Hosted CI, a full Swift suite and full `make check` are outside this local-only
delivery; no remote push or merge is performed.

Raw formal captures, calibration, native diagnostics, initial failure logs,
source/binary provenance and the final report are retained under the local main
checkout's `.scratch/reader-8k-lazy-20261112/`. Earlier raw reports remain under
`.scratch/reader-8k-performance-20261112/` with an explicit CPU-unit correction
notice and separate derived correction file.


## Rejected follow-up: reading-control observation

A subsequent candidate moved exact scroll geometry out of Observation and
resolved reading-control values on query/operation, with revisions preserving
stale-handle rejection. The candidate passed its mounted control and reading
replays, but its CPU benefit did not survive the reverse-order measurement.
The production change and its candidate-only test were withdrawn.

The unchanged 8 KiB workload ran in A/B/B/A order. The first pair followed the
first-opening case in the same fixture; both runs of the reverse pair used
fresh fixtures and opened the reader directly. Application-process CPU in each
ten-second scroll window was:

| Matched setup | Baseline | Candidate |
| --- | ---: | ---: |
| After first opening, A then B | 2.586 s | 2.458 s |
| Fresh reader, B then A | 2.209 s | 2.451 s |
| Mean of these two trials | 2.397 s | 2.455 s |

The first pair's 4.9% saving reversed in the second pair; the candidate mean was
2.4% higher. First opening was effectively unchanged (2.370 versus 2.364 s).
All eight planned product outcomes passed, including candidate reopening and
output-scrolling, but these observations do not justify retaining the added
control mechanism. The rejected patch, full raw observations and logs are
preserved with this round's Sidecard evidence.


## Execution Sidecard output and divider resizing

The user subsequently reported visible stalls with an Execution Sidecard and
while adjusting its width. These are separate from the earlier steady-reader
scroll case. The retained change has two parts:

- Divider samples update the host's retained widths and layout snapshot without
  rebuilding plugin views or their observation leases. Drag entry/exit still
  reconcile suppression.
- During an Execution Sidecard pointer drag, both native documents keep their
  starting widths behind the live panel shells. Mouse release commits the final
  widths. Content remains live and unscaled; a wider shell can temporarily expose
  empty space, and a narrower shell clips the old wrapping. Selection changes,
  workspace resizing and completion handoff stop retaining the drag widths.
  Keyboard/accessibility changes and other Sidecard types resize normally.

The user accepted this temporary wrapping behavior and confirmed that resizing
must remain available. There is no change to stored width preferences or the
responsive stacking breakpoint.

A separate output-following candidate combined a bottom size-change anchor with
an actual-distance correction. Its standard output-scroll CPU observation was
5.459 s versus 5.483 s for the candidate; static divider CPU was 8.227 s versus
8.274 s in the unprofiled pair. No stable benefit was established, so that
production change was withdrawn. Earlier variants failed bottom following,
including a Release case whose viewport stopped 1,039pt above the bottom while
its logical edge still reported bottom. These failures and the rejected patch
are preserved. The existing four-Harness replay now also checks bottom following
when a wrapping reply's native window widens and narrows.

### Sidecard measurement method

The production baseline is local `e0b5117`. Both signed Release applications use
the corrected collector and the same main reply, window and real system inputs.
The standard `reading.output-scroll` case retains its original source schedule,
capture cadence, semantic checks and eight visible reply checkpoints.

Separate diagnostics enable native tracing, timeline construction counters and
`sample`. Static resizing keeps one completed 8,552-byte message in an active
Execution Sidecard, with its terminal response withheld. A real pointer drag
widens the Sidecard by 140 points over four seconds, then returns over four
seconds, at 60 scheduled events/second. The baseline reflows both readers continuously; the retained candidate changes
only their shells until release. Another diagnostic combines the original ten-second output schedule
with that drag. These profiling observations are not pooled with formal CPU
trials, and the minimal diagnostic collector does not capture display frames.

### Retained divider result

Fresh unprofiled comparisons used the same signed baseline/candidate bundles,
fixed 8 KiB content and 480-event real pointer gesture. Each observation covers
a ten-second measurement window; these are one trial per application/case, not
a statistical performance gate. Static runs used baseline then candidate;
output runs used candidate then baseline.

| Application-process CPU | Baseline | Retained candidate | Change |
| --- | ---: | ---: | ---: |
| Drag with a settled 8 KiB reply | 8.244 s | 7.542 s | −8.5% |
| Drag while reply messages arrive | 9.733 s | 8.932 s | −8.2% |

All four runs retained 141/141 application resource samples and exited cleanly.
Both static runs remained at the active reply's bottom after release. In both
output runs the source delivered all eight settled messages plus its terminal
reply without errors, and the final reader admitted the completed execution.
Those final-state checks do not certify every intermediate output frame.
Process-exit CPU coverage remains incomplete, and no optical hitch/FPS score is
available; the numbers describe only the continuously sampled app process.

A separate traced candidate run recorded no uncached native `text.layout`
spans in the measurement window, compared with 8,980 spans (1,054.994 ms total)
in the earlier traced baseline. The gesture returns to its starting width, so
this isolates continuous drag reflow; the mounted test separately releases at a
new width and requires actual reflow. Profiling runs are not pooled with the CPU
comparison. The remaining timeline/body and shell work is still substantial;
these results do not establish that every visible stall has been eliminated.

### Sidecard validation

The mounted fold replay verifies that width samples do not rebuild plugin views
and that both drag boundaries still update context. The production-reader replay
also drives the native divider, checks fixed text widths at three intermediate
positions, requires final reflow on release, retains native text identity and
checks immediate accessibility resizing. Existing completion, stacked layout,
manual-scroll interruption, jump-to-latest and composer-focus assertions remain.

The first handoff replay exposed a Reduced Motion observation race: its
transaction-complete flag could arrive while native geometry still had the
source width. The replay now waits for the actual final native panel/aperture
sizes in that mode; animated cases still require intermediate frames and all
size assertions remain. The failed native poses, diagnostic images and logs are
retained. An earlier Release attempt rejected a source edit during compilation;
the settled source was subsequently rebuilt rather than reusing that artifact.

The new accessibility-resize assertion initially assumed that text width always
changes one-for-one with viewport width. Its extra 24pt step crossed the existing
540pt responsive-padding breakpoint: main text changed by 116pt for a 144pt
viewport change. The replay now requires the exact native viewport change and
Sidecard text width, while preserving the existing responsive padding. The
initial failed run and its native artifacts remain alongside the corrected run.

Final-source local checks passed: Debug build with test targets, `make lint`,
5 native Sidecard/handoff methods (39.156 s), 12 execution-link/routing methods
(38.655 s), and the signed Release bundle verification. Hosted CI and the full
local suite were not run: this delivery is explicitly local-main only. Existing
remote run results are not used to certify these changes.

Raw observations, input plans, sampled profiles, before/after WindowServer
captures, failures, rejected patches, final source snapshots, binary hashes and
verification logs are retained in local main's
`.scratch/reader-sidecard-performance-20261112/`. Its manifest records hashes for
copied files; sockets and symlinks are excluded. The benchmark protocol and
previous sealed reports are unchanged.
