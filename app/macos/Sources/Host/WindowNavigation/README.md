# Window and reading navigation

[Semantic workspace actions](../Interaction/README.md) expose navigation to scripts
through the same presentation methods. Back dispatches the active reading action;
Settings uses its shared draft close gate.
Navigation callbacks carry the current route-visit identity, so a delayed page
disappearance cannot clear its replacement's back action. The reading stack also
keys its front by that visit when reopening a retained thread. Settings belongs
only to Overview and cannot cover a Thread or application reading route.

[NativeWindowNavigationView](NativeWindowNavigationView.swift) owns shared
window/back controls. [NativeWindowControlPlacement](NativeWindowControlPlacement.swift)
positions native Mac traffic lights and retains the active Report reading offset
per window. Report's navigation portal publishes its current 220 ms scroll offset
to this bridge on every animation tick: all three native buttons retract with the
capsule, become hidden at the endpoint, and return with their original sizes,
actions and coordinates. Window/toolbar relayout and activation reapply that same
offset rather than resetting to the expanded position. Suppressing, detaching or
replacing the Report restores the controls; full-screen placement belongs to AppKit.
The offset is in window points and does not scale with document or workspace zoom.
Report HTML reserves that same physical top clearance after both workspace and
document zoom. New main-frame documents start with expanded navigation, and
HTTP(S) destinations report their own scroll state. WebKit retains Option-Left
for native word movement, including editors hidden inside closed Shadow DOM.
Escape stays with native form inputs, actual editable elements in the composed
event path, and open HTML dialogs before the document's back action is considered.
The Overview command remains available as the global return shortcut.
In a Report panel, main-frame HTTP(S) link clicks and new-window HTTP(S) GET
links open a separate browser card, leaving the Report mounted with its reading
position. The card shares Agent Browser navigation chrome, WebKit URL/download
policy, dialogs, focused document commands and native viewport, but exposes no
annotation controls, drafts or execution-send capability. Its partition belongs
to the reading visit. Closing folds the retained page; the Browser launcher
reopens it. Wide workspaces initially split Report and Browser equally, subject
to the shared minimum widths, and allow resizing with the shared divider. Narrow
workspaces stack the two panels. Escape from the Report or linked webpage folds an open card
before closing the Report; editable elements and dialogs retain key priority.
Same-document anchors (including HTTP pages) and non-link navigations retain WebKit behavior.
The linked Browser opens with the same `NativeSidecardFold` aperture and
launcher travel as Agent Execution/Browser/Voice and Report related executions:
380ms with cubic Bézier `(0.22, 1, 0.36, 1)`. Its launcher is the lower 42pt
right-rail control. The native document takes its destination size once while
the shell unfolds. Closing retains the existing whole-shell fade and workspace
movement through the shared fold's `fadesOnClose` presentation policy.
The shell stays mounted even before the first link, while its WebKit session
still starts only when a URL exists. Selection therefore drives opening in the
same transaction as the main pane, without a second state, layout callback or
completion/reset timer. The Report's HTML-ready 200ms admission delay is
independent of this motion.
Reduced Motion disables the workspace's folding and stacking animation.
Outside a Report panel, new-window HTTP(S) GET links use the external browser.
Non-GET new-window form requests are rejected with an in-document notice; the
host never converts a request body into a URL-only GET.
This restores the contract from `bfc2c9f4f`, whose synchronization calls were
removed by the SwiftUI shell migration `310149f1d`; `ef0164c88` subsequently
restored only fixed placement.

The optional back-frame callback reports logical `workspace` coordinates for
navigation geometry observers. Settings now owns a separate panel close button
inside the resident Dock and no longer uses a window-wide return mask.
Only actual controls own pointer regions; dragging the window header does not
pan Overview. Hover is reconciled with current availability and pointer geometry
rather than a stale enter event.

The [workspace shell](../Shell/NativeWorkspaceView.swift) presents ordinary threads, Moku history and Report HTML reading routes. Their back actions close the owning route or nested history; a plugin does not replace the host's navigation state. Native document/HTML content keeps the shared navigation safe area and cannot cover the back target.

Application reading pages retain their back action across redraws.
Publishing navigation into the shell must not create a new action on the next
render and feed another publication. A changed route or language refreshes the
action; unmounting clears it and a new mount owns a new identity.
Run `python3 tools/verification/reading-presentation/run.py --application-navigation`
for the mounted production-page regression.

[NativeReadingPageStack](../../Shared/PluginUI/Conversation/NativeReadingPageStack.swift) retains reading-page identity through transitions. [NativeReadingPageTiming](../../Shared/PluginUI/Conversation/NativeReadingPageTiming.swift) centralizes duration and curves: outer ordinary-detail opening uses the emphasized 420 ms curve, while nested/default navigation and closing retain their declared policies. Non-panel page offset, horizontal parent shade/blur and the clipped horizontal page shadow derive from shared progress. Panel position, aperture and closing fade use the independent native compositor driver in [NativeReadingPanelTransition](../../Shared/PluginUI/Conversation/NativeReadingPanelTransition.swift). Vertical conversation-history navigation uses equal full-height travel on a flat plane, without these depth effects; its retained document changes enabled state only offscreen to preserve the native scroller gutter during opening/return. History replacement keeps that hidden document disabled throughout, independently of the shared active-motion flag. The parent remains mounted through the return transition. Resize or an inactive scene completes an accepted Close for that same route visit; otherwise the animation simply settles. Identity replacement, explicit cancellation and disabled presentation still cancel the current generation without closing a replacement route.

The outer workspace reading stack also owns the retained Overview presentation
gate. Panel opening pauses display projection immediately. Ordinary Agent card
entries preload the primary reader after native animation-start delivery; drawing,
input, accessibility and secondary surfaces wait for arrival. Other panel entries
retain their arrival mounting gate. Card identity flights first mount
a lightweight workspace layout with a row-free conversation heading; this fixes
the destination before travel without mounting Harness documents. The real
reader takes over without a second title movement. The outer Agent route starts
data-only manifest/target-row prefetch during travel, owned by the route visit
and target execution; cancellation cannot publish into a replacement reader.
Data-only prefetch itself mounts no TextKit or conversation view; the separate
Agent reader preload can prepare native content during travel. Non-panel opening
and return keep projection active, and settled-detail return awaits refreshed
canvas layout
before sampling the return frame. Preparation belongs to the current route
generation: replacement or
cancellation cannot close another visit, and focus loss/disconnect completes an
already accepted Close even while preparation is pending. Nested stacks retain
their existing behavior unless a host supplies these optional hooks.

Validation uses the existing navigation, sidecard and reading suites and the [Overview native input replay](../../../../../tools/verification/overview-input/README.md).

Agent entry waits for the panel/title handoff and active main-document readiness
before admitting Moku input and Sidecards. Markdown draws in full once parsed
and the panel is admitted. Nested history, including an empty/error page, holds
content readiness until its own travel finishes. Report admits its auxiliary
card after primary travel and a committed folded layout. See the
[admission contract](../../../../../design/reading-entrance-choreography.md).
The [Report navigation replay](../../../../../tools/verification/reading-presentation/README.md#report-navigation-and-native-window-controls)
checks real WebKit scrolling, intermediate animation alignment, reversal, restoration,
suppression, resize, activation notifications, 0.25×–5× workspace safe areas,
editable/dialog key ownership, non-GET new-window rejection and remote-page
navigation resets with production views. Its panel-scale checks observe the
existing 380ms responsive fold until the native frame reaches the unchanged
one-point geometry tolerance. Panel Escape checks first observe WebKit's focused
document frame for editing and for the subsequent non-editing key.

Direct execution requests enter through Report/application `openExecution`,
explicit `openThread` reading targets, or Moku note `openNoteExecution`. All four
Harnesses forward these requests to the shared conversation reader. The requested
document owns the route's entry Back action, independently of start/result scroll
position, current/history mode, or whether a newer execution already exists.
Back (including Escape and the unavailable page's close action) exits through
the Host's return action without inventing a visit to the current document.
Explicit TOC navigation relinquishes that entry ownership, even when reselecting
the same historical row; Back then restores the current document before leaving.
A new request, including a repeated link, starts a fresh entry visit.
The mounted active history document handles Escape in its own window even if
result positioning leaves no SwiftUI focus target. Focus outside its viewport,
editing, IME composition and native menu/popup cancellation retain priority;
hidden/transitioning documents
cannot consume another page's Escape.

Moku note execution URLs are parsed by the shared Markdown link boundary and
enter through `openNoteExecution`; there is no OS-level execution URL handler.
This entry admits public ordinary threads, including archived and
failed or Moku-tool-interrupted threads hidden from Overview. The result reading request is
exact and does not start execution. A missing or ineligible thread shows an
unavailable notice; a missing execution uses the reader's unavailable page. Each click receives a fresh reading request.
Report relation buttons and the Note are Overview entry points, so their Host
return action restores Overview. Admission rules remain entry-specific; archived
ordinary threads are valid for both, while the Note additionally admits ordinary
failed or Moku-tool-interrupted threads hidden from Overview.

Retained current/result/history documents may mount the same row simultaneously.
The Harness host gives each content-resource acquisition its own subscription
handle, including for equal scopes. A departing document releases only its own
handle; the surviving document remains loaded. Execution disclosure groups still
share demand within their owning row, and retiring a surface releases all its
remaining handles.

Agent, Report and Moku history reading use a panel-owned Close rather than a Back control beside the
traffic lights. Agent history executions have no dedicated upper-left Back button,
including when the shared history document has no navigation host. History retains
TOC navigation, Escape and its close action with the existing route-visit fence.
Other application navigation retains its own window-navigation behavior.
Moku history retains the underlying route and owns a separate nested navigation
scope; its current/archived session picker reserves space inside the panel for
Close, and its transcript does not drive window navigation. Report panel HTML keeps its trusted
DOM Escape/editing/dialog handling without installing the scroll-driven window
navigation portal; scrolling never moves the traffic lights. Opening an application from an
Agent still restores that Agent and its reading target on Close. Overview entry
remembers the actual source card, and refreshes
its return frame after resize. These routes share panel margins, source-frame
animation, reduced-motion settling, rounded surfaces and the full-circle Close target.
The shared Close sits at the panel's upper-left. Viewports normally reserve
48pt below the top edge; the main Agent reader uses symmetric 22pt viewport
insets and clears Close horizontally through its reserved 48pt history rail.
The rail retains its own 64pt vertical padding. This applies to both opening
heading preparation and the live current/history reader, retaining measured
title handoff and the existing content readiness gates for input and Sidecards.
Agent Sidecards use their right-side launcher as
the open/close toggle and have no independent Close icon. The main panel button
owns its 32pt circular background and hit shape, so
the entire visible circle responds rather than only the smaller icon area. Its outer
14pt padding remains panel spacing and does not become a close target.

Agent, Report and Moku history panels also close on a completed click in the surrounding
blank workspace margin. The shared reading stack owns a separate backdrop hit
region, excluding the panel's complete rectangle (including internal whitespace,
Sidecards and their divider). Front controls, including the Sidecard toolbar and
Moku, remain above it. The backdrop is inactive during reading motion or covering
Moku interactions, and native sheets/popovers keep their dismissing press.
Outside dismissal uses the panel's existing Close route: an application opened
from an Agent returns to that Agent rather than dropping its reading target.
Escape in the current Agent document now has the same native fallback as history;
nested history and Sidecards retain their existing cancellation order.
Application panel chrome also accepts Escape while loaded WebKit content keeps
its trusted DOM editor/dialog handling. Native editors, IME, menus, sheets,
popovers and sibling Moku focus take precedence over reading cancellation.

Snapshot rehydration, disconnection and appearance changes stop reading motion
with `finishingClose: true`: an already accepted Close completes its current
visit even when the target was settled before the click. Ordinary updates do
not stop the return. Explicit navigation/cancellation retains the default
cancellation policy, so recovery cannot revive a cancelled return or close a
new visit. The full-workspace replay clicks the settled panel's icon before
injecting these events, including control cases for ordinary mutations and
same-authority snapshots.

Report reading cards reserve 8pt on every side of the WebKit viewport. Close
overlays the upper-left document area with an opaque canvas circle behind its
32pt target, preserving contrast over authored backgrounds. The host clips the
viewport to a 14pt rounded rectangle before adding the 8pt inset, following the
outer panel's 22pt curve with an even border. The right-hand scrollbar remains
inside the clipped viewport, and both scroll limits retain the same 8pt border.
This is card chrome, independent
of the existing HTML safe-area and authored page padding; no Report HTML, CSS,
scroll offset or theme content is rewritten by this viewport adjustment.


Agent panel entry captures only the source title/emoji text and native window
geometry. Its lightweight compositor ink survives deferred reader mounting and
hands off at actual heading anchors; source-less/direct-result routes skip that
bridge. Agent closing takes 420ms: content fades over the first 80%, scaling
and travel reach the source card at 86%, and the opaque shell crossfades to
Overview over the final 14%. There is no separate closing identity travel. Other
panel routes retain their previous fade policy. Route generations, refreshed parent
layout, cancellation and resize completion remain owned by the reading stack.

Report owns its HTML and associated-execution reading shells. The HTML first
commits at full width. After primary travel, the folded layout commit and the
current HTML document's WebKit main-frame completion, a cancellable 200ms gate
admits the related-execution Sidecard's fold from its right-rail launcher.
The launcher toggles expansion without discarding the selected execution.
Agent and Report share the fold, toggle chrome and workspace geometry (including
minimum pane widths and narrow-window stacking). References prefer 30% width,
then 50% for a selected execution, subject to that shared geometry.
The outer workspace reserves one real toolbar rail for Report and Browser
controls, and supplies the Report launcher's seat in its local coordinates.
Both cards share one active/pending selection: opening either replaces the
other, including the related list. Close and replacement win over delayed
admission; document revisions, retries, covering and departure retire old work.
`NativeReadingAuxiliaryBackKey` forwards the current auxiliary Back action upward;
native and HTML Escape fold a linked browser or return from an opened execution
to references before closing the Report. The related list is part of its default
view: with no execution open, Escape closes the Report directly, including while
the list is pending admission or after reopening it through its launcher. Folding
the list remains an explicit launcher action. A pending related card with a
retained execution still cancels before opening and restores launcher focus.
The auxiliary action exists only for an active/pending related card with a
selected execution; folding, replacement and visit identities retain their fences.
Report HTML keeps its 8pt viewport inset and 14pt inner clipping independently
of the Sidecard. For related-card width/height changes, the actual HTML viewport,
inner clip and 22pt outer shell/border share one interpolated size. The retained
WebKit document reflows during travel, avoiding a final-width layout jump ahead
of its shell. Browser routing, divider resizing and retained documents keep
their existing ownership.
See the [admission and referenced-execution contract](../../../../../design/report-sidecard-admission.md)
for readiness, cancellation, screenshot diagnosis and Sprint verification limits.

An expanded referenced execution lends its exact identity and destination column
to the resident composer. Returning to references, folding, replacing it with a
Browser, covering or leaving revokes that input target. Editor Escape uses the
same auxiliary Back action as the reader. Accepted input selects the resulting
exact execution in the same Report sidecard only while the same Report/composer
and sidecard-selection visit still owns navigation. Catalog publication may
arrive after the command receipt; the Report route and HTML remain mounted.

Agent TOC/history/result reading uses that same execution continuation policy.
The actual main reader publishes its selection rather than relying solely on
the Host's entry `readingTarget`. Request and reader-owner identities fence late
publications; history travel and unavailable/non-execution pages disable send.
Returning to the ordinary current document relinquishes the exact input target.

Accepted Report continuation keeps the existing 5:5 detail layout and resident
composer column. `NativeReportExecutionScroll` retains the old reader's actual
scroll position while the accepted exact execution prepares its scoped row and
Markdown. Once ready, the old viewport moves up and the new one enters from
below over the shared 420ms reading replacement curve. The incoming native host
survives landing; neither text layout nor document scroll offsets animate.
The floating upper-left Back button stays outside the moving viewport and
returns to the authored related-execution list, including during preparation.
New continuations need not occur in that list; catalog refresh does not discard
them or alter Report references. Same-execution steering updates in place without
another transition. Normal list selection keeps its 200ms readiness fade.

Pointer/accessibility and reading controls are gated during replacement; input
waits for content, landing and existing Dock geometry admission. Route, composer
and sidecard-selection identities fence late receipts; reader-visit identities
fence readiness/completion. Folding, Browser selection, covering and return
revoke pending send navigation. Reduce Motion, inactive/covered scenes and resize
settle admitted content without travel. Returning to the list or unmounting retires
both reader leases. Ordinary Agent sends, Agent history navigation and completion
promotion retain their own behavior. See the [implementation notes](../../../../../design/execution-route-slide.md).

Report related-card width changes keep the HTML document anchored at its
left edge and resize its viewport with the shell. Selection travel does not animate newly
inserted reader geometry. The related capability owns one 200ms native opacity
entrance per selected visit, after scoped-row and Markdown readiness; manifest
mounting cannot consume it. Loading remains visible while preparing, and hidden
reader controls/accessibility cannot act. Errors admit normally, refresh/retry
keeps the same entrance, and a new selection retires pending preparation. Reduce
Motion skips or settles the fade without replacing the reader. See the
[related-execution fade investigation](../../../../../design/related-thread-fade.md) and the [recording investigation and Sprint limits](../../../../../design/report-sidecard-admission.md#continuous-report-viewport-follow-up-2026-11-05-191303).

Closing a settled Report retains its current split layout from return preparation
through route completion. The Report main shell scales/translates directly from
its presented width and height to the refreshed Overview source card; related
execution and linked Browser Sidecards fade in place on the same 420ms timeline.
The full-workspace native carrier stays stationary for this return and owns only
generation-fenced completion, avoiding a second crop/travel over the split panes.
Closing before primary content admission keeps the existing native opening-reversal
path. Reduce Motion, resize, cancellation and inactive-scene completion retain
the reading stack's policies. See the [return investigation](../../../../../design/report-sidecard-close.md)
for the retained-layout boundary and Sprint validation limits.
