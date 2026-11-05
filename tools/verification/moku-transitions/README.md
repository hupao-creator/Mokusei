# Moku transition replay

```sh
python3 tools/verification/moku-transitions/run.py
# Immediately after building current production modules:
python3 tools/verification/moku-transitions/run.py --skip-build
# Focused column/Browser-annotation travel regression:
python3 tools/verification/moku-transitions/run.py --skip-build --horizontal-only
```

The replay mounts the production `NativeMokuScene` and `NativeMokuDock` in an
isolated native window. It observes the actual shared display-link controller,
captures WindowServer pixels, and never calls `draw` or advances a test clock.
The face must remain the same single native view throughout ordinary role changes.
Idle eyes must stop display-link frames between natural blinks and resume at the
next blink. At the end, entering an Agent Harness identity must remove the face;
the retained empty decoration seat must stay asleep across a full blink interval.

Cases cover idle → running, interruption during the orbit, running → thinking,
same-segment text append without exposing reasoning text, full input expansion/collapse, reversals in both
directions, rapid running/thinking/tool changes, inactive pause/resume, and
thinking retirement/landing. Directory completion uses the mounted NSTextView
and fixture catalog in both bottom and centered landing layouts: opening,
filtering down/growing, Escape and rapid reversals must keep the existing face
within 1.5 points of its resting offset from the editor row. This catches inner
menu layout animation moving the editor independently of the outer glass/face.
The replay first confirms that the actual menu opened and that Escape closed it.
Narrow 300×190
and 180×140 logical viewports must contain the loading resident in both bottom and enlarged landing presentation; Overview
reservation remains unchanged. Landing also crosses thinking → input → thinking
through the same native face without forcing input open on entry during a run.

`frames.json` records observed pose steps and clocks. The bound on eye movement
detects discontinuous geometry replacement while allowing ordinary motion
between two real display frames. It also records the mounted eye view's frame in
window coordinates and requires input transitions to stay within their measured
resting-position envelope, with one point of backing-alignment tolerance. This
catches the vertical jump caused by accepting retiring-editor geometry even when
the internal eye pose stays continuous. It is not a complete perceptual
smoothness or physical refresh-rate certification. PNGs retain the native frames for review.

Set `MOKU_TRANSITION_EVIDENCE` to select the output directory (default
`/tmp/mokusei-moku-transition-evidence`). The fixture captures only its own
window, opens no runtime or account, and never changes system motion preferences.
Run this and other native replays serially with SwiftPM builds.

The horizontal stage mounts the production Scene, Dock and cross-host column
markers with ordinary and annotation drafts. Equal-width columns isolate pure
translation. ScreenCaptureKit records actual capsule pixels on a separate queue
while the fixture deliberately holds the main actor for 200ms. At least three
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
