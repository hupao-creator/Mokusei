# Long Markdown opening: bound layout probes

2026-11-04 · [work item #249](https://github.com/hupao-creator/Mokusei/issues/249)

The reported completed OpenCode reply has 39 Markdown blocks and mounts 139
native text views. Its cached parse took about 0.1ms, but its first three seconds
recorded 45,979 text-size queries, including 45,738 cache hits. Main-thread samples
were dominated by SwiftUI layout negotiation and native `sizeThatFits` calls.
TextKit layout itself totaled 222ms. Turning off detailed diagnostics still left
0.69–0.74 seconds of individual native API response stalls, so logging amplified
rather than explained the layout problem.

## Implementation

`NativeMarkdownColumn` proposes the reading width directly to its blocks instead
of negotiating vertical flexibility. Its layout-local cache holds at most four
width proposals and is reset by SwiftUI layout/subview invalidation. Lists reuse
the column. Fixed leading slots for markers, quote rules and footnotes avoid
horizontal-stack minimum-width probes: an intermediate build showed 189ms spent
laying out 51 paragraphs at one-point width, despite their real width being
hundreds of points. SwiftUI handles right-to-left mirroring.

The full document stays mounted. Native selection/copy, footnotes, tables, image
resolution and streaming keep their production components and owners; no lazy
viewport cut-off, retained reader or cross-document height cache is introduced.

`NativePerformance.recordTextCache` batches hit/miss counts by surface at the
existing 250ms writer interval. It avoids per-probe identifiers, timestamps,
record/dictionary allocation and JSON output. Pending contexts are bounded to
256, overflow is counted as dropped, and shutdown/reconfiguration drain their
own recorder. Detailed records contain `queries`, `hits`, `misses`; summary count
remains the number of queries. Batch timestamps are drain times.

## Same-thread observations

All navigation used the built-in native interaction API. Both runs used signed
Debug applications, detailed diagnostics, the same completed reply and viewport.
Three unsampled repeated opens per build exclude startup restoration. A sampled
run is diagnostic evidence only and is not included in timing comparisons.

| Observation | Baseline | Final |
| --- | ---: | ---: |
| API opening-ready median | 1831ms | 783ms |
| Median of each open's slowest API response | 812ms | 251ms |
| Recorded text-size queries in first 3s | 45,979 | 278 |
| TextKit layout sum in first 3s | 222ms | 14–15ms |
| One-point paragraph layouts | Present | 0 |
| Mounted native text views | 139 | 139 |
| Document / viewport height | 5641 / 742pt | 5641 / 742pt |

[Timings and final build hashes](markdown-layout-performance.json) preserve all
three opening results (final readiness 683–968ms; maximum responses 179–266ms).
The same counter sums satisfy `queries == hits + misses`; only two cache records
per opening were emitted in the final first-three-second windows. A directed
reopen also confirmed the heading position, with top offset zero.

Opening-ready means the API reports no transition and a mounted ready turn; it
is not the final rendered pixel or completion of all decorative text entrance.
API polling adds observation overhead, desktop load was not controlled, and
these samples are not percentile/FPS or cold-font-cache guarantees. The initial
baseline counts come from recorded per-query events; the new batches retain
counts without flooding the regular event queue. Private source content and raw
logs remain outside the repository under `/private/tmp/moku-opencode-profile.MitwNr`
and `/private/tmp/moku-markdown-opt.ZacCqY`.

## Review, failures and validation

The first extended Markdown replay found a real RTL regression: custom placement
was manually mirrored even though SwiftUI already mirrors it. Removing that
manual transform fixed the original side-position assertion. The new resize
case initially used the replay helper's fixed-width root, so window resizing did
not resize its reader; it now uses a real resizable hosting root with the same
size-growth/shrink assertions. Once all ten cases passed, the launcher correctly
rejected its obsolete eight-test count; the required count was raised to ten.
Failure logs are retained locally. No assertions were loosened or skipped.

Final checks passed:

- Signed Debug build and bundle verification.
- Ten native Markdown cases: copy/selection, tables, footnotes, Unicode input,
  actual text growth/shrink and native window resize, both writing directions.
- Three native local-image cases, including asynchronous image layout and streaming.
- Twelve execution-link/routing tests across Codex, Claude, Pi and OpenCode,
  including streamed pages, historical targets and concurrent content consumers.
- Production panel replay: title handoff, hidden preloading, line entrance,
  normal return and interrupted opening.
- Diff and local documentation links reviewed; the pre-commit hook runs repository lint.

Scope remains local-main-only integration, without push or hosted CI. Remote
PR/Complete coverage requirements were inspected and left unchanged. No duplicate
full local `make check` was run. Temporary measurement clients are separate from
the user's original process; the final optimized instance remains on the report.
