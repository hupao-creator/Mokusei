# Reading entrance choreography

## Contract

Agent detail, Report and Git entry share a primary reading entrance. The retained
tag chrome withdraws upward and fades using
`NativeReadingPageTiming.openingAnimation` (420ms, cubic 0.76/0/0.24/1), matching
the emphasized panel opening. Moku's short downward seat shift instead uses the
native Dock travel host with a gentler 420ms ease-in/ease-out curve, independently
of main-actor reader preparation after submission. SwiftUI applies the destination
baseline discretely outside shell layout animation; the compositor compensates
from the presented position and reports completion for both axes. Resize,
dragging, inactive scenes and Reduce Motion settle through the same native owner.
The existing identity-target preparation may precede
compositor travel; secondary work never estimates its completion with a 420ms timer.
Only the collapsed Moku position participates in this first stage. Its input
expansion follows the main document's content readiness and the Harness identity
flip described below.
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
history travel keeps the active reader pending until its own arrival.

An Agent workspace initially publishes a folded Sidecard layout even if the
Conversation plugin has already requested its active execution. Markdown may
parse and mount during hidden panel preloading. After arrival the host draws
the complete parsed document, with the execution summary and any terminal
footer in their normal layout.

`NativeReadingContentStatusKey` combines readable-content readiness with pending
Markdown parsing, row loading and nested motion. Turns and
`nativeReadingContentReady()` identify loaded and readable error states. Empty
Markdown still completes parsing. Mounted Agent loading placeholders contribute
pending state throughout their visual grace period, so a loaded sibling error
cannot admit input early. The identity-only preparation reader and retained
current document behind a history page clear their contributions. Only main
contributes to the workspace's input and Sidecard admission.

`NativeReadingEntranceStage` waits for main readiness, the folded layout's
transaction commit and the primary gate, then asks the
current selection to reveal. If the selected execution Sidecard owns the Dock,
the compact Moku first travels horizontally into its destination column using a
620ms-response spring with 0.78 damping, allowing gentle braking and a small
rebound. Its actual removed completion asks the window to admit this exact route
visit. Once admitted, the compact Dock flips its eyes into the Harness logo for
420ms using the existing emphasized curve, then expands the Agent composer for
420ms. Destination revisions and local
travel identity reject stale completions; a native publication already replacing
the target takes precedence. The shell's sizing, Sidecard's 380ms fold/layout
animation and return keep their existing curves.
An empty registry, folded selection or ineligible execution still commits and
releases the identity stage without a horizontal travel wait. Later card choices keep an already
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

The identity seat retains its current mark until reading admission, keeping eyes
through initial downward travel and preserving an existing Harness logo during
an Agent continuation. The flip's actual removed completion releases a separate
scene input gate; no duration-based phase task is scheduled. A replacement
composer may reuse a flip to the same mark, but must await its completion rather
than infer readiness from its target value. A different mark or view teardown
invalidates the old completion; the composer generation independently rejects
late delivery. Reduce Motion, inactive scenes and hidden windows settle the mark
immediately without bypassing reading/content admission. The existing return and
composer-collapse paths remain independent.

The existing 180ms focus delay starts with input expansion after travel and the
identity flip when needed, never with primary travel. Delivery checks the current draft,
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
It still waits for data and Markdown parsing.

## Scope and verification limits

The same-day descent follow-up moves only the reading baseline into the existing
native Dock travel transform, retaining SwiftUI shell sizing and the sequential
identity/input gates. Headless Swift syntax parsing, the final Debug `Mokusei`
product build (25.39s) and diff review passed. No tests were added or run, and no
graphical replay or visual smoothness acceptance was performed. Return,
replacement, resize, Reduce Motion and both-axis hit protection were reviewed
statically. The local commit is handed to the coordinator without pushing.

The 2026-11-14 identity-order follow-up changes only the Dock mark's presentation
and composer admission. Headless validation passed Swift syntax parsing, the
Debug `Mokusei` product build, diff review and the new local documentation link.
The first build was blocked by nested sandbox/cache access; the final build used
`--disable-sandbox` and a temporary SwiftPM cache. An intervening build stopped
because review changed a source while it was compiling; a fresh build of the
final sources passed (30.07s). No tests were added or run, no graphical replay
or visual acceptance was performed, and no CI was triggered. Static review
covered return, rapid replacement, in-flight completion reuse, Reduce Motion
and teardown; it does not certify rendered frames or actual focus/IME behavior.
This detached commit is handed to the coordinator without pushing or merging.

The Sidecard Dock motion adjustment was inspected against the reported recording:
around 3.7s, the compact Dock moves right while expanding. The adjustment now
separates horizontal arrival from initial input expansion. Sprint validation for
this adjustment is Swift syntax parsing, diff/static review and local document
link checks only. No tests were added or run, and no build, replay, live visual
acceptance or hosted CI certifies this revision. Main integration belongs to the
caller. Earlier validation below applies to the original choreography only.

An independently built native demo was approved before this production
implementation. Its files and launch fixes are outside this integration and its
approval does not certify this production path. Changes stay in shared reader
readiness and Host
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
