# Native Moku thinking Arc replay

```sh
python3 tools/verification/moku-reasoning/run.py
# After a current make check / Swift build:
python3 tools/verification/moku-reasoning/run.py --skip-build
python3 tools/verification/moku-reasoning/run.py --skip-build --negative-control \
  --evidence .build/moku-reasoning-negative-control
```

This replaces the retired contour replay. It mounts the production Dock and
drives authenticated-shape Runtime fixture transactions through the real
RuntimeState validator, workspace catalog, Codex Harness Moku projection and
live Moku presentation. The new Arc uses the accepted 288° open circle and
source-position glide reader; there is no continuously rotating text phase.

The native window runs its normal event loop. ScreenCaptureKit captures only
the current process's full-sized window; transformed/transparent images fail
as capture errors. The replay never forces draw calls or advances animation
clocks. The negative control supplies an inactive scene and must fail the
specific natural-motion pixel observation, not an unrelated build/window error.

Checks include current-source identity, same-segment and high-rate append
continuity, UTF-16 source offsets, new segments and executions, empty content,
assistant/tool/terminal retirement, short-text settling, composer and sealed
submission restoration, note/voice/Talk ownership, disconnect, route coverage,
remount, real hide/show and a natural eye blink. Source retirement and bounded
retiring glyph paint are checked separately; handoff motion cannot keep an
expired execution live. The transition replay separately covers rapid reversed
handoffs and whole-capsule viewport fitting.

Evidence defaults to `.build/moku-reasoning-evidence`: measurements, result,
own-window screenshots, isolated launch/resource receipts and cleanup logs.
The launcher stages source, object files, frameworks and all resources in
temporary storage and cleans up only its owned process on timeout. Run SwiftPM
builds and graphical replays serially. No real model request, account, microphone
or WebRTC session is used. Voice mode uses presentation fixtures only.
Programmatic miniaturization is not part of this replay; its actual hide/show
check must not be reported as proof of physical minimize behavior.
