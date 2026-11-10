# Moku transition replay

```sh
python3 tools/verification/moku-transitions/run.py
# Immediately after building current production modules:
python3 tools/verification/moku-transitions/run.py --skip-build
# Focused column/Browser-annotation travel regression:
python3 tools/verification/moku-transitions/run.py --skip-build --horizontal-only
```

The obsolete eye-seat, blink and reasoning-presentation stage has been removed.
The existing horizontal compositor regression below remains; `--horizontal-only`
selects the same retained regression. Composer selection, completion and
Note/Talk lifecycle cases remain in the existing Swift regression suites.

The horizontal stage mounts the production Scene, Dock and cross-host column
markers with ordinary and annotation drafts. Equal-width columns isolate pure
translation. ScreenCaptureKit records actual capsule pixels on a separate queue
while the fixture deliberately holds the main actor for 200ms. Injection begins
after the first observed optical travel frame rather than a fixed delay near
the end of the current monotone easing; the original movement/count bounds remain unchanged. At least three
different positions spanning 20pt must appear inside that interval; a display-link
counter or the final layer destination cannot satisfy this assertion. The former
SwiftUI offset remains stationary in this interval. This controlled fault verifies
compositor independence, not the cause or duration of real application stalls.

The stage also checks revision-fenced arrival and rapid reversal, absorption of
pointer hits on the moving capsule, at most one native editor width change when
entering a narrower column, retained drafts and resize settling. Arrival is checked against the newly published column revision;
a queued receipt for the old revision does not describe the requested trip.
`horizontal-frames.json` and `horizontal-*.png` retain optical evidence, including
on assertion failure. No real Browser page, user profile, account or settings are
modified. Run this targeted local replay when changing Moku's native horizontal
transport; the existing default CI does not include this standalone pixel probe.
