# Report send execution transition

## Current contract

Report send no longer navigates to an Agent workspace or requests the former
three-card horizontal handoff. The Report HTML, sidecard shell, 5:5 detail layout
and resident composer column remain in place. Only the exact execution displayed
inside the sidecard changes. This supersedes the shared-column handoff developed
from the `录屏2026-11-05 19.29.31.mov` recording.

`NativeWorkspacePresentation` still uses the shared continuation sender: latest
input follows up or steers, historical input forks, and accepted receipts consume
only their original drafts. It waits for the destination Thread's catalog event,
then updates the route-owned `NativeReportSidecardPresentation`. Route, composer,
source reference and sidecard-selection identities fence the result. Returning to
the list, folding, choosing Browser or leaving cannot be undone by a late receipt.
Same-execution steering leaves the reader and its scroll position untouched.

`NativeReportExecutionScroll` retains the actual outgoing native reader at its
current scroll position. The incoming exact reader loads through the ordinary
capability, including scoped row/Markdown readiness, errors and unavailable
content. A small progress indicator remains visible while it prepares. When
ready, both viewports move upward by one viewport height: the new execution
enters from below, expressing scrolling down. Core Animation owns the shared
420ms reading replacement curve; model frames and TextKit widths stay fixed.
Landing retains the new host rather than reconstructing its reader. Streaming
and retries do not replay the transition.

The floating upper-left Back button stays stationary and usable during loading
and travel. It returns to the original related-execution list. Accepted successors
are local to this Report visit, including forks into another Thread; they do not
rewrite the Report's references and are not evicted by reference-list refresh.
Returning to the list ends that temporary detail visit. Ordinary reference
selection retains the existing readiness fade, empty list and missing-item policy.

Reader controls/accessibility are excluded during replacement. The composer uses
the incoming exact draft, with Send waiting for content/landing and existing Dock
geometry admission. Visit identities reject stale preparation and animation
callbacks. Reduce Motion, inactive/covered scenes and resizing settle ready
content directly. Landing waits for a nonzero viewport and reconciles resize
geometry before entering travel, so a queued ready callback cannot install
motion after settlement has already enabled input. Leaving/unmounting retires
retained readers. Folding retains
the current reader without replaying an already completed transition on reopen.

## Sprint verification boundary

This change is scoped to source review, diff/architecture lint and a native
`Mokusei` product build. No tests are added, and no regression tests, integration
replays, PRs, hosted CI, push, installation or release are performed. Local-main
integration retains this verification boundary.

Rendered direction/smoothness, native clipping, focus, rapid navigation,
Reduce Motion, resize and live asynchronous Harness behavior have not been
observed at runtime. Static review and compilation do not certify those behaviors.
