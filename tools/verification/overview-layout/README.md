# Overview layout comparison

Run from this worktree on macOS:

```sh
python3 tools/verification/overview-layout/run.py --baseline <before-commit> --output /private/tmp/overview-layout-comparison
```

The driver compiles the complete production solver and the production camera's pure geometry prefix, first from the requested Git revision, then from this working tree. It does not launch the application, access profiles or mutate Git. Three runs per version assert deterministic placements. JSON retains every placement, screen camera, visible-area fill, complete visible count, moved survivor count (>1pt), maximum/total top-left screen displacement, search steps and elapsed time. Raw source/compiler inputs remain beside the executable.

The same command also compiles [the history regression driver](regression.swift)
against both versions. Its `before-regression.json` and `after-regression.json`
retain the production-viewport deletion and sidecard-width-shrink paths behind
the seven-card screenshot (`ABC / DEE / F.. / .GG`). The deletion replay begins
with a solver-produced full grid, expands three cards while their adjacent cards
exit, then deletes a wide card and the lower-left card. The shrink replay starts
from the necessary `ABC / DEE / FF. / .GG` notch and narrows F. Both must finish
as a full 3×3 grid by moving only G up one row, then remain fixed on replay.
This proves possible production histories, not the user's unrecorded event order.
The unchanged-footprint solver case documents that the old fast path itself
retained the screenshot; Canvas semantic geometry reuse does not call that solver.

The [second screenshot replay](SECOND-SCREENSHOT.md) records the distinct
eight-card `ABC / DEE / F.. / G.H` fixture: seven unit reports and one 2×1
Thread/Git envelope. Original PR #166 head already repairs it to 3×3 by moving
F right before G and H move up (808 world points total). The regression covers
fresh/structural planning, stable replay, bounded fallback, exact fitting bounds
and multiple representative production viewport extents. It does not infer
execution/camera state or certify which Canvas branch produced the screenshot.

The regression driver independently checks final membership/nonoverlap and
samples every certified sequential survivor move using production shrink/exit
ordering. The transposed screenshot checks column removal and an offset screenshot
checks nonzero grid origins. Necessary center/width vacancies and refill, explicit compact/filter
planning, insufficient capacity, proof/optimization budget exhaustion, conflicting
growth, truncated fitting witnesses and 100/500-card layouts retain coverage.
Before a smaller witness is established, an exhausted proof must preserve legal
history; after proof, an exhausted compact search must retain the smaller readable
witness with `requiresRepack`. These are headless geometry/camera assertions;
the command does not mount Canvas or certify rendered animation.

The drivers pass the same readable/natural extents as Canvas when that version supports them, and apply its stationary-survivor camera policy only to revisions without entrants. Older baselines without these production contracts retain their earlier policy. Insertions use automatic collection framing. The native capacity suite separately verifies the actual Canvas and camera lifecycle, including delayed refits and manual-pan retention. Geometry time includes input validation; it is neither main-thread latency nor rendered frame time. Baseline and after begin from their own initial layout and default camera. Screen coordinates, not solver travel alone, determine the displacement metrics. The three-card fill assertion checks nonregression rather than requiring a historical improvement already present in a recent baseline.

See [historical local results](RESULTS.md) and committed compact metrics. Those 2026-10-26 metrics predate insertion recentering: six-to-seven now moves survivors 188pt to the collection anchor rather than clamping them by 98pt to the nearest visible edge.

Cases include the research's 900×750 three-card fill, nine-card center deletion/refill, six-to-seven insertion, same/reversed members, 600/900/1420/1920/2560-point windows, and 16/30/100/500-card initial layouts. Mixed-footprint growth, capacity recovery, filter/search/gesture/transition and mounting contracts remain covered by existing native suites and the [input replay](../overview-input/README.md).

Scope: bounded necessary empty space and zero-survivor-movement insertion/growth are preferred. A preserved envelope also needs to resist a proven reduction by one row or column; occupancy alone cannot establish that. Conflicting growth still uses the existing planner; there is no new local collision-component solver, rank-based spatial ordering, resize hysteresis, FIFO replacement, or virtualization. The 75% grid occupancy threshold remains a conservative policy bound, not a measured optimum. No third-party implementation was copied; the existing research's preserve-position/free-slot ideas are implemented directly in Swift.

Reduce Motion is exercised through an isolated host override of the production motion policy (the OS accessibility environment is read-only) in native capacity tests. Explicit retirement hides outgoing/transparent semantic nodes. These assertions do not constitute a VoiceOver speech/focus audit, physical input test, or optical animation/frame-rate measurement.
