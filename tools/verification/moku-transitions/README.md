# Moku transition replay

```sh
python3 tools/verification/moku-transitions/run.py
# Immediately after building current production modules:
python3 tools/verification/moku-transitions/run.py --skip-build
```

The replay mounts the production `NativeMokuScene` and `NativeMokuDock` in an
isolated native window. It observes the actual shared display-link controller,
captures WindowServer pixels, and never calls `draw` or advances a test clock.
The face must remain the same single native view throughout role changes.

Cases cover idle → running, interruption during the orbit, running → thinking,
same-segment text append, full input expansion/collapse, reversals in both
directions, rapid running/thinking/tool changes, inactive pause/resume, and
thinking retirement/landing. Directory completion uses the mounted NSTextView
and fixture catalog in both bottom and centered landing layouts: opening,
filtering down/growing, Escape and rapid reversals must keep the existing face
within 1.5 points of its resting offset from the editor row. This catches inner
menu layout animation moving the editor independently of the outer glass/face.
The replay first confirms that the actual menu opened and that Escape closed it.
Narrow 300×190
and 180×140 logical viewports must contain the renderer's full glyph envelope
after fitting in both bottom and enlarged landing presentation; Overview
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
