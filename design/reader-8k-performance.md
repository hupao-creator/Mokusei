# Agent reader: 8 KiB performance investigation

The 2026-11-12 experiment uses the existing single-reply external benchmark.
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

## External 8 KiB results

One formal trial per build and scenario was collected. Both builds passed all
four product outcomes and visible-motion checks. Every prepared reply retained
the same corpus SHA-256
`0dc5f366d8085d430c4e176418849da400ab99b3cda972dfd4085e6e9ef58496`.

The following is **observed application-process CPU time in each ten-second
formal window**, not elapsed opening time, complete process-tree cost or a
statistically established regression threshold:

| Scenario | Baseline CPU | Candidate CPU | Observed reduction |
| --- | ---: | ---: | ---: |
| First opening | 120.08 ms | 87.58 ms | 27.1% |
| Reopening | 118.57 ms | 82.98 ms | 30.0% |
| Steady scrolling | 153.94 ms | 105.28 ms | 31.6% |
| Scrolling during output | 237.87 ms | 207.35 ms | 12.8% |

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

## Validation

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
