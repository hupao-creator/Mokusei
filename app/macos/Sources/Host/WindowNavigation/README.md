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
reopens it. Narrow workspaces stack the two panels and wide workspaces allow
resizing with the shared divider. Escape from the Report or linked webpage folds an open card
before closing the Report; editable elements and dialogs retain key priority.
Same-document anchors (including HTTP pages) and non-link navigations retain WebKit behavior.
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

The [workspace shell](../Shell/NativeWorkspaceView.swift) presents ordinary threads, Moku history, Report HTML and Git reading routes. Their back actions close the owning route or nested history; a plugin does not replace the host's navigation state. Native document/HTML content keeps the shared navigation safe area and cannot cover the back target.

Application and Git reading pages retain their back action across redraws.
Publishing navigation into the shell must not create a new action on the next
render and feed another publication. A changed route or language refreshes the
action; unmounting clears it and a new mount owns a new identity.
Run `python3 tools/verification/reading-presentation/run.py --application-navigation`
for the mounted production-page regression.

[NativeReadingPageStack](../../Shared/PluginUI/Conversation/NativeReadingPageStack.swift) retains reading-page identity through transitions. [NativeReadingPageTiming](../../Shared/PluginUI/Conversation/NativeReadingPageTiming.swift) centralizes duration and curves: outer ordinary-detail opening uses the emphasized 420 ms curve, while nested/default navigation and closing retain their declared policies. Non-panel page offset, horizontal parent shade/blur and the clipped horizontal page shadow derive from shared progress. Panel position, aperture and closing fade use the independent native compositor driver in [NativeReadingPanelTransition](../../Shared/PluginUI/Conversation/NativeReadingPanelTransition.swift). Vertical conversation-history navigation uses equal full-height travel on a flat plane, without these depth effects; its retained document changes enabled state only offscreen to preserve the native scroller gutter during opening/return. History replacement keeps that hidden document disabled throughout, independently of the shared active-motion flag. The parent remains mounted through the return transition. Resize or an inactive scene completes an accepted Close for that same route visit; otherwise the animation simply settles. Identity replacement, explicit cancellation and disabled presentation still cancel the current generation without closing a replacement route.

The outer workspace reading stack also owns the retained Overview presentation
gate. Panel opening pauses display projection immediately and admits its reader
only after compositor-driven travel completes. Non-panel opening and return keep
projection active, and settled-detail return awaits refreshed canvas layout
before sampling the return frame. Preparation belongs to the current route
generation: replacement or
cancellation cannot close another visit, and focus loss/disconnect completes an
already accepted Close even while preparation is pending. Nested stacks retain
their existing behavior unless a host supplies these optional hooks.

Validation uses the existing navigation, sidecard and reading suites and the [Overview native input replay](../../../../../tools/verification/overview-input/README.md).
The [Report navigation replay](../../../../../tools/verification/reading-presentation/README.md#report-navigation-and-native-window-controls)
checks real WebKit scrolling, intermediate animation alignment, reversal, restoration,
suppression, resize, activation notifications, 0.25×–5× workspace safe areas,
editable/dialog key ownership, non-GET new-window rejection and remote-page
navigation resets with production views.

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
failed/interrupted threads hidden from Overview. The result reading request is
exact and does not start execution. A missing or ineligible thread shows an
unavailable notice; a missing execution uses the reader's unavailable page. Each click receives a fresh reading request.
Report relation buttons and the Note are Overview entry points, so their Host
return action restores Overview. Admission rules remain entry-specific; archived
ordinary threads are valid for both, while the Note additionally admits ordinary
failed/interrupted threads hidden from Overview.

Retained current/result/history documents may mount the same row simultaneously.
The Harness host gives each content-resource acquisition its own subscription
handle, including for equal scopes. A departing document releases only its own
handle; the surviving document remains loaded. Execution disclosure groups still
share demand within their owning row, and retiring a surface releases all its
remaining handles.

Agent, Report, Git and Moku history reading use a panel-owned Close rather than a Back control beside the
traffic lights. Agent history executions have no dedicated upper-left Back button,
including when the shared history document has no navigation host. History retains
TOC navigation, Escape and its close action with the existing route-visit fence.
Other application navigation retains its own window-navigation behavior.
Moku history retains the underlying route and owns a separate nested navigation
scope; its current/archived session picker reserves space inside the panel for
Close, and its transcript does not drive window navigation. Report panel HTML keeps its trusted
DOM Escape/editing/dialog handling without installing the scroll-driven window
navigation portal; scrolling never moves the traffic lights. Git reuses the
conversation reader’s viewport-scoped native Escape cancellation, preserving
menu, IME and sibling Moku input ownership. Opening either application from an
Agent still restores that Agent and its reading target on Close. Overview entry
remembers the actual source card (the clicked Agent card for Git), and refreshes
its return frame after resize. These routes share panel margins, source-frame
animation, reduced-motion settling, rounded surfaces and the full-circle Close target.
The shared Close sits at the panel's upper-left with 48pt of fixed viewport
clearance below the top edge, also used by the execution Sidecard. The button
owns its 32pt circular background and hit shape, so
the entire visible circle responds rather than only the smaller icon area. Its outer
14pt padding remains panel spacing and does not become a close target.

Agent, Report, Git and Moku history panels also close on a completed click in the surrounding
blank workspace margin. The shared reading stack owns a separate backdrop hit
region, excluding the panel's complete rectangle (including internal whitespace,
Sidecards and their divider). Front controls, including the Sidecard toolbar and
Moku, remain above it. The backdrop is inactive during reading motion or covering
Moku interactions, and native sheets/popovers keep their dismissing press.
Outside dismissal uses the panel's existing Close route: an application opened
from an Agent returns to that Agent rather than dropping its reading target.
Escape in the current Agent document now has the same native fallback as history
and Git; nested history and Sidecards retain their existing cancellation order.
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
