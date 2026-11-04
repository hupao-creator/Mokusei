# Reading entrance choreography

## Contract

Agent detail, Report and Git entry share a primary reading entrance. The retained
tag chrome withdraws upward and fades while Moku takes its reading seat; both use
`NativeReadingPageTiming.openingAnimation` (420ms, cubic 0.76/0/0.24/1), matching
the emphasized panel opening. The existing identity-target preparation may precede
compositor travel; secondary work never estimates its completion with a 420ms timer.
Only the collapsed Moku position participates in this first stage. Its input
expansion belongs to stage three, after a separate main-document line reveal.
Tag layout/canvas clearance and Moku's
bottom-anchored native editor stay intact.

The reading Dock lowers its bottom edge by up to 16 logical points, bounded by a
12-point bottom margin (normally 12–20 points). Width, top clearance, expanded
height fitting, reasoning-ink fitting and interaction regions still derive from
the same fitted surface. Landing and Settings keep their own seating. Report/Git
use the same lower seat without forcing open their Moku composer.

## Three-stage admission

The owning `NativeReadingPageStack` supplies `nativeReadingEntranceReady` to its
front only after actual primary completion. Panel entry uses the generation-fenced
Core Animation delegate; non-panel entry uses its existing progress driver.
When Agent identity ink is present, the gate also waits for its existing
measured-anchor handoff. Panel travel alone can finish before that handoff;
opening a Sidecard then would move the destination beneath the retained ink.
Reduce Motion and entries without identity ink do not acquire this extra wait.
Resize, recovery and Reduce Motion settle through the same stack. Accepted Close
and return preparation keep this gate shut.
Nested reading stacks combine their own readiness with their parent's gate;
history entry cannot start ink while the outer panel/identity handoff is moving.

An Agent workspace initially publishes a folded Sidecard layout even if the
Conversation plugin has already requested its active execution. Stage two belongs
only to main: text/row registration cannot schedule reveal until
`nativeReadingEntranceReady` admits the turn. Actual TextKit line fragments and
non-text rows keep their existing direction and ease-out opacity curve. Agent
thread entrance runs at 1.1 times its original speed: fades use `280ms / 1.1`
and the interval is `min(45ms, 600ms / max(1, lineCount - 1)) / 1.1`.
The completed turn’s timestamp/usage footer joins this same native mask ordering
as the last row, starting one beat after the preceding line with the same fade.
It no longer waits for every body fade to end before starting a separate
SwiftUI animation. Markdown/layout readiness waits and other surface motion
retain their original timing.

The last opacity animation actually installed reports its real end through Core
Animation's delegate, including the footer row for completed turns. Running
turns have no footer.
No line-count timer admits stage three. Streaming/resize changes that invalidate
sampled masks settle the entrance to fully drawn content, as before; later
updates do not restart it. Unmount restores drawing and cancels ownership, so
late opacity completion cannot publish success for that turn.
If a native line animation is interrupted while its turn remains mounted, the
turn restores full drawing and settles; a removed animation cannot strand input.

`NativeReadingContentRevealStatusKey` combines readable-content readiness with
any still-revealing turns. `nativeReadingContentReady()` reports loaded/error
content, while `ThreadDetailTurn` keeps a pending contribution through Markdown
parsing and the final native line/row opacity completion. Empty documents and
unavailable links report their readable empty/error state. Loading placeholders do not.
Mounted Agent loading placeholders keep an unfinished contribution from their
first frame, including the visual grace period. A loaded sibling error cannot
admit auxiliary input while another main document is still loading.
The identity-only preparation reader and retained current document behind a
history page clear their contributions. Only main is collected; Sidecards cannot
admit the window's composer.

For stage three, `NativeReadingEntranceStage` waits for main reveal to settle,
the folded layout's transaction commit and the primary gate, then asks the
current selection to reveal. If the selected execution Sidecard owns the Dock,
the compact Moku first travels horizontally into its destination column using a
620ms-response spring with 0.78 damping, allowing gentle braking and a small
rebound. Its actual removed completion asks the window to admit this exact route
visit, then the Agent composer expands for 420ms. Destination revisions and local
travel identity reject stale completions; a native publication already replacing
the target takes precedence. The shell's sizing, Sidecard's 380ms fold/layout
animation and return keep their existing curves.
An empty registry, folded selection or ineligible execution still commits and
opens input without a horizontal travel wait. Later card choices keep an already
admitted editor open. There is no elapsed-time opening task.
Plugin sessions, execution exclusion and user selection revisions keep their
existing ownership; hiding presentation does not transfer an execution to main.
The stage latches once per mounted workspace, so primary Close does not fold an
already-expanded card underneath the returning panel.

The window resets admission on route replacement, binds the new draft immediately
and configures a separate scene-level input gate. While the gate is closed,
`setInputOpen(true)` is rejected regardless of its source (initial context,
interaction restoration, input toggle, follow-up suggestion or failed send).
Previous editor ink retires immediately, and composer generation invalidates old
focus tasks. Pinning still prevents ordinary detail input dismissal after entry.
Application reading commits release the gate without automatically opening their
Moku composer. Covering history/interventions keep their surface priority: an
admitted visit may restore input only through the existing eligible route.

The existing 180ms focus delay starts with input expansion after horizontal travel
when needed, never with primary travel. Delivery checks the current draft,
composer generation, route visibility and covering state. Reduce Motion skips this delay, including when
enabled while a focus request waits. Closing before admission, replacing the
route or releasing the window rejects a late admission; repeated settled entry
does not fold/reopen the input or restart the entrance stages.
The scene also reads the owning panel's live motion state: accepted Close/return
preparation disables input hit testing and focus without folding its retained
shell. A delayed focus or failed-send callback cannot activate input in a moving
reading panel.

The boundary invalidates queued completion on disable, detach and replacement.
Sidecard release cancels its transition task. Repeated plugin requests retain the
current selection and do not restart travel. Availability loss before admission
retires selection normally, so a completed/archived/disabled execution cannot be
resurrected at stage three. An empty registry or an ineligible first execution opens
no Sidecard. The existing execution-completion handoff remains separate and cannot
start before entrance admission. Reduce Motion removes travel and the 380ms
interaction delay while retaining layout/readiness and cancellation ownership.
It also skips line/footer fades but still waits for data and Markdown parsing,
so a loading document cannot be mistaken for completed content.

## Scope and verification limits

The November 4 reveal adjustment was inspected against the supplied 18:43:01
recording: body ink is clear around 1.75s, while timestamp/usage begins appearing
around 1.95s. The separate completion-gated footer fade explains the pause;
the footer now shares the native row clock, with the whole reveal at 1.1x speed.
Validation for this adjustment is Swift syntax parsing, source/diff review and
local document-link checks only. No tests were added, and no build, regression,
replay or post-change visual acceptance was run. No push or PR is included;
the caller owns integration. Validation below belongs to earlier adjustments.

The Sidecard Dock motion adjustment was inspected against the reported recording:
around 3.7s, the compact Dock moves right while expanding. The adjustment now
separates horizontal arrival from initial input expansion. Sprint validation for
this adjustment is Swift syntax parsing, diff/static review and local document
link checks only. No tests were added or run, and no build, replay, live visual
acceptance or hosted CI certifies this revision. Main integration belongs to the
caller. Earlier validation below applies to the original choreography only.

An independently built native demo was approved before this production
implementation. Its files and launch fixes are outside this integration and its
approval does not certify this production path. Changes stay in shared reveal
completion/readiness and Host
auxiliary admission. No Runtime, Harness contract, Report HTML, placeholder-logo
alignment, input dismissal, source identity flight or Sidecard folding/promotion
implementation changes.

Sprint mode permits static review, product build and lint only. No tests are
created or executed, no test replay runs, and no production-build interactive
acceptance has been performed for this change. Rendered-frame smoothness, fast
user-driven reversal, actual focus/IME behavior and compact/zoomed window appearance remain
unverified dynamically. Integration is limited to local main; no hosted checks,
push, PR or release are part of this Sprint-mode task.

The source implementation reported a final Debug product build, lint, diff and
documentation-link checks. Local main integration must check its actual combined
source with a fresh product build, lint, diff and documentation-link review.
Neither those checks nor the demo observation certify production visual behavior.
No tests or test replays are created or run. A future remote integration has mixed
Swift/documentation scope and requires normal native CI rather than
documentation-only coverage.
