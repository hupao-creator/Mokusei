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

The host, execution pane and nested history route SwiftUI Escape through
`nativeReadingExitCommand`, sharing resident-input priority with native reading
without replacing focused-child dispatch. Native editors/marked text, menus,
transient controls and WebKit keep cancellation first; otherwise Escape folds
open Moku input before folding the selected Sidecard or leaving the Thread.
Explicit Close, browser address/annotation cancellation and non-Escape exit
commands retain their own routes. Covered/disabled cards cannot close a replacement.

The host's animated
[NativeSidecardFold](../../Host/Sidecards/NativeSidecardFold.swift) keeps a 60pt
top chrome band visible while the document retains its right-origin unfolding. This includes the
execution reader's upper-left Close and Browser/Voice's existing toolbar Close.
The same interpolated aperture bounds pointer hits, so masked document controls
cannot receive clicks. The existing selected/suppressed gates still disable
folded, retiring and covered cards; native document suppression, the short fade,
offsets, resizing, stacking, sessions and Close callbacks keep their ownership.

## Conversation

[Conversation](Conversation/) is an execution display. It owns no composer,
draft, attachments, Send or Stop control; Agent input belongs to the Thread detail
Moku bar. Follow-up suggestions from Harness/Application reading routes append
to that Thread's Moku-bar draft and open its editor, preserving existing text and
attachments. Compose intents and send receipts cannot open this Sidecard.

Availability requires an observed running/waiting execution and earlier/inherited
history in the Harness's full turn index. A first active execution stays in the
main reader. An exact execution-result request also keeps its target in the main
reader. The Sidecard launcher only exists while the display qualifies; it can
show/hide the current execution without focusing the Moku editor or a new input.
Entering the Thread, starting another execution and reading requests do not
automatically expand it; only the user's launcher action opens the display.
Completion, interruption, failure, archive or loss of eligibility closes and
removes it. Acknowledged input alone does not prove that an execution is active.
The host rejects stale launcher activations and retires unavailable selections
before publishing the next snapshot. Folding retains the existing execution
ownership policy and Harness response forms. The execution card has no decorative
title/emoji; its label is localized as Execution/执行.

## Browser

[Browser](Browser/) owns WKWebView navigation, URL policy, annotation and capture.
Its shared navigation toolbar and WebKit session also serve the Host's Report
link card through `NativeBrowserDocumentCard`. That document-owned surface has
an ephemeral partition and no SidecardContext, annotation draft, attachment or
send capability; Agent Sidecards retain their existing annotation behavior.

Browser pages and their frames retain their own scrollbar styling. The native
annotation list and its comment TextEditor use the shared trackless policy on
their respective viewports; system scrollbar preferences remain in effect.

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

[Voice](Voice/) presents availability, media controls and separate spoken transcripts from a [private read-only discussion](../../../../../internal/services/threadvoice/README.md). It does not send ordinary task input, answer the source task's permissions or write discussion history into that task. The [native voice owner](../../Voice/README.md) controls microphone and connection lifetime. Opening a card alone does not start capture.

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

An execution-result reading request keeps its targeted active execution in the
main reader instead of moving it into the Conversation sidecard. This preserves
the same mounted reading visit and user-controlled following across completion.
Other execution and composer behavior retains the normal sidecard policy.

Same-document SPA history keeps the current address and annotation source synchronized. Unsupported protocol links and popup non-GET requests display a non-destructive notice; the latter are never rewritten as GET. The source document and unsent DOM input remain usable.
