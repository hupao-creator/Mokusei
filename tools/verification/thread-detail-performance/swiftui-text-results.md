# SwiftUI reading text: measured renderer cost

The migration was subsequently reverted at the user's request. This report
records the historical implementation; it does not describe current rendering.
The retained benchmark requires revision `39d0941` and matching Release modules.

Measured product revision: `7a9b962140c0f326b0bc8cc5fb16f2eef63dc15e`.
Date: 2026-11-06. Apple M1 Pro, macOS 26.5.1 (25F80), Swift 6.3.2.
Production modules: Release with `-enable-testing`; standalone probe: `-O`.
The flag exposes internal production views; neither renderer is reimplemented.

**This migration is not a demonstrated performance improvement.** In the
Thread condition both fixtures cost more CPU and memory with SwiftUI. The
mixed document shows a small median warm-mount CPU decrease only without the
existing Thread row-host wrapper, with overlapping sample ranges. No performance optimization was applied in this study.

## Thread condition

Medians of four independent processes per cell; CPU is milliseconds of process
user + system time. Memory is mounted whole-process physical footprint in MiB,
not bytes uniquely owned by the document.

| Fixture / metric | AppKit | SwiftUI | Change |
| --- | ---: | ---: | ---: |
| Prose: first mount CPU | 298.7 ms | 878.3 ms | +194% |
| Prose: second mount CPU | 217.8 ms | 775.0 ms | +256% |
| Prose: second mount elapsed | 270.6 ms | 826.9 ms | +206% |
| Prose: resize CPU, narrow + wide | 258.4 ms | 466.0 ms | +80% |
| Prose: mounted footprint | 96.3 MiB | 397.9 MiB | +313% |
| Mixed: first mount CPU | 856.2 ms | 1464.4 ms | +71% |
| Mixed: second mount CPU | 975.7 ms | 1358.2 ms | +39% |
| Mixed: second mount elapsed | 993.6 ms | 1405.4 ms | +41% |
| Mixed: resize CPU, narrow + wide | 204.7 ms | 266.2 ms | +30% |
| Mixed: mounted footprint | 108.2 MiB | 197.9 MiB | +83% |

Second-mount CPU ranges do not overlap in the Thread condition: prose
212.2–219.4ms vs 745.2–920.4ms; mixed 961.8–1015.8ms vs 1354.4–1491.3ms.
Four samples are useful for this local comparison, not a formal population
estimate or a CI acceptance threshold.

## Plain Markdown condition and container cost

| Fixture / metric | AppKit | SwiftUI | Change |
| --- | ---: | ---: | ---: |
| Prose: second mount CPU | 226.0 ms | 657.5 ms | +191% |
| Prose: mounted footprint | 95.1 MiB | 393.2 MiB | +314% |
| Mixed: second mount CPU | 938.3 ms | 886.2 ms | -6% |
| Mixed: mounted footprint | 106.9 MiB | 169.9 MiB | +59% |

The controlled scope switch adds about 117ms of median warm-mount CPU to the
SwiftUI prose fixture and 472ms to mixed content. The migration's
NativeThreadRevealRow wrapper creates one NSHostingController seat per text
leaf even when the entrance has finished. The counts observed after layout are:

| Fixture | AppKit text views | SwiftUI custom text views | SwiftUI Thread row hosts | Total native views, AppKit → SwiftUI Thread |
| --- | ---: | ---: | ---: | ---: |
| Prose | 160 | 0 | 160 | 349 → 1149 |
| Mixed | 640 | 0 | 640 | 2029 → 5149 |

Thus removing application-owned NSTextView is not equivalent to reducing native
view count or memory. The scope comparison isolates a substantial container
cost, but it does not explain all of the plain SwiftUI renderer regression.
Allocation attribution or a CPU profile would be a separate diagnostic run;
there was no profiler attached to these timing samples.

## Method and limits

- Same executable, same pre-parsed blocks, same viewport and fonts; the renderer
  environment switch selects the two production implementations. No checkout,
  source replacement or alternate implementation is used between conditions.
  Both use the shared adapter; the action router and per-mount anchor identity
  match the production reader, preserving its block-equality optimization.
- Each sample starts a fresh foreground app process, mounts once, removes the
  document, waits 100ms, mounts again, and resizes 900→500→900pt at 700pt height.
  The source is 160 long paragraphs (66,608 UTF-8 bytes), or 40 mixed sections
  containing headings, prose, lists, three-column tables and code fences.
- Four rounds alternate AppKit→SwiftUI and SwiftUI→AppKit for each condition.
  The run contains 32 valid samples. Both renderer paths are exercised in every
  round; background/occluded samples are rejected.
- Layout settling explicitly drives AppKit layout/display and waits for four
  unchanged positive height observations at 16ms intervals. Elapsed times
  include that stabilization allowance and are not optical first-paint times.
- The Thread condition supplies a *finished* reveal scope. It measures the
  persistent container overhead, not panel opening, animation FPS, line masks,
  parsing, Harness decoding, network transport, streaming follow or selection.
- Footprint includes framework caches and retained allocations after two mounts.
  It is not a memory-leak diagnosis or the RSS of the user's full running app.
- Rendered wide-document heights differ: prose 16066→16482pt (+2.6%); mixed
  16534→16603pt (+0.4%). This measures the actual migrated behavior, not identical
  pixels. No accessibility scan, screenshot or profiler runs in timing windows.
- This is one foreground desktop machine, not an isolated hardware lab. It is
  not evidence about power, GPU, WindowServer CPU or all document sizes.

Raw values and provenance are in [swiftui-text-results.json](swiftui-text-results.json).
The complete per-process logs/receipts are in
`.scratch/thread-swiftui-performance/20261106-004130` in the task worktree.
An initial driver attempt detected two JSON records because LaunchServices
appended stdout across launches. That attempt was rejected; the driver now
clears redirected logs before each fresh process. The 32 reported samples come
only from the final complete run. An earlier exploratory run omitted the
production action router and is excluded from these reported numbers.
The plain mixed-content warm CPU ranges overlap (905.4–977.1ms vs
856.2–913.4ms), so its 6% median decrease is not a robust general benefit.

## Next optimization boundary

Keep the requested SwiftUI text model, but profile and reduce its plain-document
allocation/layout cost, and remove the per-leaf native hosting seats from the
Thread entrance path. Coordinate that change with the parallel animation work.
Re-run these same fixtures after changes, alongside selection/link/layout tests;
a faster renderer is not sufficient if it drops required behavior. No positive
whole-app performance claim should be made for the current migration.
