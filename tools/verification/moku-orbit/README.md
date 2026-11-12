# Production Moku orbit regression

```sh
python3 tools/verification/moku-orbit/run.py --skip-build
```

This retains the former blink replay's existing orbit case. The retired capsule
blink, eye-focus/mask, eye-slope and blink-negative-control cases were removed
during the orb rebrand. Restoring the eye renderer does not restore those
removed test cases or claim their coverage. No new test cases were added.

The fixture mounts the production Scene/Dock with its warm capsule material;
the unchanged colored-pixel oracle distinguishes dots from the actual glass.
It captures a full cycle, requires colored ink beyond all four sides and outside
the glass, and checks inactive pause, three static Reduce Motion dots, tool/input/
idle/cancel retirement and restart. The scene phase is supplied by the isolated
AppKit fixture; system preferences and real accounts are never changed.

The existing 3-second orbit uses quintic smootherstep: acceleration over its
first half and deceleration over its second half, with zero endpoint velocity.
ScreenCaptureKit captures only the fixture's own window. Failed captures and
JSON results are retained under `MOKU_ORBIT_EVIDENCE` (default
`/tmp/mokusei-moku-orbit-evidence`). Run serially with SwiftPM/native replays.
