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
three frames are required. The ring must change pixels in both halves; the cloud
must change above the same quiet static control over the eligible hold. Cloud
independence additionally requires a frame from the observed Metal layer whose
sampling, submission and actual drawable presentation all occur inside the hold,
after the exclusion margin. This rejects a prequeued image without imposing a
minimum cloud update cadence. Original 3.9s cloud/scan and camera-identity
assertions remain intact. Spinner hide/resume must remove/restore its animation.
The existing native capture CI owner executes these assertions too.

Only while a `NativePerformance` recording is active, the render queue creates a
`metal.presented` span immediately before sampling. Its frame ID and layer
context join the sample with `MTLDrawable`'s presented handler in that same
recording; the callback retains neither drawable nor renderer. Sampling and
submission use `CACurrentMediaTime`; actual presentation uses
[`MTLDrawable.presentedTime`](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime).
These are Mach host seconds:
[`CACurrentMediaTime`](https://developer.apple.com/documentation/quartzcore/cacurrentmediatime())
converts `mach_absolute_time`, and Metal's
[`present(at:)`](https://developer.apple.com/documentation/metal/mtldrawable/present(at:))
uses the same host timebase. Callback arrival and CPU-span duration cannot replace
the actual presentation timestamp. The fixture records only around the hold,
finishes on success or failure, and retains `main-hold-metal.jsonl` plus the exact
joined witness in `measurements.json`. This observation does not change pacing,
drawable buffering, generation admission or completion behavior.

The former cloud assertion required movement between three predetermined frames,
including both halves of the hold. CI 361 captured visible cloud changes during
its 213.796ms hold, but the selected middle and final frames contained the same
cloud image. The same capture stream shows repeated cloud images in passing runs
359 and 360 too. Those observations do not establish a renderer fault; the old
oracle added a phase-sensitive cadence constraint to the independence objective.
The replacement requires fresh sampled-and-presented work as well as visible
pixels. Historical captures have no frame spans and cannot certify this new
witness; its first successful execution still requires the hosted native run.

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

Historical local results on the original implementation and cloud half-interval oracle:

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
