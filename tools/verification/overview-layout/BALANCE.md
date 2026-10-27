# Default Overview vertical balance

This change starts from the integrated carousel fix, `0a64d7d07`, not its
original detached commit. It addresses the supplied 2026-10-27 screenshot.

## Measurements and cause

The screenshot's filter ends near y=110px, cards span y=226–1130px, and the idle
Dock begins near y=1140px. Thus the visible gaps are approximately 116px above
and 10px below. Card dimensions identify a 3×3 envelope (1112×632 world points):
one 2×2 execution/extension card, one ordinary thread and four standard reports.
The screenshot scale is approximately 1.428 image pixels per world point, and
the corresponding client viewport is approximately 1292×858 points.

The Overview GeometryReader receives the logical client viewport. Its camera
reserved the filter's 60pt toolbar band, but knew nothing about the sibling Moku
Dock. The Dock uses a 44pt idle height and `clamp(0.05 × viewportHeight, 24, 36)`
bottom seat. There was no shared bottom reservation or safe-area correction.
The old 40% spare-space anchor therefore balanced against the window edge,
rather than against the bottom control. Changing that fraction alone would
actually move this collection further down.

The same production camera geometry compiled from the baseline and working tree
gives the following values for the screenshot's logical viewport and envelope:

| Measurement (points) | Before | After |
| --- | ---: | ---: |
| Card scale | 1.0 | 1.0 |
| Card envelope top | 139.2 | 103.0 |
| Card envelope bottom | 771.2 | 735.0 |
| Gap below reserved toolbar boundary (60) | 79.2 | 43.0 |
| Gap above idle Dock top (778) | 6.8 | 43.0 |

The production SwiftUI Canvas independently measures `(90, 103, 1112, 632)`
after the change. Packing and scale remain unchanged; the collection moves up
36.2pt. In screenshot pixels, the expected visual gaps are about 64px / 61px.
Their small difference is the toolbar's existing 2pt clearance below the chip.
These screenshot conversions are estimates, not a capture of the user's app
after installation.

## Geometry contract

The workspace projects the toolbar boundary and the Dock's idle surface into
`NativeOverviewViewport`. The Dock reservation is derived from its production
capsule geometry, and is zero when no Moku Dock exists. Compact filter rows use
their existing taller toolbar boundary.

The actual content region lies between those persistent controls. Preferred
horizontal margins remain 32/64pt. The Dock consumes the existing vertical
padding budget, leaving equal preferred gaps above and below; it is not added
on top of two full vertical margins. On ordinary wide windows this preserves
the fitting extent and readable scale. Collection fits, retained filter fits,
automatic restoration and attention targets share the available region's center.

Carousel capacity uses actual control-free space, not preferred margins or
current camera visibility. The planner first retains its ordinary inset policy.
If that result exceeds actual capacity, it tries the full control-free extent
before admitting a carousel. In the prior recording's five-card case, a 3×4
envelope would exceed the Dock boundary by 2.8pt; the 4×3 alternative fits at
0.85, with measured top/bottom gaps of 90.5/90.3pt (native pixel rounding).
The fallback is a second bounded solve only when the preferred result does not
fit. Cancellation and layout-stage ownership remain shared with the first solve.

## Regression coverage and limits

`NativeOverviewCenteringTests` hosts the production Canvas with the workspace's
viewport projection and real Dock geometry. It measures mounted card frames at
500, 620, 621, 860, 1180 and 2560pt widths with 1, 3 and 16 cards; mixed report/
execution footprints; extension growth/shrinkage; native window resize; manual
pan and return; visibility/interaction-deferred return; and camera bookmarks.
The mixed-card case verifies equal clearances and unchanged mounted identities.
The prior five-card case verifies the wider fitting alternative, true overflow
in a small window, and recovery without a stale carousel target.

The tests use production layout/camera components with geometric card fixtures;
they do not assert report text rendering or replay physical trackpad input.
Transient composer/note/notification expansion retains its overlay and interaction
ownership: opening it does not repack cards. Ordinary stationary-survivor revisions
still preserve reading position where possible; explicit return restores balanced
default framing. True oversized scenes retain readable overflow/carousel behavior.
No running user application, Note replay, or other worktree is operated on.

## Local validation (2026-10-27)

- `make check ARGS=` passed (clear the caller's inherited `--fresh` argument).
- 63 tests passed across `NativeOverviewCenteringTests`,
  `NativeOverviewCapacityTests`, `NativeOverviewCarouselCenteringTests`,
  `NativeOverviewCameraReadabilityTests`, `NativeOverviewAutoReturnTests` and
  `NativeOverviewTransitionTests`, with `--no-parallel`.
- `python3 tools/verification/overview-input/run.py` reported
  `PASS Overview SwiftUI replay completed` in its isolated fixture app.
- Baseline/current production geometry probes produced the table above; rendered
  Canvas measurements independently confirmed the after values and equal gaps.
- Local diff and documentation-link review passed. No physical trackpad or live
  user-workspace replay was run.
