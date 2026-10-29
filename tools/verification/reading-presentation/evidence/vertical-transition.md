# Conversation history: planar vertical transitions

## Report and recording

The supplied `录屏2026-10-29 18.11.51.mov` is a 9.835-second screen recording,
2790 × 2034 pixels, nominal frame rate 39.211723 fps, with an identity display
transform. It shows the left-hand turn index in an ordinary conversation detail,
with two entries: the current reminder-design answer and its earlier execution.
It is not Overview card navigation or Settings.

AVFoundation's `AVURLAsset` and `AVAssetImageGenerator` decoded metadata and PNG
frames entirely from the command line. The sandboxed decoder initially returned
AVFoundation -11821 / OSStatus -12911; the same windowless command succeeded
outside that sandbox. No media player or application window was opened. Sampling
at requested half-second intervals retained actual decoded timestamps (the
recording is variable frame rate).

At approximately 0.91s, the current answer shifts right by roughly 16 recording
pixels (about 8 points at 2× backing scale) before the vertical change. Around 1.48s the earlier execution appears as
a rounded sheet, with the current answer shaded beneath it. The reverse changes
around 3.0s and 6.0s show the same depth/overlap treatment. Both settled pages
have the same horizontal reading-column origin.

## Production causes and change

`ThreadConversation` already routes TOC history through the vertical
`NativeReadingPageStack`. The stack previously disabled the retained current
page as soon as history opened. A windowless native SwiftUI diagnostic confirms
that disabling a `ScrollView` switches `NSScrollView.hasVerticalScroller` from
true to false, and enabling it restores true. Removing a reserved scroller gutter
recenters the column, explaining the recording's initial lateral movement.

The stack also moved the outgoing page by only one quarter of the viewport while
the incoming page moved a full viewport, including history-to-history replacement.
Dimming, rounded clipping and a page shadow reinforced the covering-sheet effect.

Vertical opening, replacement and return now use equal full-height travel, with
shared timing and a common adjoining edge. Vertical pages have no dimming, blur,
rounded corners or page shadow. The current page remains enabled during visible
travel and the existing two-frame return preparation, preserving its scroller
and horizontal layout. Its existing disabled input state applies once it is
fully offscreen. Pointer and accessibility gates remain active throughout the
history visit. Horizontal navigation retains its existing presentation.

TOC selection/order, resource lifetimes, cancellation generations, focus callbacks,
scroll restoration and Reduce Motion admission/settlement are unchanged.

## Headless verification

Run from the repository root:

```sh
MOKUSEI_TEST_HEADLESS=1 swift test --package-path app/macos \
  --scratch-path .build/vertical-transition \
  --filter 'NativeReadingPagePresentationTests|NativeThreadHistorySidebarTests|NativeMokuExecutionLinkRoutingTests|NativeReadingPageHeadlessTests'
```

The two new windowless integration methods mount the production page stack and
native scroll view in an `NSHostingView`, asserting no `NSWindow` exists. Narrow
and wide cases inspect the real retained scroller, enabled environment, view
identity and stable horizontal metrics during preparation;
they also cover the offscreen input gate, external teardown, cancellation fencing
and disabled presentation's immediate close. When the system already requests
Reduce Motion, they exercise its immediate return without changing preferences.

The existing graphical vertical replay now also measures the outgoing page:
opening and both history replacement directions must meet edge to edge, with
neither overlap nor gaps. Its existing pixel coverage and cancellation assertions
remain. These display-dependent methods are compiled but explicitly skipped in
this local headless run, together with the sidebar's actual focus/input cases.

Without a window, SwiftUI does not deliver normal animation-removal completion
or trustworthy intermediate composited frames. The headless cases therefore do
not certify smoothness, rendered edge pixels, final animated restoration, actual
keyboard focus, or pointer handoff. The system Reduce Motion preference was not
changed; runtime preference toggling remains unverified here. Use the existing
reading-presentation and thread-sidebar graphical replays on a disposable runner
for those boundaries. Local graphical launchers were not invoked.

The checkout starts at `bdf1f96`. Before verification, GitHub reported no open
PRs, no classic main branch protection, and an active `main-pr-gates` ruleset
requiring PRs/resolved threads plus deletion/force-push protection, with no
required status checks. Other commits had pending/in-progress CI; none was
cancelled or rerun. Baseline run 40850020010 failed in existing missing-result
execution-link assertions, tag-glass capture geometry and isolated-input replays,
plus coverage collection. Its results do not certify this change. This task does
not push, dispatch CI or merge, per the requested independent-review workflow.

Final local results: the focused Swift command exited 0; four test methods
executed successfully (including 12 route and three resource-scope parameter
cases), and 11 graphical methods explicitly skipped. All Swift application and
test targets compiled. `make lint` exited 0 (architecture/static registration,
no-Node boundary, Go formatting and `go vet`). Diff whitespace and the modified
README files' local links passed review. The workflow classifier treats the
Swift source/test changes as full CI scope, not documentation-only.

As a negative control, temporarily compiling the baseline stack against the new
headless regression exited 1 with six assertions across narrow/wide cases:
missing scroller/disabled environment on opening and return preparation. The
fixed source was restored in `finally` before the final successful run. Early
verification attempts also encountered SwiftPM sandbox/cache restrictions and
an unsupported attempt to set SwiftUI's read-only Reduce Motion environment;
the final tests use the actual system preference without mutating it. No product
failure was hidden by retrying an unchanged check.

Local logs and decoded frames are retained in `.scratch/vertical-transition/`.
No full `make check`, signed bundle replay or hosted CI is claimed.
