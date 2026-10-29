# Thread Sidecards

The shared [NativePlugins](../../Composition/NativePlugins.swift) composition registers Conversation, Browser (`iab`) and Voice. The host in [Host/Sidecards](../../Host/Sidecards/) selects one expanded card, owns widths/responsive layout, outer transitions, focus and suppression, and injects [thread-bound capabilities](../../Shared/PluginAPI/SidecardPlugin.swift). Sidecards apply to ordinary Agent Threads.

The collapsed launcher group uses concentric capsules: 30pt-high button feedback
inside 5pt padding and a 40pt-high glass surface. Clip launcher contents before
applying glass so the system owns the capsule's outer highlight and shadow;
clipping the glass itself would cut off that shadow.

## Conversation

[Conversation](Conversation/) owns its draft and active-execution presentation. Its history qualification comes from the Harness's complete public turn index, not whichever lazy body is loaded. A first running/waiting turn remains in the main reading area. With earlier/inherited history, the active process can be shown in the execution card. Send intents and receipts coordinate with other cards through the host; plugins do not import siblings.

## Browser

[Browser](Browser/) owns WKWebView navigation, URL policy, annotation and capture.

Browser frames opt into the [shared trackless scrollbar policy](../../Shared/PluginUI/README.md#scrollbars).
It decorates scrollbar parts without replacing native scrolling, selection or
input handlers; system persistent-scrollbar preferences retain priority over
transient hiding. Browser chrome and Moku theme colors remain caller-owned.

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

The Conversation input uses the shared composer's focused paste handling for PNG/TIFF clipboard images and local file URLs, including accompanying text. Its attachment chips, import limits/errors, pending removal and attachment-only submission reuse `NativeComposerDraft`. Each deliberate paste imports one batch; plain text remains a native editor action. Folding retains staged attachments in the plugin session; releasing that session persists imported attachments in a profile/thread-scoped draft alongside the independently revisioned text draft. Reopening restores the chips; removal discards staged files and an accepted send consumes its exact attachment identities, including after release and after a successor adds files. New files, in-flight imports and new text survive late receipts. The host injects device-local imports and policy through `SidecardAttachmentImport`; send receipts retain successfully submitted files.

Replay: `xcrun swift test --no-parallel --package-path app/macos --filter 'NativeSidecardAttachmentPasteTests|NativeComposerPasteTests|NativeSidecardNavigationTests'` (requires a graphical macOS session).

An execution-result reading request keeps its targeted active execution in the
main reader instead of moving it into the Conversation sidecard. This preserves
the same mounted reading visit and user-controlled following across completion.
Other execution and composer behavior retains the normal sidecard policy.

Same-document SPA history keeps the current address and annotation source synchronized. Unsupported protocol links and popup non-GET requests display a non-destructive notice; the latter are never rewritten as GET. The source document and unsent DOM input remain usable.
