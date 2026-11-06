# Thread Sidecards

The shared [NativePlugins](../../Composition/NativePlugins.swift) composition registers Conversation, Browser (`iab`) and Voice. The host in [Host/Sidecards](../../Host/Sidecards/) selects one expanded card, owns widths/responsive layout, outer transitions, focus and suppression, and injects [thread-bound capabilities](../../Shared/PluginAPI/SidecardPlugin.swift). Sidecards apply to ordinary Agent Threads.

Agent reading and the selected Sidecard occupy independent opaque reading-palette
panels with fine borders and a 16pt workspace gap. The resident Moku Dock stays
outside them. Separate 42pt round Liquid Glass launchers, spaced 14pt vertically,
remain centered in the right background margin and indicate the active card.
Opening a different launcher switches the retained plugin session; selecting it
again folds it. Per-plugin preferred widths and retained drag widths still belong
to the host. Below 760pt of available panel width the two panels stack vertically.
Only their shells change; plugin forms, browser behavior and voice ownership remain
with the existing sessions. Nested history Back belongs inside the main panel;
its independent Close returns to Overview.

An expanded card owning the current running/waiting execution publishes its
destination column to the resident Moku input through a passive native geometry
bridge across the reading panel's separate hosting tree. Input
centers below that column and narrows to fit it. Its horizontal entrance uses a
620ms-response spring with 0.78 damping for braking and a small rebound; shell
sizing and return keep the 380ms fold curve. On initial entry the compact Dock
finishes that travel before input expansion is admitted. Later card choices keep
the editor mounted and open. Dragging/resizing settles directly; stacked layout
uses the panels' shared full column width. Choosing Browser/Voice or another
non-owning activity centers and fits input below main, including for a completed
Thread; its send target remains that Thread. Browser annotation mode uses its
own column and description route as specified below. Folding, suppression, losing
selected-card eligibility or promoting a completed execution returns input to
the workspace center. No composer mounts
inside a Sidecard and no plugin input ownership changes. See the
[Reading-panel Dock contract](../../Host/MokuScene/README.md#reading-panel-dock)
for fit, editor lifetime and Sprint validation limits.

When the Agent reader selects a historical execution, the resident input stays
under main even if a newer execution owns the expanded Conversation Sidecard.
Its send uses the shared exact-execution continuation boundary also used by
Report. Returning to the ordinary current document restores latest-Thread input.
Browser annotation mode keeps its explicit activity draft and current-Thread
send authority; merely reading history does not retarget that separate action.

The host, execution pane and nested history route SwiftUI Escape through
`nativeReadingExitCommand`, sharing resident-input priority with native reading
without replacing focused-child dispatch. Native editors/marked text, menus,
transient controls and WebKit keep cancellation first. Foldable resident input
gets first refusal; pinned Agent-detail input stays expanded, so reading Escape
retains the selected Sidecard/nested-history close order before leaving the Thread.
Launcher toggles, browser address/annotation cancellation and non-Escape exit
commands retain their own routes. Covered/disabled cards cannot close a replacement.

Agent Sidecards have no independent Close icon. The corresponding right-side
launcher toggles open/closed and selecting another launcher switches activity.
The main Thread's Close remains separate. Conversation, Browser and Voice retain
their programmatic/Escape dismissal without ending execution, drafts or media.
The host's animated
[NativeSidecardFold](../../Shared/PluginUI/Conversation/NativeSidecardFold.swift) resolves the
corresponding launcher's actual bounds through SwiftUI layout anchors. One
interpolated presentation step moves the rounded paint and pointer aperture from
that button to the panel and back, including stacked layouts, retained widths
and workspace scaling. The source follows current launcher layout; if a button
loses availability during return, its last real bounds remain the destination.
The document stays mounted at panel size rather than stretching its text through
the launcher. The shell remains visible until the final part of folding.
Ordinary toggles and card choices admit each reader's destination size once,
including when retained widths differ. The main reading column's center and
outer shell animate separately, while its Close stays fixed at the upper-left;
TextKit and SwiftUI documents no longer receive intermediate widths on every
fold tick. Line wrapping therefore settles at the start of travel rather than
continuously reflowing. Only size changes clear inherited animation; subsequent
reader-owned animation transactions remain intact. Sidecard interpolation owns
only paint, hit aperture, opacity and the native aperture marker, with travel applied as a rendering
offset outside the document layout. Execution promotion also keeps each native
document at a fixed width while its shell moves.
The common opening uses a 380ms cubic Bézier `(0.22, 1, 0.36, 1)` for
aperture, offset and opacity, with one host selection transaction. The
[shared opening-path audit](../../Shared/PluginUI/README.md) also covers Report
references, HTML link/new-window entry, retained Browser reopening and the
separate native/WebKit content gates. Reduced Motion and divider dragging
settle geometry without travel.
The existing selected/suppressed gates disable folded, retiring and covered
cards; native document suppression, resizing, sessions and dismissal callbacks
keep their ownership. Completion handoff still promotes the retained execution
reader into the main panel.
See the [fold performance investigation](../../../../../design/sidecard-fold-performance.md)
for the original-recording evidence and this repair's sprint validation limits.

The `--thread-send-feedback-native` replay samples mounted native aperture
frames in the production layout for all three launcher positions, opening and
closing in wide/stacked layouts, quick reversals and switching, button availability
changes, resize during opening and retained width. Existing production
Conversation/Browser/Voice toggle, Dock and handoff cases run beside it.

## Conversation

Initial Host presentation is the third entrance stage: the main panel finishes
its actual travel, then main reveals its lines separately. The last line and any
completion footer must settle before a folded workspace commits and admits a
requested Sidecard. The resident Agent composer's input gate releases through
the same visit check after the compact Dock's horizontal travel completes,
then starts its 420ms expansion. Without an owning execution Sidecard, input is
admitted at the layout commit. The card keeps its existing 380ms animation.
No available card is required for input.
Plugin selection/execution ownership stays live while presentation waits; retiring
availability cannot be reopened by the layout completion. Reduced Motion also
removes the card's transition interaction delay. See the
[shared entrance contract and sprint limits](../../../../../design/reading-entrance-choreography.md).

[Conversation](Conversation/) is an execution display. It owns no composer,
draft, attachments, Send or Stop control; Agent input belongs to the Thread detail
Moku bar. Follow-up suggestions from Harness/Application reading routes append
to that Thread's Moku-bar draft and open its editor, preserving existing text and
attachments. Generic compose/send intents do not open it; the detail composer's
explicit, visit-scoped reveal request correlates its receipt with observed execution.

Availability requires an observed running/waiting execution and earlier/inherited
history in the Harness's full turn index. A first active execution stays in the
main reader. The Sidecard launcher only exists while the display qualifies; it can
show/hide the current execution without focusing the Moku editor or a new input.
Entering a Thread or explicitly opening its active execution (including a result
link) expands it once when the full session index contains another execution or
inherited history. A request for a different historical execution cannot reveal
the current one. An active first execution stays in main; unrelated background
starts do not create a new entry request. User fold/card choices win over delayed
index/receipt delivery and ordinary streaming updates. New explicit reading
requests and local detail sends may reveal again. Archive or loss of eligibility
closes and removes it. Acknowledged input alone does not prove an execution is active.
The host rejects stale launcher activations and retires unavailable selections
before publishing the next snapshot. Folding retains the existing execution
ownership policy and Harness response forms. The execution card has no decorative
title/emoji; its label is localized as Execution/执行.

The live execution viewport reserves 22pt at both vertical edges, with 12pt of
scrollable document padding at each end, matching the main Agent reader. The
viewport keeps its existing horizontal inset and contains the scroller at both
limits; the launcher and Escape continue to own dismissal.

## Browser

[Browser](Browser/) owns WKWebView navigation, URL policy, annotation and capture.
Its shared navigation toolbar and WebKit session also serve the Host's Report
link card through `NativeBrowserDocumentCard`. That document-owned surface has
an ephemeral partition and no SidecardContext, annotation draft, attachment or
send capability; Agent Sidecards retain their existing annotation behavior.
Report's Browser and related-execution list/detail share one active selection
and wait for Report document readiness plus 200ms on initial admission. Browser
DOM Back callbacks follow the current URL request and selection; a callback
from a folded or replaced card cannot dismiss its replacement. This does not
change Agent Sidecard timing. See the [Report admission contract](../../../../../design/report-sidecard-admission.md).

Agent Thread Markdown links (Codex, Claude, Pi and OpenCode, including current,
historical/inherited and Conversation execution readers) also route readable
local `.html`/`.htm` files into Browser. Absolute paths and local file URLs use
the shared PluginAPI parser; symlinks must resolve to a regular HTML file on a
local volume. Explicit link/address opening grants WebKit read access to that
document's directory for assets. A document at the filesystem root grants only
that file; WebKit never receives `/` as the read-access URL. A directory grant
allows directory contents, not just CSS/images, and is not a per-asset allowlist.
Local page/frame/popup navigation can visit validated HTML only within read-access
ranges already admitted by that session. New HTTP(S) page navigation cannot
reuse a past local grant; existing back/forward history may return to an admitted
local document. WebKit retains its own origin/file-access policy, and macOS
permissions still apply. No security-scoped grant or privacy override is added.
Queries, fragments, history, reload and HTTP(S) navigation retain the existing
Browser lifecycle. No page bridge acquires runtime, shell or Thread authority.
When Browser is unavailable, the existing system-open route validates HTML
before handing it off; other existing host-file actions retain their behavior.
Local documents disable annotation because the existing annotation transport
accepts only HTTP(S) sources. Existing web annotations and pending drafts remain
available after returning to a web page.

Browser pages and their frames retain their own scrollbar styling. The native
annotation list and its comment TextEditor use the shared trackless policy on
their respective viewports; system scrollbar preferences remain in effect.

Annotation selection no longer mounts a floating editor or native annotation
portal over the page. The selected Browser publishes a visit-scoped resident
composer request: Moku moves to the Browser column's horizontal center, retains
page focus until selection completes, then accepts a text description. Return
captures the current selection and submits the recoverable batch to the owning
Thread. Capture checks and failures, attachment staging/cleanup and receipt
consumption keep their existing owners. Cancel, navigation, covering, folding
and card switches revoke the request and restore normal Thread/Moku input.
The pending-annotation list, editing, preview and retry controls remain in Browser.
See the [resident annotation input contract](../../../../../design/browser-annotation-resident-input.md)
for lifecycle and Sprint verification limits.

Loading state follows the main frame. Address editing, page navigation and external URL intents retain their distinct focus ownership. A web view suppressed by host transitions does not paint over other surfaces. Annotations are assembled into shared attachments and sent through the current thread's admitted send capability; failed submission preserves the recoverable annotation batch. The footer's material/shadow belongs inside the browser's own surface.

Rejected subframe and new-window downloads do not replace the main page's ready/error state. Canceling an uncommitted navigation restores the last successful document's address and annotation readiness; a stale navigation cannot settle a newer one.
Annotation placement follows WebKit's applied page zoom at its limits, while
menu zoom commands retain their accumulated level for consistent reversal.

Browser drafts are isolated by profile and thread and remain in memory for the
application process. Returning to Overview releases WebKit and native dialogs,
while preserving unsent annotation comments, screenshots, supplementary text and
pending execution recovery. Deleting an annotation only removes that annotation;
remaining supplementary text stays editable and can be sent on its own. Accepted
send receipts consume their exact batch even after its presentation unmounts.
Native view/session generations reject late page callbacks after a switch or
teardown. Collapsing or covering a card is distinct from ending its underlying
activity.

Annotation metadata strips URL credentials before any conversation/model payload
is built. Capturing an element re-reads its current locator and text, rejects a
removed target, and checks that the selection is unchanged across the native
snapshot. DOM editing controls, shadow-tree editors and modal dialogs retain their
native editing semantics. Option+Left remains with WebKit, including editors in
closed shadow roots; unhandled Escape crosses the isolated WebKit bridge and
⌘K remains available for global Overview navigation. Browser chrome, errors and accessibility labels
use the current host translation.

Page-owned file pickers and JavaScript dialogs close with a negative result when the browser is suppressed, its document navigates, or its session is released. Their WebKit callbacks complete once, including when AppKit delivers a delayed sheet completion. Cancellation retains dialog ownership across synchronous reentrant navigation; normal completion releases ownership before the page can open its next dialog. `NativeBrowserDialogTests` obtains WebKit parameters from a local HTML fixture and exercises these native sheets without external pages.

Run `python3 tools/verification/reading-presentation/run.py --browser-dialogs` in a graphical macOS session. The isolated AppKit runner owns the application event loop and checks the complete four-test summary and all 19 cases. Ordinary SwiftPM skips this suite: without that event loop, `NSOpenPanel` can end the test process before the suite finishes, even with a zero exit status.

## Voice

[Voice](Voice/) now presents only retained **Past voice transcripts**. Its stable `voice` identity preserves settings and existing history, but it offers no call, microphone or mute controls. The native history source creates no media client; Runtime rejects thread prepare/start/heartbeat. The [native voice owner](../../Voice/README.md) retains only Overview global Moku calls. Stored discussion transcripts are not deleted or resent.

Verification uses the existing sidecard navigation, conversation, browser annotation/viewport and voice suites.

`NativeBrowserViewportTests` loads real loopback HTTP pages in WKWebView to
verify that iframe attachment and unsupported-MIME responses preserve the
main page. A rejected main-frame download likewise retains a successful source document; an initial download without a source remains an explicit error. The same fixture covers new-window downloads, cancellation before document commit, native word navigation in DOM/shadow editors and dialogs, and annotation capture after target mutation/removal. Its annotation replay
compares DOM geometry and the production native editor portal after zoom commands
pass both WebKit limits. Run `xcrun swift test --package-path app/macos --no-parallel
--filter 'NativeBrowserViewportTests|NativeBrowserAnnotationTests'` in a graphical
macOS session. `python3 tools/verification/reading-presentation/run.py --browser-viewport`
runs all nine viewport cases and the HTTP media freshness case in an isolated AppKit event loop, including focused
document Reload/Zoom through the real responder chain without changing host zoom.
Plain SwiftPM retains the portal geometry, document layers, cookie isolation and
navigation/cancellation cases. The annotation mouse-input and focused responder-
chain cases explicitly require this native replay capability; a display alone
cannot establish AppKit event-loop/key-window ownership.

The detail Moku bar owns text and attachment persistence per profile and Thread.
Browser annotation imports and send receipts retain their existing independent
capabilities and ownership. Removing the Conversation composer does not remove
Browser annotation sending or the Runtime follow-up command.

When the expanded execution terminates, the Host retains the current main reader
and its scroll position while a second production main reader prepares the exact
completed execution behind an opacity gate. The opaque content owner must confirm
termination and Markdown must finish parsing; a readable loading error can also
acknowledge readiness. Placeholders and cached running content cannot start the page turn.
The Host first folds the Sidecard back to its launcher using the shared 380ms fold
curve while widening the main shell. Only after that animation's actual completion
and destination content readiness does the 420ms downward page turn begin. These
independent gates accept either delivery order; delayed content leaves the old main
reader visible with the Sidecard already folded. The outgoing main column retains
its width; the incoming column lays out once at destination width. Core Animation
moves the native page seats, keeping TextKit's model viewport onscreen. Landing
keeps the same incoming host and scroll state; the folded source stays hidden.
Animation/readiness callbacks are fenced by handoff and execution identity.
Folding, card choice, replacement execution, archive, covering routes, release or
a different reading target cancels the old handoff. Main history navigation
remains in place rather than being replaced by this animation. Resize, an inactive
scene and Reduced Motion settle to the latest reader once its content is ready;
enabling Reduced Motion during travel also settles immediately. The handoff
never requests editor/content/launcher focus. Retained widths, stacked layout
and input ownership keep their existing boundaries. See the
[production handoff notes](../../../../../design/execution-handoff-production.md)
for the demo comparison and Sprint observation scope.

Same-document SPA history keeps the current address and annotation source synchronized. Unsupported protocol links and popup non-GET requests display a non-destructive notice; the latter are never rewritten as GET. The source document and unsent DOM input remain usable.
