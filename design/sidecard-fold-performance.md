# Sidecard fold performance repair

> 动效策略已更新：本文有关系统 Reduce Motion 的行为与验证描述仅记录历史。当前应用不再感知该偏好；见[移除清单与验证](remove-reduce-motion.md)。

## Evidence and diagnosis

The reported recording is `录屏2026-11-04 09.28.36.mov`, attachment
`aebe954b-d793-421a-933d-e8ddfce9bf16`. Its duration is 18.208 seconds and the
video track reports about 23.99 fps. Decoded timestamped frames from the original
recording show repeated Voice Sidecard toggles in roughly the first seven seconds:
the main reading column moves between wide and narrow panes, and the Voice card
can show an empty shell before its content appears. These are original-recording
observations, not captures of the repaired application. Variable sample times
and recording cadence cannot establish the application's display FPS.

Static review of `4a83a3f` (Merge sidecard launcher animation fix into local main)
and the current Host layout identifies an expensive animation boundary:

- Selection starts a 380 ms SwiftUI animation around the entire workspace. The
  main reader's animated frame proposes a different width/height at intermediate
  steps, propagating viewport changes into SwiftUI documents, TextKit layout and
  scroll geometry instead of just moving visible panel edges.
- Changing cards can change retained width too, animating the document frames
  of the selected and retained Sidecards.
- The former fold modifier interpolates progress and both complete rectangles;
  each tick re-enters a body that also assigns the document's layout frame.
  Only its presentation aperture, opacity and measurement marker need that work.
- The empty Voice shell has a separate explanation: the model includes
  `transitioning` in plugin suppression, and Voice applies zero opacity while
  suppressed. The existing 380 ms transition task releases this suppression.
  This delay alone does not prove missed animation frames.

This identifies concrete repeated-layout work in the production path. No
runtime profiler was run, so its share of total CPU time, dominant stack on the
reporter's machine and actual frame-time improvement remain unmeasured.

## Repair and preserved behavior

The main reader now adopts its destination size once per layout change. Its
negative half-width offset belongs to the unanimated content layout; the
matching positive half-width offset animates outside it. The reading column
therefore travels between pane centers without scaling text. A separate outer
frame animates the opaque shell and clip. The panel Close belongs to that shell,
keeping its fixed upper-left position instead of moving with the reading column.
Line breaks settle at the start of travel; they no longer continuously reflow.
During local-main integration, animation suppression was scoped to changes in
the destination size with `transaction(value:)`. Unrelated reader transactions,
including the summary reveal's completion-footer fade, are not globally cleared.

Ordinary Sidecard travel likewise assigns its destination document size once.
A separate animated shell frame preserves the background/border resize when
switching between different retained widths, independently of document layout.
A smaller presentation modifier interpolates the aperture and progress, updating
paint, pointer shape, final-stage fade and native aperture marker together.
Travel uses an outer rendering offset. This preserves the original launcher
anchors and fallback, rounded geometry, timing curve, last-real-button return,
retained sessions, selected/suppressed gates, divider and Reduced Motion policy.
No snapshot, new hosting tree, asynchronous callback or animation timer is added.

Execution promotion opts into its existing animated document resize, preserving
the SwiftUI travel-completion/readiness handoff. The recent execution-summary
reveal and reader-admission implementations are untouched. Plugin suppression
and Voice's delayed visibility remain as before; the repair does not keep WebKit
or other native documents active while their current policy suppresses them.

## Sprint validation limits

Static review includes endpoint offsets, ordinary toggles, retained-width
switches, stacked geometry, divider/Reduced Motion settling, presentation hit
geometry, fixed Close placement and preservation of the execution handoff path.
The macOS application builds with Swift 6.3.2 / macOS 26.5 SDK. `make lint`
(architecture/static registration/no-Node checks, Go formatting and `go vet`)
and `git diff --check` pass. Local build/lint logs and decoded original frames
are under `/tmp/mokusei-sidecard-evidence`; private recording frames are not
added to the repository.

Per the requested sprint scope, no test cases were added or run and no test
replays were run. The repaired application was **not launched for native dynamic
acceptance**, recorded or profiled. Build success does not certify intermediate
pixels, rapid reversal, focus, scroll position or target-device smoothness.

Read-only remote inspection found main rulesets requiring strict `Complete
coverage` and a PR. This delivery is a detached-worktree local commit only:
no push, PR, CI dispatch, main update or publication. Existing remote results
are for other revisions and do not validate this repair.

## Layout-placement follow-up (2026-11-17)

The new report supplies `录屏2026-11-17 17.23.57.mov`, attachment
`8143b6d7-dbed-4e1f-920a-95460e3bf53f`. The original was decoded and inspected
before changing code. It contains 435 frames over 8.051667 seconds at variable
sample intervals. Contact sheets and individual timestamps show two Agent
entries followed by right-hand Execution Sidecard unfolding, around 1.2 and
5.2 seconds. The samples at 1.116667→1.183333 and 5.083333→5.158333 have
66.7ms and 75ms gaps near content admission/opening. These are recording gaps,
not measured application frame times or proof of the dominant blocking stack.

The final-size repair above is present in baseline `a43931d2020bc3fc44d97d5187d9d017eae91c9a`,
but its `NativeSidecardFoldPresentation` still interpolates a complete view
modifier. Every tick reconstructs the mask, pointer aperture, opacity, native
frame-marker layout and travel around the retained document. Fixing the proposed
size prevents repeated measurement; it does not prevent repeated placement.

A temporary isolated AppKit probe wraps the **production** `NativeSidecardFold`
document in a counting SwiftUI `Layout`, with a ScrollView containing 100 fixed
paragraphs. It uses a 1180×620 viewport, a 435×620 destination, the real fold
curve and eight alternating open/close changes, 600ms apart. On the same Mac
and Debug toolchain, the baseline's document `placeSubviews` counts are
`48, 49, 47, 48, 47, 49, 47, 47`; the candidate's are
`2, 2, 2, 2, 2, 2, 2, 2`. Both measure the document once per change.
This directly demonstrates avoidable per-frame placement, independently of
reader loading. It does not establish repeated TextKit measurement, optical
FPS, GPU cost or the share of the user's hitch attributable to this work.

The Agent path now interpolates its mask and interaction Shape locally, with
SwiftUI's leaf frame/offset interpolation for the native marker and travel.
Only the existing `clamp(progress * 5)` opacity rule needs an animatable modifier;
it does not change layout. Mask, interaction shape, marker and offset still
receive the same endpoint geometry and selection animation. Duration, curve,
launcher seats, final document sizing, retained sessions, suppression,
accessibility and Reduced Motion gates remain owned by their existing paths.
Report and explicit fading returns keep their original presentation and
non-animatable aperture because the Report return memo must retain the last presented pose when closing mid-fold.

The current main implementation worktree was inspected read-only. Its pending
Moku horizontal-travel and traffic-light changes are separate; this repair
does not edit or incorporate them. Obsolete capsule tests are outside this scope.

Validation uses `xcrun swift build --package-path app/macos` and the existing
replay:

```sh
MOKUSEI_SWIFT_SKIP_BUILD=1 python3 tools/verification/reading-presentation/run.py \
  --thread-send-feedback-native
```

Its five native-owned methods cover
production launcher toggles, wide/stacked aperture travel from all three seats,
rapid reversal/switching, availability changes, resize and retained widths,
live divider reflow, execution handoff/content readiness, Reduced Motion and
resident-composer click/type focus. These pass on baseline and candidate.
A separate temporary native-click probe rejects a point outside the aperture
40ms into opening, with a successful button click after settling as its input
control.

The native captures are AppKit diagnostic renders, not WindowServer optical
frame-rate evidence. No new unit tests or test cleanup are included.

Private original frames, probe sources/raw counts, build/replay logs and a
candidate fixture stack sample are retained locally under
`/tmp/mokusei-sidebar-evidence`. The temporary probes are diagnostics, not a new
mandatory verification gate. `git diff --check` and local documentation-link
review supplement the affected build/replay. No full local `make check` or
hosted CI is claimed. The running user application was not restarted or profiled;
post-integration target-app pacing remains unmeasured.

Read-only remote inspection on this date finds an active PR requirement, a
disabled `main-pr-gates` ruleset and no classic main protection. This is an
independent detached commit for the coordinator: no main merge, push, publish
or CI dispatch. Other revisions' hosted results do not certify this commit.
