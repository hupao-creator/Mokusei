# Overview layout verification

**Historical comparison retired.** Overview now uses the pure FitAll solver in
[NativeOverviewLayout](../../../app/macos/Sources/Host/Overview/NativeOverviewLayout.swift).
That solver has no previous placements, search budget, topology repair or move
certification, so the old baseline/current comparison driver was removed rather
than kept as a different-contract imitation. [RESULTS.md](RESULTS.md) and
[SECOND-SCREENSHOT.md](SECOND-SCREENSHOT.md) retain historical measurements from
the former incremental planner; they are not results for the current algorithm.

Current verification runs against the production implementation:

- `NativeOverviewGeometryTests` generated inputs verify membership, latest sizes,
  finite/legal geometry, world gaps, exact bounds, FitAll containment and
  centering, viewport-translation covariance, determinism and the independent
  regular-grid quality floor. Failures retain the seed, full input and reduced
  input.
- `NativeOverviewCameraTests` covers FitAll, manual ownership, pause/hide,
  latest-wins and invalid-input recovery without a readable floor or retained
  reading seat.
- `NativeOverviewCenteringTests`, `NativeOverviewCapacityTests`,
  `NativeOverviewTransitionTests` and `NativeOverviewStatePropertyTests` mount
  the production Canvas and assert actual rendered frames. The state suite
  replays randomized insert/remove/footprint/viewport/pause/visibility/manual/
  content schedules and shrinks failures by removing events.
- [BALANCE.md](BALANCE.md) records the persistent-control gap measurements used
  by the workspace viewport; it remains a product-layout reference.
