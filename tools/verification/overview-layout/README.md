# Overview layout comparison

Run from this worktree on macOS:

```sh
python3 tools/verification/overview-layout/run.py --baseline <before-commit> --output /private/tmp/overview-layout-comparison
```

The driver compiles the complete production solver and the production camera's pure geometry prefix, first from the requested Git revision, then from this working tree. It does not launch the application, access profiles or mutate Git. Three runs per version assert deterministic placements. JSON retains every placement, screen camera, visible-area fill, complete visible count, moved survivor count (>1pt), maximum/total top-left screen displacement, search steps and elapsed time. Raw source/compiler inputs remain beside the executable.

The after driver passes the same readable/natural extents as Canvas and applies its stationary-survivor camera policy only to revisions without entrants. Insertions use automatic collection framing. The native capacity suite separately verifies the actual Canvas and camera lifecycle, including delayed refits and manual-pan retention. Geometry time includes input validation; it is neither main-thread latency nor rendered frame time. Baseline and after begin from their own initial layout and default camera. Screen coordinates, not solver travel alone, determine the displacement metrics.

See [historical local results](RESULTS.md) and committed compact metrics. Those 2026-10-26 metrics predate insertion recentering: six-to-seven now moves survivors 188pt to the collection anchor rather than clamping them by 98pt to the nearest visible edge.

Cases include the research's 900×750 three-card fill, nine-card center deletion/refill, six-to-seven insertion, same/reversed members, 600/900/1420/1920/2560-point windows, and 16/30/100/500-card initial layouts. Mixed-footprint growth, capacity recovery, filter/search/gesture/transition and mounting contracts remain covered by existing native suites and the [input replay](../overview-input/README.md).

Scope: bounded empty space and zero-survivor-movement insertion/growth are preferred. Conflicting growth still uses the existing planner; there is no new local collision-component solver, rank-based spatial ordering, resize hysteresis, FIFO replacement, or virtualization. The 75% grid occupancy threshold is a conservative policy bound, not a measured optimum. No third-party implementation was copied; the existing research's preserve-position/free-slot ideas are implemented directly in Swift.

Reduce Motion is exercised through an isolated host override of the production motion policy (the OS accessibility environment is read-only) in native capacity tests. Explicit retirement hides outgoing/transparent semantic nodes. These assertions do not constitute a VoiceOver speech/focus audit, physical input test, or optical animation/frame-rate measurement.
