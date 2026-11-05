# Report Close with an expanded Sidecard

## Current implementation

Close retains the Report's current split selection and presented main size from
parent preparation through route completion. The main card's real WebKit reader
lives inside a native carrier. Core Animation moves/scales that carrier directly
to the refreshed Overview source card while keeping the reader's bounds fixed.
The related-execution or linked-Browser carrier fades in place in parallel. Both
use one monotonic start time, the stack's duration (normally 420ms) and the existing
return curve `(0.42, 0, 0.58, 1)`. Main opacity hands off during the final 14%.

`NativeReportSidecardPresentation.updateLayout` preserves active/pending selection
for an accepted return and cancels admission work. Reference refresh and auxiliary
Back cannot discard the selected execution mid-return; the composer target is
revoked. Completed route unmount calls `cancel()`. Cancelling without navigation
restores normal readiness and native carrier identity. Resize/inactive scene/
Reduce Motion keep the stack's accepted-close settling policy.

The main document-frame memo retains the last interpolated size if Close interrupts
width travel. Report Sidecards opt into the native return host inside the shared
fold, before aperture/offset presentation; a render memo retains the current fold
pose. Other Sidecards do not acquire this host. Outside return, the same retained
readers receive their normal content and viewport updates. There are no cloned
readers or bitmap captures in the production animation.

The enclosing native panel stays stationary during this Report return and owns
its generation-fenced completion. The route-slide container releases its bounds
clip only for return, allowing an Overview destination outside the open panel.
Before content admission, the existing native opening-reversal path still applies.
HTML opening/list-detail width animation and the single-execution-column send
handoff remain separate from this return policy. The native host opts out of
intrinsic sizing: the surrounding production frame owns both dimensions.

## Failed revisions and observed diagnosis

The user's 19:13 and 19:48 recordings showed a main Report expanding to full width
before leaving. Return preparation removes `nativeReadingEntranceReady`;
`invalidateAdmission` cleared active selection and caused full-width relayout.
Suppression also uses that clearing boundary. Retaining selection addressed this
preceding relayout, but did not establish a working animated return.

The 20:20 recording showed the first return repair disappearing instead of moving.
The first implementation removed the outer carrier's motion and relied on an inner
SwiftUI GeometryEffect/opacity. Adding local value-scoped `.animation` in the next
revision did **not** fix the user's 20:29 failure. The earlier transaction-only
explanation was insufficient; build/static results were not visual acceptance.

On 2026-11-05 the complete production hosting chain was mounted in an isolated
window: `NativeReadingPageStack` → native panel host → `NativeExecutionRouteSlide`
→ `NativeReportDetail`/WebKit. Manual five-times-slow closing reproduced the failure:
the main disappeared while the sidecard was still present. The old independent
proposal did not cover this chain.

A diagnostic explicit-progress GeometryEffect made motion visible, but intermediate
WindowServer images showed WebKit rewrapping as its presented rectangle changed.
That diagnostic was discarded. The delivered implementation instead fixes the
reader's native bounds and animates a separate CALayer carrier. Captured frames
show the text and shell shrinking together, preserving line breaks and scroll
position while the Sidecard fades at its original location.

## Actual verification

The user explicitly requested self-verification after two failed deliveries.
No test cases or remote CI were added/run. Manual native UI operations and
WindowServer recordings were performed in the isolated production-component
window; no Runtime or user's profile was opened or modified.

Observed operations:

- Open the production Report card and wait for actual WebKit readiness and related
  list admission; close the 7:3 layout at 5× slow and normal 420ms speed.
- Reopen, select an execution to enter 5:5, scroll the real HTML document, and close
  at normal speed. The scrolled content shrinks without jumping to the top or
  rewrapping; the execution remains at its original seat while fading.
- Repeat the normal-speed scrolled-detail close on the final native-host build.
  The source card returns. The final window screenshot is 2640×1720 pixels,
  matching 1320×860pt; it did not resize to fit detail content.

The recordings use `SCRecordingOutput` at requested 60fps, capturing only this app's
own window, without audio or microphone. Viewing decoded intermediate frames
confirms motion, stable text layout and parallel fade; it is not an FPS benchmark.
The full recordings are retained beside the isolated apps in `/private/tmp`.
Short clips and a sampled frame are exported under
`.build/sidecard-close-demo/evidence/`:

- `slow-list.mp4`: 7:3 list return, 5× slow.
- `normal-list.mp4`: 7:3 list return, 420ms.
- `normal-detail.mp4`: final build, scrolled 5:5 detail return, 420ms.
- `normal-detail-middle.jpg`: final detail recording at 32.3 seconds, visibly
  between the open and source sizes, with the Sidecard still in place and fading.

The final detail recording's 32.1/32.2/32.3/32.4/32.6s frames show initial size,
progressive shrink, parallel fade and source-card handoff. The native driver was
also observed at the slower speed before the final sizing-probe clarification.
Fixture HTML and execution data are synthetic; production rendering, split layout,
return hosts and both outer native bridges are real. This does not certify live
Harness subscriptions, arbitrary authored HTML, Browser navigation or all
interruption cases. The installed application was not replaced during verification.

## Build and delivery

Production `swift build --product Mokusei --disable-sandbox`, architecture/static
registration/no-Node checks and `git diff --check` pass. Build/static logs are in
`.build/sidecard-close-demo/`. No full suite, scripted replay suite or remote PR/CI
was run. The manual fixture now offers normal/5× speed and own-window recording;
see `demos/report-thread/README.md` for the launch command.

The worktree includes local main `5e4b441`, preserving the intervening send-feedback
fixes. This managed session stays detached and cannot update main or another
worktree; the final production-fix commit is delivered for caller integration.
