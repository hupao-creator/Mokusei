# Report Close with an expanded Sidecard

## Evidence and scope

The supplied recordings `录屏2026-11-05 19.13.03.mov` and
`录屏2026-11-05 19.48.19.mov` show the production Report leaving for Overview
with associated executions open. The main page expands toward full width and
recenters its HTML before returning to its source card. These are observations
of the original application, not visual confirmation of this repair.

The implementation is based on local main `742123e` (Keep one execution column
during Report send transitions), including `f40d666` (Resize Report HTML with
its travelling shell). The fix was prepared in a separate worktree.

## Cause and retained-layout policy

`NativeReadingPageStack.requestClose` first prepares the retained parent and
sets motion active. This removes `nativeReadingEntranceReady` before native
return starts. `NativeReportDetail` forwards readiness loss to the shared
Sidecard model; `invalidateAdmission` clears active selection, and the Report
layout becomes full width. Suppression also clears selection through this
boundary. Simply changing the return curve cannot fix this preceding relayout.

A Report-only return environment now begins with parent preparation. The model
cancels pending admission but preserves active selection, selected execution and
layout throughout that accepted Close. Reference refresh cannot discard the
selected execution during return, and the composer input target is revoked.
Pointer, accessibility, launcher and auxiliary Back actions are excluded.
The existing completed-route unmount calls `cancel()` to release selection and
admission. Cancelling the return without navigation restores ordinary policy;
scene deactivation/resize/Reduce Motion retain the stack's accepted-close behavior.

The already-sized main shell uses a GeometryEffect for translation and independent
width/height scaling directly to the refreshed source card. It stays opaque until
the final progress handoff. The Sidecard keeps its seat and fades across the same
420ms existing Report return curve `(0.42, 0, 0.58, 1)`. The full-workspace native
carrier does not also move or crop these surfaces; a same-duration native animation
retains generation-fenced completion without a new async timer. There is no bitmap
snapshot, extra reader tree or intermediate WebKit viewport width proposal.

The HTML document-frame memo samples the existing interpolated width/height below
its animation boundary, retaining that size during return. The fold presentation
memo likewise retains its presented aperture, offset and opacity if Close occurs
while a Sidecard is travelling. These caches are view-local render memos, not
observable state; they resume sampling if return is cancelled. Their purpose is
to avoid snapping an interrupted width animation to its final layout before return.

## Compatibility and limits

Ordinary opening, sidecard toggling and list-to-execution resizing keep their
existing layout animation. In particular HTML still resizes with its travelling
shell outside return (`f40d666`). Return before primary content has mounted uses
the existing native opening-reversal path. Report continuation remains a separate
route-owned slide: its single-execution-column handoff (`742123e`) is unchanged.
The route slide container only releases its bounds clip during a Report return,
allowing the main card to reach an Overview source outside the open panel bounds;
continuation and normal reading retain the clip. Browser and stacked layouts use the
same local main origin; auxiliary surfaces do not inherit the main transform.

This implements the chosen parallel-return behavior in production sources.
Native glass, WebKit composition, intermediate frames, rapid reversal and target-device frame
time have **not** been visually accepted or profiled in this Sprint.

## Validation and delivery

No tests were added or run, no replays were run, and no remote PR/CI was used.
The first production build failed on the new opacity modifier's actor-isolated
Animatable conformance; its conformance was explicitly isolated to MainActor.
The corrected production `swift build --product Mokusei --disable-sandbox`
compiled and linked successfully. Architecture/static registration/no-Node source
checks and `git diff --check` passed in the source worktree.

Static review covers source/local coordinate conversion, retained widths,
interrupted layout sampling, related-list/detail and Browser paths, input gates,
selection cleanup, cancellation, and isolation from opening/continuation. This
is not a claim that actual production animation has been visually confirmed.
