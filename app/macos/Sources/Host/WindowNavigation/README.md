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
New-window HTTP(S) GET links use the external browser. Non-GET new-window form
requests are rejected with an in-document notice; the host never converts a
request body into a URL-only GET.
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

[NativeReadingPageStack](../../Shared/PluginUI/Conversation/NativeReadingPageStack.swift) retains reading-page identity through transitions. [NativeReadingPageTiming](../../Shared/PluginUI/Conversation/NativeReadingPageTiming.swift) centralizes duration and curves: outer ordinary-detail opening uses the emphasized 420 ms curve, while nested/default navigation and closing retain their declared policies. Page offset, parent shade/blur and the clipped page shadow derive from shared progress. The parent remains mounted through the return transition; identity changes, resize, inactive scene and disabled presentation settle/cancel the current generation.

Validation uses the existing navigation, sidecard and reading suites and the [Overview native input replay](../../../../../tools/verification/overview-input/README.md).
The [Report navigation replay](../../../../../tools/verification/reading-presentation/README.md#report-navigation-and-native-window-controls)
checks real WebKit scrolling, intermediate animation alignment, reversal, restoration,
suppression, resize, activation notifications, 0.25×–5× workspace safe areas,
editable/dialog key ownership, non-GET new-window rejection and remote-page
navigation resets with production views.

Moku note execution links enter through `openNoteExecution`, which admits public
ordinary threads, including archived and failed/interrupted threads hidden from
Overview. The result reading request is exact and does not start execution. A
missing or ineligible thread shows an unavailable notice; a missing execution
uses the reader's unavailable page. Each click receives a fresh reading request.
