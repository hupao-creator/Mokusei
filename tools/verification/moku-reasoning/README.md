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

Checks include three visible dots and naturally changing pixels, source/segment
identity and UTF-16 offsets, append clock continuity, absence of admitted/painted
reasoning glyphs, tool-to-reasoning priority, composer/note/voice ownership,
disconnect/reconnect, completion, failure, interruption, waiting for user input,
reply completion, terminal retirement while inactive/hidden and resumption through
the same display clock and eye identity. The transition replay separately
covers rapid reversals and bottom/landing viewport fitting. The standalone Arc
study remains available but does not certify production thinking presentation.

Evidence defaults to `.build/moku-reasoning-evidence`: measurements, result,
own-window screenshots, isolated launch/resource receipts and cleanup logs.
The launcher stages source, object files, frameworks and all resources in
temporary storage and cleans up only its owned process on timeout. Run SwiftPM
builds and graphical replays serially. No real model request, account, microphone
or WebRTC session is used. Voice mode uses presentation fixtures only.
Window hide/show covers terminal retirement and clock resumption; physical
minimize behavior remains outside this replay's scope.
