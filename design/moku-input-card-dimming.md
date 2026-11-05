# Moku input changes Overview card colors

## Recording evidence

Source: user attachment `519aaa57-ff79-46c0-8430-4c31ac2fd901`,
`录屏2026-11-05 14.15.21.mov` (5.215 seconds).
AVFoundation decoded the original recording into one-second PNG samples in
`/tmp/moku-frame-{0...5}.png`; these temporary files are not repository assets.

- At 0s the bottom Dock is compact. Report titles, excerpts and emoji are at
  their ordinary contrast. The wide upper-left Agent card has readable Git
  counts (`10`, `+180`, `−138`).
- At 1s the bottom Moku editor is expanded. The six Report cards in the lower
  two rows have faded titles, excerpts and badges. The upper-left Git summary
  also fades. The ordinary Agent title/preview and the completed upper-right
  Agent card do not show the same fading.
- At 2s the Dock is contracting and those controls are still faded. At 3s the
  compact Dock and ordinary card colors have returned, continuing through 5s.

The sampled card outlines, sizes and grid positions stay fixed. Animated clouds
and live execution text also change during the recording; they are independent
running content, not evidence of a card layout jump. One-second sampling does
not rule out shorter intermediate artifacts.

## Cause and change

`NativeMokuSceneState.interactionPaused` includes `inputOpen`. The workspace
passes that fact into `NativeOverviewCanvas`, which previously applied
`.disabled(interactionPaused)` to the complete canvas. This propagates SwiftUI's
disabled environment into plugin controls. `NativeReportCard` wraps its full
content in a plain Button; `ThreadCardGitExtension` similarly wraps the Git
summary. Native disabled Button styling explains both the faded regions and
their difference from gesture-based Agent content.

The canvas now gates hit testing and hides paused content from accessibility
instead of marking all descendant controls disabled. Plugin-owned disabled
states (for example a pending response) are still owned by those controls.
Camera pause and activation guards are unchanged. The native outside-click
monitor and its same-click automatic-framing suppression are unchanged, as are
composer focus, drafts, send, Escape, animation and persistent viewport sizing.
No Browser annotation, Report badge or related-thread panel code changes.

## Verification and limits

Sprint scope: no new tests, regression runs, replay, CI dispatch or push.
Static review traced the input-open fact through the canvas to the two Button
renderers and reviewed outside-click/camera ownership. Swift frontend parsing
and `git diff --check` are the local checks for this change; no application build
or post-fix visual/keyboard/VoiceOver interaction run is claimed. In particular,
hit-testing and accessibility gating are not a runtime proof of keyboard focus
behavior. The recording establishes the original symptom; the source path
establishes the cause, but a new recording is still needed for visual acceptance.

The read-only query for remote main protection failed because the GitHub API was
unreachable. No hosted check result is claimed. The detached commit is handed
to the coordinator for integration into local main.
