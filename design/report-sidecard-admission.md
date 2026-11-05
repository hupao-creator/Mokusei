# Report reading admission and referenced executions

## Problem and scope

The supplied 2026-11-05 13:44:13 recording shows the related-execution card
expanding during Report entry, including repeated visits. The old admission
only waited for primary panel travel and a folded layout commit; HTML query
completion and WebKit loading were independent. A second, outer Browser
selection could expand alongside the Report's related-execution selection.
The supplied related-execution screenshot also shows a missing title/emoji and
an unwanted execution-process summary.

## Behavior

- Report first commits a full-width, folded layout. Its current HTML query must
  return the requested content revision, and the owning WebKit main-frame
  navigation must finish. Primary travel and the folded layout commit must also
  finish. Only then does a cancellable 200ms admission interval begin.
- This interval is a minimum after readiness, including with Reduced Motion;
  it is not a timeout measured from the initial click. The main actor can deliver
  its completion later under load. WebKit `didFinish` is the document boundary;
  indefinitely running scripts, subsequent DOM changes, and future lazy assets
  are not a second application loading contract.
- Related references, a selected referenced execution, and the linked Browser
  share one active Report sidecard selection. Before admission, the latest
  request is pending. A pending launcher's second click cancels it. After
  admission, toggles and replacements use the existing motion immediately.
- Closing clears the pending choice. The timer admits the latest choice rather
  than capturing an earlier card, so replacement or closure cannot revive the
  default related list. Loading a new revision/navigation revokes admission;
  failures remain folded until a successful retry. Covering or leaving the
  route cancels pending presentation. A new route visit owns fresh state.
- Document/view and navigation identities reject stale WebKit completions.
  Selection identities reject old auxiliary Back and Browser close callbacks;
  a newer URL request also retires the old Browser callback. Folded documents
  retain their readers but cannot receive input or accessibility focus.
- Referenced executions retain the existing host-owned `.execution` data scope.
  Their heading uses the exact execution's stored title (timestamp fallback)
  and the Harness's existing thread emoji. They hide execution work and its
  summary while preserving the final reply, independent errors, interactions,
  author, status, timestamps and usage. The live Agent execution Sidecard keeps
  its existing heading/work policy.
- The main Report reader, 14pt HTML viewport clip and 22pt shell/border use one
  interpolated size when the related sidecard changes. WebKit receives the
  presented viewport size throughout the existing 380ms fold, including height
  changes in stacked layouts. The retained HTML document reflows during travel
  rather than adopting the final width before the shell starts moving.

## Ownership and validation

The isolated HTML surface publishes typed, revision- and view-scoped readiness
through a SwiftUI preference. Report consumes that observation and its native
layout gate. The outer Report workspace and plugin share one presentation owner
through the environment; standalone Report fixtures use the same owner's local
fallback. No Runtime schema, Harness data decoder or Agent sidecard selection
contract changes.

Sprint mode explicitly excludes new tests and regression execution. Validation
is source/lifecycle review, application compilation and static/diff/link checks;
no automated interaction, animation capture, CI, push or PR is triggered for this
change. Recording/screenshot inspection diagnoses the original behavior and
does not certify the modified application's rendered behavior. The managed
detached worktree delivers a commit to its caller for local main integration.

The application product build, `make lint` (architecture/static registration,
formatting and `go vet`), diff review and documentation link checks passed.
Initial sandbox-only attempts could not start SwiftPM's nested sandbox or write
the Go compiler cache; rerunning these same build/static commands with the
required environment access succeeded. Effective remote main rules require
strict `Complete coverage` and a pull request; those remote gates were only
inspected, not executed or bypassed for this local Sprint delivery.

## Report shell clipping follow-up

This records the earlier fixed-document implementation; the continuous viewport
follow-up below supersedes its destination-size transaction.

The supplied 2026-11-05 13:59:00 recording shows the loaded HTML background
escaping the main panel's right border at approximately 1.5s and 3.2s while
the related card folds. The document immediately takes its larger destination
width, while the main shell still interpolates from its narrower width. The
inner HTML clip also takes the destination size, so it cannot contain pixels
within that intermediate shell. Report was missing the outer animated-frame
clip already used by the Agent main panel.

The main Report shell now applies a 22pt rounded clip after the animated outer
frame and background, before the border. That clip shares the border's current
presentation bounds while the document keeps its existing destination-size
transaction. This also contains vertical growth in stacked layouts. The
retained WebKit view, 8pt viewport inset, inner 14pt clip, fold timing,
Reduced Motion handling and sidecard admission/selection keep their ownership.

Sprint verification for this follow-up is inspection of the supplied recording,
source/layout review, product compilation, static lint and diff/link checks.
No new tests, regression runs, automated captures, CI or push are performed.
The repaired application's intermediate frames have not been captured or
visually accepted in a running application; the source recording establishes
the original defect, not post-fix visual acceptance.

## Referenced execution expansion follow-up (2026-11-05 19:01:54)

The continuous viewport follow-up below supersedes the fixed document size
described here; the left anchor and reader transaction isolation remain.

The supplied 6.38s recording starts with Report references already expanded.
At approximately 0.30–0.37s the second item is selected; this is the list-to-reader
30%-to-50% width change, not the initial launcher fold. Dense source-frame
inspection shows the HTML heading shifting sideways immediately, followed by
reader text admission and further horizontal movement around 0.40–0.60s.
AVFoundation decoding needed access to the system decoder outside the build
sandbox; exact-time image extraction was used, rather than keyframe sampling.
The recording does not establish a main-thread stall or its CPU duration.

Two animation boundaries were leaking geometry into this transition. Report
copied Agent's center-compensating offsets around its fixed-size document: the
inner offset adopted the new half-width immediately, while the outer offset
animated from its previous value. That displaced HTML at the start of the width
change. Report now anchors both document and shell at top-leading and animates
only the shell's bounds. Responsive HTML still reflows once to its destination
width; it is not scaled or laid out at every intermediate shell width.

The selection animation also covered the newly inserted execution subtree, and
the ready reader started its 200ms fade with a subtree-wide `withAnimation`.
Selection transactions are now cleared below the related-card shell, and the
ready-reader fade is scoped to opacity with its transaction cleared before the
rendered content. This keeps asynchronous native text admission out of that fade's
geometry animation. Later reader-owned transactions, resource subscriptions,
selection/Back, fold duration, input placement and Reduce Motion retain their
existing ownership. The fade still runs once per mounted related reader.

Sprint scope: no tests, replays, application launch or post-fix frame capture.
Source recording inspection diagnoses the original behavior; source review and
compilation cannot certify the repaired application's frame pacing. Live visual
acceptance of list-to-execution, execution-to-list, folded reopen and stacked
layout remains unperformed. The managed detached worktree supplies a commit for
caller-owned integration and does not change local main or another worktree.

Validation completed: `swift build --package-path app/macos --product Mokusei`
(with the SwiftPM sandbox disabled and an isolated module cache) succeeded;
`make lint` passed architecture/static registration/no-Node checks, formatting
and `go vet`; `git diff --check` and the changed documentation link passed.
The effective remote main ruleset still requires a PR and strict `Complete
coverage`; current remote state was inspected, but no hosted run was requested
and no historical run is claimed as validation of this change.

## Continuous Report viewport follow-up (2026-11-05 19:13:03)

This recording shows Overview-to-Report entry, rather than selecting an execution
in the related list. Exact source-time frames around 3.40–3.58s isolate the
remaining discontinuity. The full-width HTML is visible through approximately
3.48s. At 3.50s its viewport has already narrowed, clipping the still-wide page;
by 3.52s WebKit's responsive layout has moved the centered content left. The outer
shell and related card are still travelling. These are observed geometry/paint
discontinuities, not evidence of a measured main-thread or CPU stall.

The fixed destination-size transaction deliberately sent the final viewport to
WebKit ahead of the animated outer shell. The HTML's own centered layout could
therefore jump even with the native document anchored left. Report now uses a
private animatable frame modifier to interpolate one width/height for the actual
HTML viewport, its 14pt clip, and the 22pt shell/border. The modifier clears the
implicit transaction inside each already-interpolated frame, so there is no
second frame animation or independently moving inner clip. The HTML view and
WebKit generation retain their identity; no page load, snapshot, visibility gate,
timer or additional selection state is introduced.

This intentionally trades the old single WebKit reflow for continuous viewport
layout during related-sidecard travel. It removes the deterministic endpoint
size jump; it does not prove WebKit paint keeps up with every animation frame.
Authored CSS breakpoints can still change layout discretely. The 380ms curve,
readiness/200ms admission gate, HTML fade, related-reader policy and cancellation
ownership stay unchanged. Size interpolation handles width and stacked height,
and selection reversal retargets the same modifier. Ordinary resize follows its
current geometry proposal; Reduce Motion supplies no fold animation. Agent and
Browser sidecard native content retain their separate fixed-size policy.

Sprint scope remains source recording inspection, source/lifecycle review,
application build and static checks. No tests, replay, application launch or
post-fix frame capture is performed, so smoothness and WebKit's additional layout
cost still require live acceptance. Current main protection and remote run/PR
state were inspected before validation; no hosted check is triggered or bypassed.

Validation completed for this follow-up: the Mokusei product build succeeded
(12.78s); `make lint` passed architecture/static registration/no-Node checks,
formatting and `go vet`; diff and changed documentation links passed review.
The final source was reviewed after Astra high's implementation. These checks
establish compilation/static correctness, not post-fix animation frame pacing.
