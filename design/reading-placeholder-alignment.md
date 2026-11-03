# Reading placeholder alignment

## Recording observation

Source: `录屏2026-11-03 16.53.27.mov`, attachment
`170d3458-beda-4b74-afbc-03a7bc3dff60`, 12.758 seconds.
Reviewed extracted frames, including a 170ms sampling of 1.00–8.99 seconds.

The user opens the ordinary Agent Thread “修复执行过程隐藏时的消息回归”
from Overview twice in a light appearance. The first opening shows a centered
whole-panel loading label before the heading and long reply arrive. On the
second opening, the 7.12s frame shows “正在读取…” at the reading panel's left
edge, vertically near its middle. At 7.29s, the heading and a separate inline
placeholder occupy the centered reading column; by 7.46s the long reply is
visible. This is the reading panel, not the Overview card's preview text.

## Cause and change

Host loading already filled and centered its surface, but Codex used the same
leading-aligned `CodexContentStatus` both before initial state decoding and
inside scoped turn rows. Before the conversation/timeline exists, that status
receives the full panel width and has no reading-column parent to constrain it.

The shared `NativeReadingPlaceholder` now explicitly distinguishes surface and
inline placement. Host loading and Codex's initial decode use surface placement;
scoped rows and execution empty states use inline placement. Codex error/retry
UI remains a separate immediate branch. No loading, caching, decoder or resource
lifecycle implementation changes are included.

A 180ms presentation grace period suppresses brief labels. It reserves layout
while hiding text and accessibility, so appearing text does not move content.
SwiftUI task cancellation and a post-sleep cancellation guard prevent a departing
placeholder from revealing itself later; disappearance also resets visibility.
There is no minimum display time that could delay ready content or errors.

## Review and limits

Static review covered these layout/lifecycle paths:

- Short and long content: surface placeholders are removed when content arrives;
  inline placeholders have no expanding height or content-height prediction.
- Narrow windows: surface padding is bounded, width follows the viewport, and
  text can wrap; inline margins remain owned by the production timeline.
- Light/dark and contrast: semantic thread text colors follow the existing palette.
- Fast switching: delayed tasks belong to mounted placeholders, row IDs reset
  inline placeholder identity, and cancellation is checked before revealing text.
- Accessibility: hidden grace-period text is excluded; visible text remains
  readable without taking focus; no spinner, animation or pointer interception is
  added. Retained inactive readers preserve their parent accessibility policy.
- Errors: failure text and retry controls bypass the loading delay.

Only Swift syntax parsing and diff/whitespace/link review were performed.
No tests, test hooks, builds, CI or native replay were run, as requested for
sprint mode. The supplied recording shows the original issue only. The change
has not been visually exercised in a running app; narrow-window, theme,
VoiceOver, Reduce Motion and rapid-switch behavior still need manual acceptance.
The 180ms grace period is a presentation choice, not a measured performance gain.
