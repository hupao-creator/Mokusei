# Sidecard fold performance repair

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
