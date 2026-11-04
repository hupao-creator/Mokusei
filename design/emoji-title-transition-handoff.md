# Agent heading handoff

## Recording evidence

Reviewed the user-supplied `录屏2026-11-04 09.23.03.mov` (11.135s,
3248 × 2124 pixels) from attachment `d89a267e-39e6-488f-ac6b-d280c637660e`.
AVFoundation initially could not decode inside the filesystem sandbox; extraction
with access to macOS media services succeeded. Only the original recording was
decoded, without launching the app or replaying an interaction.

The first ordinary Agent card opens around 1.3s. At 1.7–1.8s the panel and
heading have stopped their main travel; at 1.9s the real reader's author/filter
row appears. Comparing the original-resolution frames at 1.8s and 1.9s, the dark
title glyph bounds move from y=519…593 to y=511…586 (about eight video pixels
upward), while their horizontal extent is essentially unchanged. The wrench
emoji's dark bounds change from y=369…454 to y=370…455: this pair shows a
one-pixel difference, not the title's upward displacement. These are recorded
pixel coordinates, not application points or measurements of layout anchors.

## Cause and repair

`NativeOverviewWorkspaceView` registers card identity anchors. The outer
`NativeReadingPageStack` admits a lightweight `NativeThreadOpeningContent`
through `ReadingPanelView`, then mounts the Harness reader after panel travel.
`NativeThreadIdentityFlight` bridges that interval until measured reader
anchors take over. Both the prepared and loaded headings use
`NativeThreadHeading` inside `ThreadConversation`.

The flight used a separate `CATextLayer` with an AppKit attributed font,
kerning and wrapping policy, whereas the real heading uses SwiftUI `Text`
with native font fallback, tracking and two-line tail truncation. Setting
the flight layer to the same anchor rectangle does not reproduce SwiftUI's
glyph origin. `scheduleHandoff` then removes that ink and reveals the real
heading immediately. The existing handoff-distance observation measures
rectangle origins, so it cannot detect this glyph-baseline discontinuity.

The flight now rasterizes shared `NativeThreadHeadingInk` leaves using
SwiftUI `ImageRenderer`, the measured destination's local size, the native
backing scale and the reader's environment. The final heading uses those same
leaves. Plain compositor image layers retain the existing position/scale
animation and completion ownership; no per-frame text rendering is added.
Fonts, emoji size, heading spacing, centered responsive column, reserved history
rail, sidecard resizing, deferred reader mounting and final layout stay with
their existing owners. No compensating vertical offset or second animation is
introduced. The change is confined to shared Agent heading presentation; it
does not modify detail Moku behavior.

## Validation scope

Sprint mode: no test cases were added, and no tests, replay, app launch or
post-fix animation recording were run. Local review checks the production call
sites and layout modifiers. The delivery reports the actual lint/build results;
compilation and static review do not certify rendered handoff pixels, long or
multiline titles, different emoji, dark mode, zoom, interrupted opening or
sidecard changes in the running application. These remain dynamic acceptance
boundaries.

`swift build --package-path app/macos --product Mokusei
--force-resolved-versions --disable-index-store -j 4` succeeded (81.54s).
The build reported the existing unused `dismissInputForEscape()` result in
`NativeMokuDock.swift:474`; that file was not changed. `make lint` passed
architecture/static registration, Go formatting and `go vet ./...`.
`git diff --check` and the added local documentation link passed review.

Remote rules were inspected read-only: `main` requires a PR and `Complete
coverage`. This work is explicitly local-only and does not push, open a PR,
trigger CI or merge. Existing remote runs do not validate this revision.
