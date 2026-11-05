# Animation independence, 2026-11-05

The supplied temporary audits were recommendations. Current sources confirm that
Overview's asynchronous Metal encoder received frames only from a main-run-loop
display link, while Codex's production status ring used a TimelineView.

## Implementation

Overview keeps geometry, SwiftUI color resolution, visibility input and initial
reveal on main. It sends a Sendable snapshot to its serial Metal queue. A
screen-rate-capped DispatchSourceTimer samples the existing seeded field and
400ms intensity curve independently of main; it is not a vsync guarantee.
One in-flight GPU frame prevents a backlog. Drawable acquisition stays off main.
Generation checks reject retired work; queue-owned revisions prevent an older
static completion from cancelling a replacement driver. Closures do not retain
the timer or its owner. No view/environment/model is read from the render queue.

Static fields retry missing drawables until success, then stop. Fade-out submits
a zero-energy terminal frame before stopping, even while main is blocked.
Hidden/occluded/detached views retire work and preserve the last image. Resume
uses the original epoch; disabling motion preserves frozen-time behavior.
The shared SwiftUI cloud remains the capability fallback.

Codex's native quarter-ring keeps the diameter, stroke, colors and 800ms linear
cycle. Core Animation owns rotation after submission. Scene background, Reduce
Motion, hiding, occlusion and detachment stop it; resume rejoins wall-clock phase.
It owns no input or accessibility children. New state, layout, visibility events
and first-frame admission still require main.

## Verification

The existing native-decoration WindowServer fixture now includes the production
spinner and a bounded 200ms main hold. An independent capture queue admits only
complete frames presented inside the hold after a 30ms exclusion margin. At least
three frames and changing cloud/ring pixels in both halves are required, with a
quiet static control. Original 3.9s cloud/scan and camera-identity assertions
remain intact. Spinner hide/resume must remove/restore its animation. The existing
native capture CI owner executes these assertions too.

Evidence: `.scratch/reading-presentation/NativeOverviewTagGlassTests/`, including
`native-decoration/main-hold` PNGs, measurements and source/binary provenance.
Local build/replay logs are `/private/tmp/animation-*`. The mathematical cloud
replay checks continuity, deterministic sampling and hidden intervals; Metal tests
check shader output. Neither substitutes for the WindowServer hold evidence.

This is Debug component evidence, not Release CPU, power, physical-display FPS
or GPU-time measurement. Thread Sanitizer, multi-display/long-duration stress and
exhaustive fade-reversal/occlusion/Reduce Motion combinations were not executed.
Queue ownership and stale completion paths were reviewed; that is not a
race-detector result. Timer pacing/energy still needs the existing Release
foreground performance workflow.

Local results on the final implementation:

- `swift build --package-path app/macos`: passed (Debug application).
- `swift test --package-path app/macos --filter NativeCloudMetalTests`: all five
  tests passed, including parameterized appearance/zero-intensity cases.
- `MOKUSEI_SWIFT_SKIP_BUILD=1 python3 tools/verification/reading-presentation/run.py
  --tag-glass-captures`: all seven cases passed in 60.545s after the foreground-state retry.
- Production cloud mathematical replay: passed with warnings-as-errors.
- Final main-hold cloud mean RGB deltas: 0.203 and 0.164; spinner: 4.018 and 3.329;
  static control: zero. The two sampled intervals span about 139ms inside the hold.
- Reviewed the retained composed frame for cloud clipping and ring appearance;
  this is not a pixel-golden comparison against the previous spinner.

Initial attempts failed because nested SwiftPM sandboxing and network access
were unavailable in the restricted shell. Authorized build/network execution
resolved those environment failures. Neither is reported as a passing attempt.
Earlier successful capture runs preceded the final queued-event revision guard
and are not substituted for final-source validation. The subsequent run exited
1 after 62.835s: the cloud fixture lost foreground/key-window state at its final
visibility check. Failed logs and full evidence were preserved at
`/private/tmp/animation-foreground-failure.log` and
`/private/tmp/animation-foreground-failure-evidence`. This is an invalid foreground
observation, not a waived assertion or proof of a false alarm. The fixed launcher
has no failed-method-only switch, so its seven cases were retried together with
unchanged assertions. Hosted Complete coverage was not run for this commit.

## Retained paths

Overview camera already uses pure CustomAnimation. Report's HTML navigation
portal and Timer mount only under `ready && !panel`. Neither was rewritten.
Report responsive viewport resizing requires native layout; replacing it with
snapshots or fixed-width masks changes the visual contract. Overview structural
layout, reading/sidecard geometry and Moku painting also couple animation to
layout, input, phase transitions or AppKit drawing. They need separate designs
and intermediate-frame validation. Existing compositor panel travel and scan
remain unchanged; no reading-text migration files were edited.

Remote rulesets require a PR and strict `Complete coverage`. This detached
worktree returns a commit to its caller without updating shared refs or claiming
hosted CI passed for that commit.
