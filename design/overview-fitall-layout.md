# Overview FitAll layout refactor

> 动效策略已更新：本文有关系统 Reduce Motion 的行为与验证描述仅记录历史。当前应用不再感知该偏好；见[移除清单与验证](remove-reduce-motion.md)。

## Problem

The former layout and camera were coupled to update history. The audit found:

- `NativeOverviewLayout.plan` took `previous`, `preservePositions`, a fitting
  extent and a search budget. It preserved survivor top-left positions, required
  75% grid occupancy, searched for a compact shape, certified straight moves and
  cached incomplete search outcomes. A second capacity attempt could replace the
  first legal witness, while a failed search could keep an older layout onscreen.
- `NativeOverviewCanvas` queued every structural revision in a FIFO. A worker
  suspended in card motion did not pull a later collection until older revisions
  were consumed. Repeated viewport requests could cancel camera work while the
  card queue continued.
- `NativeOverviewCamera` carried `readingFit`, `retainedX`/`retainedY`,
  `lastAutomaticFit`, `framingRetained`, `pendingAutoFit`, a 160ms refit delay,
  a 600ms throttle, a fixed readable floor and a 16-cell budget. It inferred
  reading intent from the difference between the live transform and the old
  target, and created persistent vertical seats after height shrink.
- Tests and documents encoded those behaviors: `NativeOverviewPackingTests`,
  `NativeOverviewCameraReadabilityTests`, `NativeOverviewAutoReturnTests`, the
  transition/capacity fixtures and the layout comparison driver.

These rules made the final screen depend on update order, animation progress and
whether a search had completed. The same final cards could produce different
placements or camera targets after a different update path.

## New model

`NativeOverviewLayout.solve(members:usableViewport:policy:)` is pure. Its only
inputs are the latest members in product order, the usable viewport and an
explicit policy (grid metrics and scale cap). It returns placements, the exact
world union and the automatic camera. No previous placement, camera, animation
sample, pause state or revision is an input.

The solver evaluates a bounded deterministic candidate set:

1. a uniform grid for every column count `1...N` using the largest measured span;
2. horizontal and vertical shelf packs, sampled at no more than 65 targets on
   their respective packing axes (columns and rows);
3. horizontal product-order shelf packs under the same bound.

Candidates are ranked by unclamped FitAll scale, then world area, width and a
stable seed. The uniform-grid pass includes the independent regular-grid quality
baseline for every column count, so a selected result cannot fit worse than that
baseline. The grid pass is `O(N²)`; shelf passes are `O(65N)` after sorting.

Shelf target ranges include both endpoints. For more than 64 available target
values, the step is `ceil((count - 1) / 64)`, keeping the enumeration within 65
targets even when spans make the range much larger than the card count.

The camera is FitAll: `scale = min(cap, min(V.w/B.w, V.h/B.h))` and
`translation = V.center - scale × B.center`. There is no readable floor, cell
budget or retained reading seat. Manual pan/zoom is explicit user state and is
never replaced by background geometry. Live camera bookmarks derive their mode
from that single owner; pausing a return animation cannot restore stale manual
ownership, including when the automatic target already matches the current view.

Card composition may use up to three grid columns (`HarnessOverviewCapacity.maximumColumns`).
This is a card capability: the resulting footprint, including 3×2, is an input to
the same FitAll solver. The canvas default toolbar clearance is the actual
persistent tag-bar height, shared with fixtures through `NativeOverviewViewportDefaults`.

`NativeOverviewCanvas` uses latest-wins geometry. A new structural snapshot
cancels the in-flight presentation, samples current card poses, and starts one
transition to the latest target. An older task cannot publish, clear
`isLayingOut`, or consume a newer revision. Pauses settle the sampled pose and
retain the pending target; resuming resolves the latest content. Geometry reuse
also revokes any obsolete worker waiting for the spatial stage, so an A→B→A
update cannot publish B after returning to A. `Reduce Motion` commits immediately.

## Verification

- `NativeOverviewGeometryTests`: seeded generated inputs, full-input and
  reduced-input reporting, identity/size, non-overlap and gaps, exact bounds,
  finite values, FitAll containment/centering, cap, viewport translation,
  determinism and the regular-grid quality floor, plus a 1,500-card 4K/ultrawide
  case that checks legality, cap and the same regular-grid quality floor. Mixed
  3×2/2×1 and 3×2/3×1/2×1 cases compare both shelf axes against independent legal
  packing witnesses.
- `NativeOverviewCameraTests`: FitAll, manual ownership, pause/hide before and
  during explicit return, matching-target bookmark ownership, latest-wins,
  invalid geometry and empty collections.
- `NativeOverviewHeadlessGeometryTests`: bare `NSHostingView` with no window;
  mixed footprints, resize, toolbar/Dock reservations, scene resets and
  `displayedFrame` agreement.
- `NativeOverviewCenteringTests`, `NativeOverviewCapacityTests`,
  `NativeOverviewTransitionTests`: graphical mounted production Canvas,
  rendered frames, rapid revisions, interruption, zero viewport and
  invalid-snapshot recovery. Membership and viewport A→B→A replays hold the
  spatial stage until the final input is admitted, then verify that the obsolete
  worker cannot replace the reused geometry.
- `NativeOverviewStatePropertyTests`: randomized event traces against the mounted
  Canvas with a shrinking replay; failures print the complete input and reduced event sequence. A fixed reduced trace is checked in as `reducedInterleavingRegressionConverges`.

## Remaining limits

The solver does not claim globally optimal packing for arbitrary mixed
rectangles; the regular-grid result is a quality floor, not an optimum proof.
Exits, moves and entries share one transition rather than proving collision-free
paths. The 1.0 cap is an explicit product parameter; a caller may pass nil for a
raw FitAll scale. Native decoration capture and signed-app replays remain
separate owners and are not certified by these geometry tests.
