# Thread opening: reuse the window backdrop

2026-11-04 · [work item #247](https://github.com/hupao-creator/Mokusei/issues/247)

The reported completed Codex thread was slow to open in Native Dev. Existing
performance logs showed roughly 1.55 seconds from navigation to Markdown delivery,
although subscription readiness took milliseconds and the actual parser took
about 0.1–1ms. A reproduction through the built-in interaction API and a main-thread
sample found `NativeReadingParentView.scheduleCapture` spending substantial time
inside `cacheDisplay`, `CALayer.renderInContext` and CoreGraphics transparency
compositing. Sampling perturbs execution; that attempt is excluded from timings.

The user clarified that even blurred Overview cards are unnecessary behind the
reader. The final implementation removes parent bitmap capture entirely. The
isolated parent fades fully out during panel travel and its native host is hidden
once the panel and title handoff settle. The existing window-owned
`ultraThinMaterial` remains visible. No extra material layer or screenshot cache
is introduced. The same retained host, controls, camera and authoritative data
resume at the latest viewport during return preparation; refreshed cards fade
back in during the original panel return. Nested non-isolated reading retains
its previous presentation. Panel duration, title handoff and text entrance are
unchanged.

## Local observations

Both builds used the real development profile and the same thread and viewport.
All navigation after initial discovery used the native interaction socket.
Temporary measurement clients were stopped; the original user process was not
terminated. The final signed development generation remains open on the thread.

| Navigation to completed Markdown delivery | Baseline | Final |
| --- | ---: | ---: |
| Open 1 | 1622ms | 885ms |
| Open 2 | 1623ms | 799ms |
| Open 3 | 1600ms | 1028ms |

These are three unsampled interactive opens per build, not frame-presentation
latency or an FPS measurement. The baseline samples follow a sampled warm-up;
the final first open is the first observed in its process. They do not establish
a controlled cold OS/font/cache comparison. Other desktop processes remained
running. Median Markdown delivery decreased from 1622ms to 885ms (about 45%).
The original animation and subsequent text entrance still take time.
[Timing and binary input hashes](thread-backdrop-performance.json) identify the
observed builds. Raw logs, sampling output and API observations remain local under
`/private/tmp/moku-thread-perf.8ZQrtR`; no conversation body is copied here.

## Review and validation

- Final `make fast ARGS='--no-open'`: Debug build, signing and bundle verification passed.
- Final production thread-panel replay: passed source/heading handoff, completed
  and running text entrance, close and interrupted opening. Reviewed its ready
  screenshot: the background is clear of Overview cards.
- Final `NativeMokuLandingTests` native replay: all 10 passed, including retained
  host identity, hidden update/resize suppression and latest-layout return.
  The existing integration assertion now checks the retained hidden host rather
  than requiring the removed bitmap.
- Reviewed cancellation/return ownership and the full diff; no asynchronous
  capture task or generation callback remains. No new unit tests were added.

The user explicitly requested local-main integration only, with no push. Remote
rules still require a PR and `Complete coverage`; they were inspected but not
changed. Hosted CI and a duplicate full local `make check` were not run. This
local result does not certify the unpushed history against remote merge gates.
