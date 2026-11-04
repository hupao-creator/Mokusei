# Paced native Markdown creation and cross-thread review

2026-11-04 · [work item #250](https://github.com/hupao-creator/Mokusei/issues/250)

The user kept existing animation, asked to investigate sub-100ms main-thread
stalls and repeat-visit caching, then requested closure and cross-thread checks.
They explicitly preferred removing a complex cache without clear overall gains.
The preceding width-driven layout change is on local main as `8898dcd`.

## Final changes and ownership

- Native reveal registries, task handles, masks and admission bookkeeping are
  outside SwiftUI observation. User-visible completion stays observed.
- Initial non-streamed Agent Markdown admits small top-level batches between
  main-loop turns. A batch estimates about 12 native text leaves; lists and tables
  remain atomic. This budgets work, not a hard time limit. The document-ready
  gate and token acknowledgement wait for all blocks. New revisions interrupt
  older batches, including empty replacements; disappearance cancels the worker.
  Existing displayed content and streaming pages retain their ordinary path.
- All content remains mounted after admission. Native selection/copy, callbacks
  and scroll state keep their visit ownership. Panel and line animation durations
  are unchanged.

A cross-visit attributed-string cache was tried and removed before integration.
It achieved warm hits but did not establish broad end-to-end gains, and native
attributes/attachments add ownership complexity. The final implementation has no
new formatting/native-view cache. Existing parse/content caches and simple
layout-local measurements remain. The discarded experiment is clearly separated
from final results in the JSON.

Review caught an empty-replacement edge in paced admission before verification;
empty documents now clear any in-flight prefix. The added native integration
case exercises real partial mounting and supersession without weakening readiness.

## Cross-thread measurements

Both versions used signed Debug applications, detailed diagnostics and the same
built-in interaction API. Each case had three opens and 5ms polling for three
seconds. Document/viewport geometry matched. The old package predates `8898dcd`,
so the table measures the combined layout and admission work, not the isolated
contribution of this follow-up. Desktop activity, OS/font caches and process
startup were not controlled.

| Case | Opening-ready median, before → final | Median of each open's slowest response, before → final |
| --- | ---: | ---: |
| OpenCode long report | 1495 → 732ms | 813 → 163ms |
| Codex short reply | 583 → 586ms | 160 → 158ms |
| Codex medium reply | 596 → 593ms | 150 → 162ms |
| Codex longer reply | 599 → 617ms | 166 → 164ms |

[All samples and build hashes](markdown-repeat-visit-performance.json) retain
slower cases. The final medium and longer Codex cases include 239ms and 281ms
responses respectively. Three samples cannot establish a general regression or
percentile gain, and do not support claiming universal speedup. The longer Codex
opening-ready median was 18ms slower; shorter cases were effectively unchanged.

**Sub-100ms is not achieved across these samples.** The substantial benefit is
concentrated in the complex OpenCode report; its final slowest-response samples
were 143–195ms. Opening-ready means no reported transition and a mounted ready
turn, not full pixel reveal. Snapshot waits are responsiveness observations, not
CPU-only intervals or FPS. All full document heights were preserved: 5641, 486,
1048 and 1263 points. No source report body was committed. Raw observations are
local under `/private/tmp/moku-sub100.WYPHC2`.

## Final verification and delivery

The final no-formatting-cache build passed signing and bundle verification, then:

- 11 native Markdown tests, including paced empty supersession, exact source-byte
  replacement, resize/growth/shrink, RTL, selection/copy, tables and footnotes.
- 3 local-image tests, including asynchronous native media and streaming behavior.
- 12 execution-link/routing tests across four Harnesses, including streamed pages,
  historical targets and independent content consumers.
- Production panel replay: title handoff, hidden preloading, protected first paint,
  text entrance, normal return and interrupted opening.

The Markdown launcher requires exactly 11 cases. The temporary cache-specific
case was removed with that implementation; no retained assertion was relaxed or
skipped. The earlier layout-stage RTL and fixed-width-fixture failures and their
corrections are recorded in [the preceding investigation](markdown-layout-performance.md).
Diff and local links were reviewed; the normal commit hook runs repository lint.

Delivery is local main only, without push or hosted CI. Actual remote PR and
Complete coverage rules were inspected and left unchanged. No duplicate full
local `make check` is claimed. The user requested closing this round rather than
expanding it further; the unmet sub-100ms target is reported explicitly.
