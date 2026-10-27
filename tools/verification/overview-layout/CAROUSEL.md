# Unnecessary carousel regression

The supplied 2026-10-27 15:25:03 recording is 15.753 seconds, 2672×1778 pixels.
AVFoundation frames were decoded with both requested time tolerances set to
zero. Approximate/keyframe extraction is unsuitable here: it returned unrelated
earlier presentation content for some requested times.

At 0.995s the lower 2×2 card is centered and the upper cards are clipped. At
3.995s the upper-right standard card is centered and the bottom row is clipped.
At 7s the upper-left 2×2 card is centered. At 8.992s manual navigation has
started; at 10.983s and 14.978s all five cards are visible. The card footprints
and spacing remain unchanged across these exact frames: two 2×2 cards plus
three 1×1 cards, in a 3-column × 4-row envelope (1112×848 world points).

In the 1440×958 decoded frames, a standard card is approximately 330×183 pixels,
consistent with scale 0.85 after the recording's 2× backing scale and image
resizing. The window is approximately 1292×858 points. At this viewport the
preferred 64pt margins and 60pt toolbar leave 1164×670 points. The collection
at the readable floor occupies 945.2×720.8 points: too tall for preferred
margins, but fully within the 1292×798 points below the toolbar. This explains
why translation alone can reveal all cards.

The root cause was using `fitsAtReadingScale`, the planner's preferred-inset
fit predicate, as the hard carousel capacity predicate in both restoration and
normal attention reconciliation. It was already independent of current camera
translation; changing an offscreen-card check would not fix this case.

The fix preserves packing, readable scale and ordinary framing. Only carousel
capacity uses the real viewport below the toolbar, for both admission and exit.
The existing symmetric overflow framing already shows the whole scene when it
fits only by consuming preferred margins. True viewport overflow still cycles.

Regression coverage uses production code:

- `NativeOverviewCapacityTests.recordingFootprintsFitWithoutMarginsAndRecoverAfterExtensionGrowth`
  hosts the five footprints in SwiftUI, checks rendered frames, grows both
  extension cards into real overflow, shrinks them, pans manually, refreshes
  attention facts and returns to automatic framing. Mounted identities persist.
- The resize capacity case distinguishes preferred-margin loss from actual
  capacity loss and checks recovery from a genuinely undersized window.
- `NativeOverviewCarouselCenteringTests` restores a displaced automatic camera
  without briefly centering an attention card, and exercises admission/exit at
  both horizontal and vertical hard boundaries, including toolbar clearance.

Run these suites with:

```sh
xcrun swift test --package-path app/macos --no-parallel \
  --filter 'NativeOverviewCapacityTests|NativeOverviewCarouselCenteringTests'
```

The ordinary [Overview input replay](../overview-input/README.md) additionally
checks production input and camera ownership. These tests do not replay physical
trackpad hardware or the user's live conversation data.

Local verification on 2026-10-27:

- The capacity and carousel suites passed all 24 tests, including the mounted
  five-card regression and existing carousel centering/manual cancellation.
- After strengthening the restoration test to inspect every animation target,
  all 30 carousel, automatic-return and readability tests passed.
- An identical probe compiled against the baseline and fixed production camera
  reproduced `carouselTarget=note` before and `carouselTarget=nil` after, both
  at scale 0.85. The fixed fit is `(x: 173.4, y: 98.6)`, placing the collection
  entirely below the toolbar without any manual input.
- `make check ARGS=` passed. The first invocation inherited `ARGS=--fresh` from
  the caller and failed because Go's test runner rejects that option; clearing
  that unrelated launcher argument allowed the complete required check to run.
- `python3 tools/verification/overview-input/run.py` reported
  `PASS Overview SwiftUI replay completed` in its isolated application.
