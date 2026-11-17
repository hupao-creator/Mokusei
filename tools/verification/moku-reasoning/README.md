# Native Moku thinking loading replay

```sh
python3 tools/verification/moku-reasoning/run.py
# After a current make check / Swift build:
python3 tools/verification/moku-reasoning/run.py --skip-build
python3 tools/verification/moku-reasoning/run.py --skip-build --negative-control \
  --evidence .build/moku-reasoning-negative-control
```

This mounts the production Dock and drives Runtime fixture transactions through
the real RuntimeState validator, workspace catalog, Codex Harness projection and
live Moku presentation. Moku's reasoning text Arc is temporarily hidden; the
replay checks retained reasoning data and the existing three-dot loading instead.

The native window runs its normal event loop. ScreenCaptureKit captures only
the current process's full-sized window; transformed/transparent images fail
as capture errors. The replay never forces draw calls or advances animation
clocks. The negative control supplies an inactive scene and must fail the
specific natural-motion pixel observation.

Checks include three visible dots and changing pixels, source/segment identity,
UTF-16 offsets, append clock continuity, tool priority, composer/note ownership,
disconnect/reconnect and terminal retirement.

The transition replay separately
covers rapid reversals and bottom/landing viewport fitting. The standalone Arc
study remains available but does not certify production thinking presentation.

Evidence defaults to `.build/moku-reasoning-evidence`: measurements, result,
own-window screenshots, isolated launch/resource receipts and cleanup logs.
The launcher stages source, object files, frameworks and all resources in
temporary storage and cleans up only its owned process on timeout. Run SwiftPM
builds and graphical replays serially. Window hide/show covers terminal retirement and clock resumption; physical
minimize behavior remains outside this replay's scope.

The fixture uses the production warm capsule and restored persistent eye seat.
Its existing saturated-dot oracle remains independent of the shell. It follows
the decoration canvas without adding eye-seat assertions. The native resident
sleeps between its cancellable idle blink wakes after the handoff.
