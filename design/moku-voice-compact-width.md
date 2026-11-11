# Moku voice capsule width

## Investigation and behavior

Before `51d736c609d420004f24d0db16e41d6abcfcac09` (Rebrand Moku as a
Harness-colored glass orb), the mounted voice transcript regression required
168×44pt both before the first transcript and after the transcript disappeared.
That commit added `voiceControlVisible` to the Dock's row expansion condition
and changed those assertions to the full message width and 58pt height.
`ce1ea8c` restored the eye capsule and its original idle dimensions, but retained
the voice-only expansion condition and assertions.

The restored contract is:

- Voice controls alone use the ordinary 168×44pt capsule, fitted to the available
  viewport. Landing retains its existing resident scale. A retained multiline
  composer must not enlarge this row.
- A visible live transcript expands to `min(560, viewport width − 48)` points in
  the ordinary Overview Dock. Its height grows from 58pt to eight lines before
  scrolling, as established by `e07277afc12185d0b08a134254f750594225d7eb`.
- Removing a transcript returns to the compact row unless another visible
  surface needs expansion. A deferred Talk notification keeps its ordinary
  message layout; dispatch keeps its 400pt maximum width. Note and Settings
  retain their own expansion.
- Transcript visibility and the existing presentation priority decide the
  layout. No media lifecycle, transcript identity or composer restoration policy
  changes are needed.

## Implementation and verification boundary

Remove the voice-control-only row expansion condition in the production Dock.
The existing mounted `NativeMokuVoiceTranscriptLayoutTests` suite is the test
seam: restore its two compact assertions without adding methods or changing the
fixture. Existing cases cover 320/900pt viewports, light/dark environments, retained
multiline drafts, partial and long transcripts, scrolling and deferred
Talk/dispatch across history/window visibility changes.

Before the sprint/headless instruction, the original production code failed the
restored width expectations: the empty voice row was 272×58pt at 320pt and
560×58pt at 900pt, both at entrance and after transcript removal. With the
production fix, those width expectations and the existing transcript assertions
passed, but the whole suite failed extra control probes under investigation.
The control view is mounted both in the hidden retained composer and the Dock;
a shared measurement/probe incorrectly observed or reparented the hidden copy.
Those exploratory additions were removed from the final patch. These runs do
not certify a successful final graphical suite.

The isolated voice cloud replay stopped with `Full own window unavailable;
refusing thumbnail evidence` before reaching entrance assertions. Its failed
report is retained under `.scratch/voice-width/cloud-evidence/failure`; it is
not passing graphical evidence. The sprint instruction then limited subsequent
verification to headless execution of related existing cases. No application
restart, live microphone/WebRTC check, full regression run or hosted CI is part
of that verification. Hosted CI and integration into main belong to the caller
of this detached worktree task.

Final related headless validation passed with zero skips: three existing
`NativeMokuTalkTests` methods, including both parameter cases of the mounted
windowless long-message layout. The other methods check voice composer
restoration and measured action-seat fitting. The command also built the
current application/test targets successfully:

```sh
MOKUSEI_TEST_HEADLESS=1 xcrun swift test --package-path app/macos \
  --filter 'NativeMokuTalkTests/(voiceComposerRestoresOnlyAnInputThatWasAlreadyOpen|longMessagesFitTheCapsuleAndReserveStopWithoutOpeningAWindow|noteActionsFitMeasuredControlsAtBoundaries)'
```

The test process reported 3 tests in 1 suite passed in 9.082 seconds; its raw
log is `.scratch/voice-width/headless-related.log`. This confirms the selected
headless boundaries, not rendered animation, focus or live voice hardware.
