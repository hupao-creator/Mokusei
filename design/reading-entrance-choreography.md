# Reading entrance choreography

## Contract

Agent detail, Report and Git entry share a primary reading entrance. The retained
tag chrome withdraws upward and fades while Moku takes its reading seat; both use
`NativeReadingPageTiming.openingAnimation` (420ms, cubic 0.76/0/0.24/1), matching
the emphasized panel opening. The existing identity-target preparation may precede
compositor travel; secondary work never estimates its completion with a 420ms timer.
Tag layout/canvas clearance and Moku's bottom-anchored native editor stay intact.

The reading Dock lowers its bottom edge by up to 16 logical points, bounded by a
12-point bottom margin (normally 12–20 points). Width, top clearance, expanded
height fitting, reasoning-ink fitting and interaction regions still derive from
the same fitted surface. Landing and Settings keep their own seating. Report/Git
use the same lower seat without forcing open their Moku composer.

## Two-stage admission

The owning `NativeReadingPageStack` supplies `nativeReadingEntranceReady` to its
front only after actual primary completion. Panel entry uses the generation-fenced
Core Animation delegate; non-panel entry uses its existing progress driver.
When Agent identity ink is present, the gate also waits for its existing
measured-anchor handoff. Panel travel alone can finish before that handoff;
opening a Sidecard then would move the destination beneath the retained ink.
Reduce Motion and entries without identity ink do not acquire this extra wait.
Resize, recovery and Reduce Motion settle through the same stack. Accepted Close
and return preparation keep this gate shut.

An Agent workspace initially publishes a folded Sidecard layout even if the
Conversation plugin has already requested its active execution. Its native
`NativeReadingEntranceStage` waits for that layout's transaction commit and the
primary gate, then admits the current selection. This causes a separate existing
380ms Sidecard fold/layout animation. There is no new elapsed-time opening task.
Plugin sessions, execution exclusion and user selection revisions keep their
existing ownership; hiding presentation does not transfer an execution to main.
The stage latches once per mounted workspace, so primary Close does not fold an
already-expanded card underneath the returning panel.

The boundary invalidates queued completion on disable, detach and replacement.
Sidecard release cancels its transition task. Repeated plugin requests retain the
current selection and do not restart travel. Availability loss before admission
retires selection normally, so a completed/archived/disabled execution cannot be
resurrected at stage two. An empty registry or an ineligible first execution opens
no Sidecard. The existing execution-completion handoff remains separate and cannot
start before entrance admission. Reduce Motion removes travel and the 380ms
interaction delay while retaining layout/readiness and cancellation ownership.

## Scope and verification limits

Changes stay in native presentation: shared reading timing/admission, Overview
chrome, Moku geometry and the Host Sidecard presentation model. No Runtime,
Harness contract, Report HTML, placeholder-logo alignment, input dismissal,
source identity flight or Sidecard folding/promotion implementation changes.

Sprint mode permits static review, product build and lint only. No tests are
created or executed, no replay runs, and no repaired-build interactive acceptance
has been performed. In particular, rendered-frame smoothness, fast user-driven
reversal, actual focus/IME behavior and compact/zoomed window appearance remain
unverified dynamically. Hosted CI and integration belong to the caller; this work
is committed only in the detached managed worktree.

Local verification completed: `swift build --product Mokusei` (Debug, macOS 26,
Swift 6.3.2), `make lint` (architecture/static registration/no-Node, Go formatting
and `go vet`), `git diff --check` and the new README links. GitHub protection/PR/run
lookup could not connect to the API; no hosted validation was triggered. A future
integration has mixed Swift/documentation scope and requires the caller's normal
native CI rather than documentation-only coverage.
