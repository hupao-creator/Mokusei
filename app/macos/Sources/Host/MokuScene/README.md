# Chief presentation

[NativeMokuWorkspacePresentation](NativeMokuWorkspacePresentation.swift) derives the current Moku execution's display from public transcript operations. [NativeMokuSceneState](NativeMokuSceneState.swift) owns transient presentation and dismissal. The [Go coordinator](../../../../../internal/services/moku/README.md) owns task admission, tool results, notes.

The composer, conversation history, note and reminder use the Chief name in
both interface languages, including their Accessibility labels.

Question choices use the full visible rounded rectangle as their button hit
shape, including padding and the empty space beside the answer text.

Settings uses the SwiftUI [reveal overlay](../Settings/NativeSettingsTransition.swift)
inside the persistent scene. Scene state retains Settings through return and
reports its transition lifetime; the overlay owns animation completion and
settling, without restoring the retired AppKit scene host.
The Settings content suppresses inherited animation only for changes to the
expanded state, so its final layout remains stable during the shell morph while
subsequent child-owned animations retain their own transactions.
A geometry group outside that transaction resolves the shell's animated page
placement first. Closing therefore carries the fixed-size page with the shell
instead of immediately centering its Map, title and form in the collapsed Dock's
width. Compositing alone does not provide this layout boundary.

Moku history uses the same bounded reading stack and panel shell as Agent, Git
and Report reading: shared margins, rounded surface, border, dimmed/blurred
retained background and panel-owned Close. The reader displays the
current Moku session; archived session data remains stored. The reading card and
the current-session input capsule are separate siblings, with a 12pt gap and the
same horizontal center; the card alone owns the rounded reading surface and
Close.

Close, the surrounding blank margin and Cmd+B return through the shared motion
lifetime; native Escape first returns from an internally selected historical
turn, then closes the panel. Editors, IME, menus and popovers keep priority.
Resize, scene deactivation and recovery complete an accepted Close. The parent
stays mounted with its route identity and navigation intact, preserving Agent,
Git or Report reading on return. History has a separate navigation visit and
does not publish scroll-driven traffic-light navigation. Its panel geometry
adapts to narrow windows using the existing shared contract.

Entering history from Note keeps the existing Note-dismissal behavior. History
covers the outside Dock and owns its existing current-session composer. Note
layout/closing motion, scrollbar policy and Agent composer motion are independently owned.

## Dock and composer

Dock and history composer placeholders stay on one line and truncate at the tail.
The native draft editor remains multiline.
The composer layout reserves attachment/action seats and the resident eye seat
(the actual Harness logo in Agent detail) before giving
the remaining width to the editor; long placeholder text cannot displace Stop.
Dispatch status remains a single line with tail truncation and retains the
Dock's separate trailing control inset. Its configuration adapts within that
reserved content seat as described below.

Moku’s Dock (idle, landing, composer, Talk, dispatch and Note), interaction
panel and history input capsule use a dark SwiftUI environment.
The current and archived Moku conversation reading cards inherit the workspace's
system appearance. The capsule's dark environment is scoped to its own content.
Settings and the onboarding forms use the system appearance. Settings uses the
opaque native window background, including with Reduce Transparency. The
illustrations have their own [Liquid Glass panels](../Settings/README.md).
The resident eyes travel into the reserved header seat during expansion and
follow that seat when the Settings shell scrolls at extreme zoom.

The collapsed Overview Dock is the original 168×44-point eye capsule. Its warm
capsule material and Note's Regular glass share one persistent native glass node.
The character's state colors, expressions, blink timing and Settings/onboarding
handoff and target-gaze animations use the original vector renderer. No Harness
sphere artwork or palette is loaded. Agent detail retains its actual Harness
logo; Overview and history input reserve the eye seat. The Stop control remains
at the trailing edge with its existing cancellation and accessibility semantics.

The shared input row places the attachment plus immediately to the right of
the identity seat. Below 260pt the editor takes the upper row and the plus
stays beside the identity on the lower row. A primary click or accessibility press opens
the device file chooser directly. For host-enabled drafts, the contextual
menu on the same button offers host files and host directory references.
The composer remains dark in both macOS appearances. A native chooser keeps
its Escape and Cancel behavior. Cancelling adds no chips and leaves the draft
available. The same current Chief draft and send route serve Overview and
Chief history. Chief's delegation tools take text prompts. When a delegated
Agent needs a file, its prompt can refer to the file by its managed path.

Agent entry sequences the compact Dock's travel, the eyes-to-Harness flip and
composer expansion. The reading entrance's actual arrival/layout admission
releases the flip; its removed animation completion releases input and the
existing focus path. A composer-generation fence and a view-local transition
generation reject replaced or detached completions without an elapsed-time task.
The small downward reading-seat shift uses the existing native travel host,
with a 420ms ease-in/ease-out curve rather than SwiftUI layout animation. Reader
preparation cannot stall submitted travel frames. Both axes share sampled
replacement geometry, completion fencing and moving-control hit protection;
shell sizing and composer expansion remain owned by SwiftUI.
Rapid replacement retains the current mark during travel; the same Harness
reuses a settled or in-flight flip. Return keeps the existing collapse path.
An inactive scene or a hidden window settles the mark immediately,
while reading/content readiness still gates input. See the
[entrance contract](../../../../../design/reading.md).

[NativeMokuDock](NativeMokuDock.swift) uses one native glass capsule with a bottom-center anchor. Idle size is 168×44 points; expanded width is bounded to 560 points and the available viewport. [NativeMokuComposer](NativeMokuComposer.swift) shares the input row between the Dock and history. Collapsing and reopening the Dock input restores the caret/selection saved while it was open; the first open keeps the existing autofocus behavior. The native editor snapshots selection before becoming unavailable during collapse and restores it on a rapid reopen; the scene retains the selection and its exact UTF-16 text for a later editor remount. Unchanged multiline/Unicode text retains the native range. Changed text reopens at its end rather than reusing stale offsets. Selection restoration neither requests focus nor changes draft persistence; draft context changes clear the scene snapshot, and marked text remains owned by the input method. A normal click can acquire the native editor without being undone by a delayed SwiftUI focus report.

Dock and history clear submitted text, directory mentions and ready attachment
chips in the mounted editor as soon as the draft captures the send. The
retiring Dock capsule also clears its sealed ink snapshot before collapse.
The pinned Thread editor remains editable and keeps its native first responder
while the send awaits confirmation. A reopened ordinary Dock can also edit its
next draft. The draft blocks further submissions until the pending send settles.
Browser annotation retains its own read-only submission interval.
Admission still owns persistence consumption and staged-file release. Failure
reveals the retained draft, preserving any new text after the failed message;
no automatic retry occurs. **Check previous receipt** checks the saved command
ID. A missing receipt permits local review after checking the conversation.
Local recovery offers **Restore to draft** or **Keep next draft**. Both choices
are local and preserve the editable successor. Ready image chips use system Quick Look with the
shared strip's local managed-file URLs and independent preview/remove actions.
No current e2e evidence is supplied for Quick Look focus or pointer behavior.

The identity seat retains the last open editor position while the composer
retires. Directory completion stays above the same bottom-anchored native editor.
Its measured height changes the shell without replacing the editor or its
selection owner through entry, exit and rapid reversal. The pending-send replay
selects the same directory in two consecutive drafts using Return.

The bottom Overview Dock carries one Stop button while the running Chief's
eyes and capsule move between their compact and input positions. The input
row reserves its measured seat beside Send. Stop is visible while editing
and on hover or focus in the compact capsule. The editor uses its final
width throughout the 420ms motion. Its ink fades in during the last tenth
of expansion and fades out over the same part of the return. Closing ends
editing immediately. See the [Overview Dock replay](../../../../../demos/moku-panel-transition/README.md#overview-dock-replay).

`inputLeaving` keeps the ordinary closing editor mounted for 420ms to retain
its selection. Returning from an Agent conversation to Overview closes the reading
panel's input gate while the workspace still owns the outgoing draft. The
composer and its directory suggestions hide at that point. The shell starts
contracting in its reading column on the same update, easing out over the
420ms return. Route release removes the row without a SwiftUI exit fade. Reopening
restores the active draft and its selection. Talk has independent presentation
and can become readable when input closes. The shell and the single identity
seat move in the same transaction. The editor overlay reserves its final width
and height before the editor mounts. In the wide layout, input ink appears to
the right of the Harness logo after the logo clears the final text seat. Below
260pt of capsule width, text and attachments occupy the row above the identity
and actions. The editor fades in during the last tenth of shell expansion.
Returning reading panels retain their last admitted Dock column through the
return. Resize preserves the native editor and the shell fits the viewport.
The [Agent entrance replay](../../../../../demos/moku-panel-transition/README.md#agent-entrance-replay)
checks the settled text origin, focus and return. The
[Report replay](../../../../../demos/moku-panel-transition/README.md#collapse-replay)
covers the wide and narrow logo clearance and execution-list input gate.

An initialized workspace with no globally eligible, unarchived conversation cards
opens the same Dock at the visual center: 680×76 points, 16-point text and at least
24-point horizontal viewport margins. Moku and its archived history do not count
as ordinary cards. Membership is measured before tags and report coverage,
including documents exposed only inside a directory. Loading is not an empty
workspace. Archiving/deleting the last eligible conversation restores landing;
filtering to no results does not. Landing eligibility does not depend on the
separate [first-run onboarding](../Onboarding/README.md) completion marker.

Landing opens input once on entry. Submitting uses the ordinary sealed-draft
collapse; failure reopens the preserved draft. Escape keeps landing input open;
IME, directory completion and native transient controls retain their cancellation
priority. Input reopening and Stop use the same paths as the bottom Dock.
Outside clicks keep landing input open, including clicks in another window or
app, without consuming the click or losing the draft. Bottom-Dock input still
collapses on outside clicks. Returning from a
covering route or remounting cannot reopen input over a resident or message.
Hydrating a running Moku or waiting message presents that state immediately.
Focus loss, native menus, attachment sheets, modal panels and visible child
windows also retain landing input. Cross-app observers belong only to presented
Talk notifications and retire when the notification hides or the Dock unmounts.

The same persistent capsule and character host own running, thinking, Talk and
dispatch. There is no separate landing notice. A manually opened editor defers
notifications until it closes, without losing its draft. The centered compact
resident eyes and running orbit scale together by 76/58. Expanded landing rows
retain the 680-point composer width and 76-point minimum height.

A durable first-task shell can precede native admission, so it remains behind
landing while `create_thread` is pending. A successful public result for an
eligible Thread returns the same Dock to its bottom seat. Failure without an
admitted conversation stays centered; an independently admitted conversation
also ends landing. Existing workspaces hydrate at the bottom. The same surface
owns the transition.


Directory completion opens above the editor within the same capsule. The editor stays seated at the bottom; scrolling suggestions are clipped to their own area. Selection keys and IME handling use the existing completion state. On macOS, native paste/drop imports files. The Dock and history capsule surfaces have no Moku context menu on right-click or Control-click. An accepted send consumes only its submitted draft revision; failure retains it.

[NativeMokuSubmission](../Shell/NativeMokuSubmission.swift) retains one logical
Moku submission through admission, receipt recovery and persisted draft
consumption. An uncertain retry queries that same receipt;
changed input or a different Report/directory cannot consume the original
submission. Dock, Report and history capture the source when sending. A
successful response retains its receipt until the settled draft and its cleanup
ID are durable. An owner that reopens the draft can finish the matching
acknowledgement even if the original window closed.

An empty or whitespace-only draft without attachments/directories mounts no Send
button or circular background, including in accessibility. Its empty layout seat
keeps the editor width stable. Attachment/directory-only input still exposes Send;
importing, submission and unavailable states retain their ordinary admission rules.
For an active Thread execution, that same seat shows Stop when the draft has no
sendable content and Send when it does. Other composer routes retain their existing
Stop and Send layout.
Moku editors always use the existing shortened, rounded 2.6-point
white core with a warm-yellow upper halo, cool-blue lower halo and blurred
gradient fringe, including on a light system.
The empty placeholder starts three points after the insertion origin.
Composer padding lives inside the native viewport so these halos are not cut at
the text line edges. A 2.4-second breathing cycle replaces native on/off
blinking; white ink uses 20–100% opacity, while its halos fade fully.
Same-line movement remains 120ms and interruptible. IME composition uses the
native caret; line changes stay immediate. Selection and focus/visibility loss
remove the layer and animations.

The empty message editor reads `Type a message…` (Chinese `输入消息…`) across
Overview, landing, Git, Moku history, Agent details and Report execution details.
The placeholder also supplies the editor's accessibility label. Editor help
describes whether the message goes to Moku or directly to the current Thread.
Selected directories are shown as chips. Browser annotation mode supplies its
own editor instructions based on whether a page region is selected.

On macOS, clicking the collapsed Moku row opens input; when a message is visible, only the eyes are the input target so prose remains selectable and controls retain their actions. Clicking the eyes beneath an open note switches to input. Physical two-finger upward swipe opens the note; horizontal swipes do not open input. [NativeMokuSwipe](NativeMokuSwipe.swift) requires a precise phased gesture, threshold and dominant direction, rejects inertia/outside-origin gestures, and respects input/interaction ownership. Its AppKit monitor routes trackpad scroll events; the shared target checks exclude microphone controls and note-reading content. The click entry uses the existing composer focus and draft-restoration path. Note scrolling, Escape, outside click and the close button reuse the ordinary note path without changing the media owner or saved composer restoration state.

Ordinary Talk also admits that upward gesture across the message row. Note
temporarily replaces the message as the capsule's reading surface. A native
viewport with vertical overflow keeps its scrolling ownership, including at either end; the eyes and surrounding
row remain note entry points for a long message. The monitor checks the actual
hit-tested AppKit viewport, so resizing and persistent scroller gutters do not
depend on a predicted text height. Dispatch status is informational; clicking it does not open a detail sheet.

The compact running fallback reuses [MokuRunningStory](../Moku/MokuRunningStory.swift): three rainbow beats, lift, a three-second orbit, landing and recovery, with the eyes following the same clock. The eyes retain their seat while the 5-point dots follow the capsule's outer contour, with 3 points of clear space. [NativeMokuRunningGeometry](NativeMokuRunningGeometry.swift) supplies that authored path to the persistent character host. Decorations paint outside the glass clip.

[NativeMokuCharacterMotion](NativeMokuCharacterMotion.swift) owns one AppKit display link and logical clock for the persistent eye and decoration seats. Ordinary expression changes take 420ms; running/thinking handoffs take 550ms. Interrupted transitions inherit the currently sampled geometry and derivative, without an intermediate idle pose or overlapping eye views. Same-segment text updates do not redirect a role. Inactive, hidden and occluded scenes pause the clock. Blink shape uses the continuous timestamp rather than fixed-rate samples.

Static character targets are cached until their input changes. The native display
link sleeps between blinks (4.2-second period, 0.32-second blink). The
[first-run handoff](../Onboarding/README.md) schedules a single blink on the
mounted face and sets its next idle blink one full period later. App activation,
scene state and the face's AppKit visibility govern that first blink.
Losing eligibility clears it immediately, including
while the display link sleeps. The next idle blink keeps its scheduled time.
One cancellable wake resumes the display link at the next blink. A Harness
identity with no face and no moving decoration has neither frames nor a blink
wake. Role transitions, loading, visible reasoning and retiring ink keep their
frames through the final paint. Resuming starts a fresh wall-time interval, so
sleep cannot advance a new transition. No eye-only correctness suite is configured here.

Talk and live transcript prose use semibold, centered layout.
Symmetric 64-point insets reserve the eye seat without shifting text
away from the capsule center.

Overview derives its persistent bottom reservation from the same idle capsule
geometry. Expanding the composer, note or notification does not change that
reservation or trigger a card repack; those surfaces retain their existing
interaction/overlay ownership.

## Thinking feedback

Moku temporarily hides its live reasoning text Arc. Deep thinking uses the same
three-dot running choreography described above. Live reasoning takes priority over a queued generic tool expression; source
appends do not restart the running clock. Completion, failure,
interruption, waiting for input and runtime disconnect retire loading through
the existing execution and surface ownership state.

The public Harness foreground still supplies
[MokuReasoningContent](../Moku/MokuReasoningContent.swift), identified by Thread,
Harness, execution and foreground sequence with its UTF-16 source offset.
Assistant/tool foreground changes, terminal states and disconnects retire that
live projection. The Arc model, painter and layout exist; the Dock does not
admit or paint their text. Ordinary Agent Thread and Moku history readers own
their trace rendering.

## Talk, dispatch and notes

The expanded note's **Moku history** button opens the existing conversation
reader. It remains available when the note or conversation is empty and supports keyboard and accessibility activation
with localized labels. The Dock measures
the actions; narrower capsules put them in a separate control band. If the full label
cannot fit beside the other control, History becomes an icon with the same
accessible label and help; if even that pair cannot fit, the controls stack.
The note body stays clipped above these rows; its header scrolls with the body
in short viewports, including 5× zoom.
Opening history uses the scene's ordinary navigation path, closing the note
without changing its exposure receipt or the workspace draft.

[NativeMokuTalk](NativeMokuTalk.swift) shows the latest valid `talk` or `create_thread` operation. Talk is selectable text in a four-line viewport with scrolling for overflow. Its trailing control seat stays reserved for the whole message so retiring Stop does not shift centered text or change its wrapping. It does not edit the draft or grab focus. Clicking outside the capsule dismisses the presented notification without consuming the click, including clicks in another window or app; clicks and scrolling inside retain it. The cross-app mouse observer is removed when the notification is hidden or the Dock unmounts. Dismissed/presented operation identity survives refresh and remount within its scene; a notification covered before presentation waits until it can actually be shown.

Talk uses symmetric 64-point insets around its centered selectable text viewport,
reserving the persistent eye/control seats without shifting prose. No Talk clipping/transcript
correctness suite is configured in this source tree.

The
capsule height uses the same width; changing the scrollbar preference updates
both without replacing the scroll view. The production selectable text uses
the native clip/scroller boundary for mixed Unicode and overflowing content.
The native viewport also stays inside its promised host bounds: the prose width
is a maximum inside a flexible, leading-aligned document, so persistent scrollers
cannot expand it into the note's history actions.


Text shorter than the Talk viewport is vertically centered in its row.
The Dock's Stop
square is revealed by pointer hover, keyboard focus or VoiceOver focus and fades
out otherwise. The Button itself stays in the accessibility tree, while pointer
hit testing follows the visual state so an invisible square cannot be clicked.
Running messages reserve a 48-point trailing inset even before hover/focus,
keeping text and dispatch content clear of the 30-point Stop target and its
7-point edge inset. Revealing the square therefore does not rewrap the message.
This is cancellation (`moku:cancel`), with no pause/resume action. Composer Stop
shares the Send seat for an active Thread execution; other composer routes retain
their separate Stop item. Blink/cloud clock pauses are animation lifecycle state,
not message-bar controls.

Dispatch notifications (pending, started or failed) expire 10 seconds after their
first actual presentation; ordinary Talk notifications retain their 60-second
timeout. Both use a monotonic deadline retained by the scene. Refreshes and
in-place operation updates do not extend it; a replacement operation gets its
own full interval. The Dock's
deadline task is cancelled on replacement, dismissal or unmount and checks the
captured operation identity before expiry.

[NativeMokuDispatch](NativeMokuDispatch.swift) projects the same operation while pending and settled. Success requires `completedAt`, no error, `ok:true` and a nonempty `threadId`; it confirms dispatch, not task completion. The 400×58-point layout contracts for narrow viewports. Configuration comes from that call's arguments. The notification is informational and does not open a detail sheet.

The notification first fits the complete status and configuration on one line.
When their intrinsic width exceeds the available content seat, configuration
moves below status inside a 32-point row, without changing capsule dimensions,
eye placement or the 48-point trailing control reservation. Model and thinking
use 11-point text with no fixed configuration width. The model keeps its exact
identifier across Codex, Claude, Pi and OpenCode; there are no display aliases
or provider-prefix stripping. Thinking retains the requested effort or mode
(`on`, `off`, `fixed`), with no inferred defaults. Only an overlong model on the
second line truncates in the middle; thinking has higher layout priority, and
extreme widths can still truncate either field. Hover help and accessibility
retain the complete configuration. Provider remains separate from model identity
in the stored operation; the notification has no clickable detail sheet.

The selected Harness is the single key in `arguments.target`, with its native
fields nested under that key. Empty, ambiguous or non-object selections do not
produce a dispatch projection. Empty native option objects remain visible so
rejected requests can still show their outcome. Catalog audit previews preserve that identity
and only `model`, `provider`, `thinking.mode` and `thinking.effort`, with each
display string capped at 256 code points; oversized target keys are omitted
instead of changing their identity. Other native options are not forwarded to
the catalog. The full stored operation retains the caller's original request.

[NativeMokuNote](NativeMokuNote.swift) reads the persisted note and expands the same capsule, up to 560 points wide and bounded by the viewport with 24-point side margins. Markdown is read-only/selectable, with a fixed header and scrollable body. When the available note height is too short to show a complete body line below that header, the header scrolls with the body instead; the supported 5× app zoom therefore retains a usable reading viewport. The catalog's `lastExposure` is the only authority for the accessibility update indicator. Opening the panel does not acknowledge it. A user-opened panel or later body interaction can start a reading session; the production renderer must apply the exact note token, the key foreground window must remain visible, and each actual body viewport interval must stay stable for two seconds. Only complete coverage submits an authenticated receipt. Qualification compares the rendered document with the scroll viewport, so the gutter a persistent legacy scroller reserves is layout rather than horizontal overflow; content that actually exceeds the viewport still stays unqualified. Code, tables, images and local-file previews stay unknown in this first version. Each mounted window owns its partial coverage; failed receipts remain pending for a later same-version UI activity, with no optimistic indicator change.

Coverage retains the union of settled ranges, so revisiting text does not accumulate duplicate intervals. Disconnect cancels the in-flight submission while retaining at most one completed receipt. Snapshot rehydration reconciles that receipt against the exact catalog incarnation/version before retrying; a new version, cleared note or released workspace discards it.

The fixed-header versus scrolling-header layout depends on the Dock's available
viewport height, independently of the document's fitted height. An initially
empty Markdown layout must not replace the scroll container when parsing
finishes: replacing it retires the mounted renderer and its armed read session.

Input/permission interactions take precedence over the note; leaving Overview or opening another covering route closes it. Escape, outside click, the close button and the note command dismiss it. The macOS note command is `Cmd+Shift+N` when the Dock is available.

Talk and Note take turns owning the same reading surface. Opening first fades
message ink in place over 100ms, expands the single glass shell with the existing
420ms geometry curve, then fades Note and History in over 120ms. Closing reverses
that sequence. The footer retains History/Stop actions; Note prose never travels through a visible Talk row. The message's native
viewport remains mounted with its ordinary 48-point control inset, preserving
wrapping and scroll state while hidden.

A generation fences each animation completion, so a rapid reversal cannot finish
an older intent. Input, covering routes and inactive/hidden scenes
settle the current target immediately. Hidden/retiring text and History cannot
receive pointer or accessibility activation. Note gains interaction and reading
exposure eligibility only after its entrance completes; a close intent revokes
both immediately. Its native viewport claims a user-open arm when eligible,
including a quick reopen that retained the same renderer. Escape, outside click
and the existing input command remain available during the handoff.

Covering a notification with Note does not consume it. An already presented
Talk keeps its original deadline and can expire while covered; a new operation
received inside Note starts its deadline only when it becomes visible on return.
The latest scene-owned message supplies that return, with no snapshot or cached
message to resurrect. Text selection, scrolling, composer drafts and note data
retain their existing owners. See the [same-level handoff contract](../../../../../design/composer.md)
for the current Talk/Note ownership contract.

Expanded Note uses dark Regular Liquid Glass without the compact clear shell's
bottom-fading gradient; the expanded material is noninteractive;
selection, links, scrolling and dismissal retain their existing targets. The
material stays mounted through opening, closing and reversal. Reduce Transparency retains the
same opaque warm-black fallback. No Note lifecycle/viewport regression runner is configured here.
The [Note transition preview](../../../../../demos/moku-note-transition/README.md)
records the production Dock with synthetic notes, including intermediate frames,
rapid reversals, narrow/centered layouts and a local no-animation fixture.

Switching the coordinating Harness retains the previous native conversation as a read-only Moku history session. The desktop history panel opens the current session. Runtime prevents archive reactivation, fork and execution of previous sessions, while keeping attachment ownership until an explicit Moku history reset removes current and previous sessions.

Note Markdown accepts app-internal execution links in the form
`[label](mokusei://execution?threadId=THREAD_ID&executionId=EXECUTION_ID)`. The note
forwards a validated typed reference to the Host; other Markdown surfaces do not
open these links and they are never handed to the OS. Only ordinary public
Agent Threads qualify, including archived, failed and interrupted ones. Moku,
its history and missing/private targets produce an unavailable notice. The note
retains its existing character budget and viewport-exposure semantics.

Note execution references use a clear Liquid Glass capsule with
its owning Harness's native logo and a trailing up-right arrow. There is no
hover scale or interactive glass response. Ordinary links keep their existing
purple underline. The note observes public catalog membership and uses the
registered plugin logo; missing/loading metadata and unregistered Harnesses use
a neutral execution symbol, then update in place when metadata arrives. Private
Moku/history targets never receive an ordinary Harness brand. Decoration does
not replace the existing exact-execution route or its admission checks.

The native Markdown renderer reserves a width-bounded attachment seat for each
execution reference and hosts a live glass surface in that seat. Long titles
wrap inside the capsule, while surrounding prose remains TextKit text. Selection
and copying preserve the full title, without inserting a logo/arrow into copied
content. Pointer events remain with TextKit for drag selection, and the hosted
control supplies named keyboard/accessibility activation.

Pointer and accessibility activation dispatch the same exact execution reference.
The Dock closes the Note and retains its reading position. Once the Note has
closed, Overview reveals the destination in its filter and, for a grouped Report,
on its Collection page. The settled Overview card supplies the reader’s origin.
A unique Super Thread owner opens its Report with the cited execution selected
in Related executions. Other links open the ordinary Agent reader, including
eligible Threads hidden from Overview. Both readers start at the cited run’s
heading, with output following off. The visit stays on that execution after a
successor starts.

Closing either expanded reader, clicking its backdrop or using the Overview
command returns to Overview with the Note closed. Only an explicit Back to the
Note restores its retained viewport. Escape in the ordinary cited document
performs that Back action. In the Report, the sidebar arrow restores the related
list, where the Report arrow returns to the Note.
The closed Note remains ineligible for input, accessibility and exposure.

## Settings expansion

Settings expands from the resident Dock's existing capsule, with a stable
viewport-bounded centered surface with a 780-point preferred width and a
900-point minimum preferred height that grows with its active form. Its full
panel uses the opaque adaptive Settings fill and a subtle border, without Liquid
Glass. Its header has no character or reserved eye slot. The other Dock surfaces
retain their Harness tint and anchors.
The scene blurs and disables Overview, while the capsule and retained input/Note
visit stay mounted. Closing uses the Settings draft gate and restores the
previous valid surface; pending interventions resume only after Settings exits.
Only loaded Overview admits Settings, including menu and semantic entry points.

## Immediate Timer

`timer(text)` uses the same completed tool-operation audit path as Talk, with
its own workspace-owned [controller and audio port](NativeMokuTimer.swift).
Only completed `timer` rows with `result.ok:true`, no error and valid text enter
the FIFO. Identity includes owner, Harness, execution and operation ID, so
repeated snapshots and a delayed double click cannot replay or acknowledge a
successor. Equal text in separate successful calls remains separate messages.
Ordinary Talk keeps its existing silent, latest-only, 60-second presentation.

[NativeMokuTimerBar](NativeMokuTimerBar.swift) reserves a small seat above the
current workspace route with the complete scrollable text,
a queue count and an always-present **已收到 / Received** button. It does not
navigate, replace the editor, grab focus or close permission surfaces. Its click region is excluded from composer outside-click dismissal. It has no
Escape, outside-click, focus-loss or timeout acknowledgment. Native text/buttons expose the
content and action to accessibility; acknowledgment does not require audio.
Like the other Moku surfaces, the Timer bar uses a local dark environment even
in a light workspace; it does not override the window appearance.

The model owns the controller across scene and route remounts, including UI
reload. Its first installed snapshot establishes a silent history baseline;
completed rows in that snapshot are not new messages. Pending operations can
still complete afterward. Subsequent snapshots enqueue unseen completed rows,
including the bounded cross-execution catch-up tail. A disconnect retains the
already received queue and loop; local acknowledgment remains usable offline.
A successful tool call while no client is running is not guaranteed delivery.
Long gaps beyond the 256-row tail, history clearing and owner replacement can
lose unseen events. There is no exactly-once guarantee across clients or app
restarts: each workspace owns its queue, seen identities and acknowledgments in
memory. Restart discards them and baselines the initial restored history; a stale
reading cache followed by fresher hydration can expose other unseen operations.
This is intentionally not a reliable persistent alarm/reminder service.

The production player lazily loads macOS `Glass.aiff` through `NSSound`, loops
one shared bell while the queue is nonempty, and never alters system volume.
Acknowledging the last item stops it; workspace shutdown stops
it before asynchronous runtime cleanup, and process exit ends playback.
Playback failure keeps the message and receipt button visible, reports the error
in the bar and offers an explicit retry. Muted devices, output routing, sleep,
OS audio interruption and actual audibility remain outside headless coverage.

They do not certify rendered animation frames, keyboard focus,
sound output or real VoiceOver operation. Those require explicit interactive acceptance; do not open windows or play the
production bell during headless verification.

## Reading-panel Dock

Browser annotation mode temporarily lends the resident composer to the selected
Browser card. The same native destination marker and travel host center it below that
card, fitting its column. Page focus remains with selection until an element or
region is chosen, then the text editor receives focus. A separate ephemeral text
draft describes that selection; normal Thread and Moku drafts remain retained.
Return/Send captures and submits the annotation through Browser's existing
attachment/send route. Escape, the accessible Cancel annotation control and the
Browser toolbar cancel only this mode. Switching/folding cards, page navigation,
covering or closing returns to the ordinary draft and send route. Annotation
input admits text without file or directory controls. Failed capture
keeps the description; failed sends keep the captured batch for the existing
retry/text-only controls. See the
[annotation input contract](../../../../../design/composer.md).

While the selected Sidecard owns the current running/waiting execution, the
resident input is centered below that panel and fits its width with the ordinary
24pt horizontal insets and 560pt cap. Its reading baseline stays fixed. The
Sidecard host publishes destination bounds through passive native layout markers;
the bridge converts across the reading panel's separate `NSHostingView` into
scene coordinates. Publications wait for layout and carry Thread identity, so a
retiring reader cannot position another Thread's input. The native marker stays
at the workspace origin and carries the target's local rectangle explicitly;
equal-width column switches therefore do not depend on a native frame-change
notification from a SwiftUI ancestor transform. The same editor, draft,
selection and input actions remain mounted.
Selecting Browser (or another non-owning activity) instead centers input
below the main reading panel and fits that panel's width, including when the
Thread's latest execution has finished. Input still sends to the same Thread;
opening an activity does not make that activity its target. Folding the selected
card, suppression, losing the selected card's eligibility or starting completion
promotion restores the workspace-centered input. A first execution in main with
no expanded activity does not move it. Horizontal travel into a target column
uses the existing monotone native easing for every distance: 380ms for a changed
column frame, otherwise 420ms. The compositor moves directly from the current
presentation position to the target, without overshoot or a settling rebound. Vertical
descent retains its independent, non-bouncing timing. Shell sizing retains the
Sidecard's 380ms curve; divider dragging and window/zoom resizing settle without
travel. Stacked layouts share the
panels' full column width and keep the same bottom reading baseline. Composer
expansion retains its separate entrance timing.

The Scene keeps the complete Dock in one persistent native hosting tree. Its
native outer layer owns horizontal travel. The native host moves to the target
column in the same transaction that starts compositor travel. The source
correction holds through the first compositor sample. Its editor,
controls and glass travel together even while the main thread prepares content.
Reversal starts at the current presentation position. Completion is fenced to
the current native animation, placement revision and composer generation;
resizing settles immediately. Keyboard focus survives travel,
while coordinate-based pointer hits wait for arrival so they cannot activate a
control at its invisible destination.

Switching columns can also change input width. The editor adopts that width
once, inside its own geometry group, while the shell retains its existing size
and vertical animation. The complete Dock owns its state and geometry within
one hosting tree, including Settings height preferences and input hit regions.
The hosting root stays fixed while observable content carries outer updates;
replacing the root can settle the shell before its content finishes moving.

Native compositor travel is distinct from full-workspace frame pacing, GPU
or energy measurements.

Primary reading entry lowers the collapsed Dock with its native 420ms
ease-in/ease-out curve. Its composer stays unmounted until the reading panel/title handoff
finishes and the main document is ready, then the folded Agent workspace
commits. That visit-scoped boundary admits the Sidecard reveal (380ms). If its
execution column owns the Dock, the compact Moku travels there first; the actual
horizontal animation's final completion then admits the
Harness flip and subsequent input expansion (420ms each).
The native geometry bridge fences completion to the current destination revision,
and the workspace retains the existing route-visit admission check. A folded,
ineligible or absent execution Sidecard releases the identity stage at layout commit without
a travel wait. Once input is admitted, later card choices move the retained editor
without folding it. Direct resizing settles without a delay.
Scene-level input admission also gates interaction restoration,
input controls and focus; navigation cannot bypass it by reconfiguring the draft.
Within an admitted Agent reader, TOC selection and Back replace the editor's
draft without folding the pinned shell or readmitting its settled Harness mark.
Input readiness still follows the selected document.
Automatic focus follows the current composer visit's ink reveal. The Dock
requests focus when the reveal reaches 10% opacity. Admitted click and Tab
focus remain available during opening. Cmd+Shift+B explicitly focuses a pinned Agent editor after TOC navigation,
without changing its draft, send generation or suppressed automatic-focus policy;
accepted Close suspends input hit testing/focus as the shell folds. The fitted Dock
bottom moves down by up to 16pt, keeping at least
12pt below it; Super Thread admits the expanded composer only for a selected
associated Thread; Git retains its normal input policy in that same lower seat.
Landing and Settings keep their existing positions. The bottom-anchored editor,
reasoning envelope and hit regions still use the fitted surface. See the
[reading choreography](../../../../../design/reading.md).

The same resident Dock remains mounted and interactive while an ordinary Agent
Thread, Report or Git detail is presented in a reading panel. `dockRouteVisible` combines Overview and
reading-panel eligibility without admitting Settings or Note on a reading route.
The composer, Talk and pending interventions use that shared eligibility; other
application pages and covering routes still hide the Dock. Returning to Overview publishes eligibility in an order that retains native
input/hit-region ownership. Agent detail keeps its input expanded. Its leading
identity seat reveals the actual Harness plugin's native logo, which remains
visible while typing.
The host resolves the current target's `harnessID` on each render, including target
changes; unknown/empty IDs use a neutral terminal mark, never Moku's Harness.
Registered custom Harnesses supply their own mark through the same registry.
The passive logo occupies a 34×25pt seat only in Agent input and ignores pointer
and accessibility hit testing. A 420ms horizontal-axis flip retires the old mark
in its first half and reveals the new mark in its second half. Changing Harness
flips to the new mark; changing Threads within the same Harness keeps it steady.
Overview and Report/Git restore Moku's theme without a logo; Settings has no header identity slot. Identity transitions use SwiftUI's retained views,
without delayed callbacks that could restore a stale Harness or acquire focus.
The logo is separate from placeholder/draft text and never replaces the editor.
The window owns persisted drafts (text, directory mentions and attachments) per
Thread for ordinary current input and per exact Thread/execution for fixed
history/result input, separately from Moku history/Overview. Agent and Report
readers share `NativeExecutionContinuation`: latest input follows up on its
original Thread, while historical input forks at the native checkpoint before
following up on the admitted branch. The source identity is captured before
the first suspension. Runtime chooses steer or a successor execution for a
latest follow-up. Stop uses the viewed current execution's cancellation identity.
Unavailable Threads and read-only Moku histories cannot send. Ordinary Thread
archive only changes list visibility and does not disable sends. Failed sends keep their draft and error;
late receipts consume only their original draft and cannot reopen another visit.
Retiring composer callbacks may refresh the capsule's retained text, directories
and attachment ink only while they still own its selected draft. A Thread title
or execution change keeps that Thread's unsent draft. See the
[draft and attachment contract](../../../../../design/composer.md)
for the distinction between restored input and cross-Thread routing defects.
The local send publishes a visit-scoped reveal request before admission, then
attaches the exact execution receipt. Conversation opens once that same execution
is observed running/waiting and qualifies for its Sidecard. A receipt alone cannot
open it. Card choices, navigation, suppression and failed admission retire the
request; a fresh send may reveal again even when steering the same execution.
Navigation resets retained editor ink, selection and completion ownership before
admitting the replacement draft. Returning to Overview, Git or Moku history restores the existing Moku send route.
An unselected Super Thread keeps the resident Moku capsule compact and denies
input expansion. No Overview card send entrance is added.

Agent detail pins the composer open: Escape, outside clicks, the input toggle
and successful sends cannot fold it. The editor's Escape callback closes the
current detail through its existing reading motion, fenced to that route/target;
the Dock's native fallback uses the same callback after focus moves to its controls.
Reading/document/Sidecard Escape skips resident-input folding and retains its own
nested cancellation order. An ordinary click in the blank panel margin closes
that detail on the first completed press; clicking inside the reader, Sidecards,
capsule or directory candidates retains their normal interaction.

IME marked text, directory completion, native menus, sheets, popovers and explicit
control cancellation retain priority. Escape closes directory completion first;
in Agent detail an outside press also dismisses completion first without folding
the editor or closing the reader. Native transient/IME-owned presses are recorded
before delivery so mouse-up cannot close the reading panel after AppKit commits a
mark or removes a popup. The window-sharing indicator can stay visible while
the reader handles a blank-margin click or the composer handles Escape. Only
child windows that can take keyboard focus claim those actions.
Existing Moku interventions/covering routes keep their surface priority and release
the Agent editor afterward; its draft remains owned by the same Thread.
Execution Sidecards stay usable
beside the open composer and own no text/attachment input.

Overview, landing, Git and Moku history retain their existing input and
cancellation policies. Closing detail or changing targets retains unsent text,
attachments and directories through the window-owned persisted Thread draft.
Sending still consumes only the accepted revision; failed sends retain the draft
and error, and late receipts cannot alter another target's presentation.
See the [composer routing contract](../../../../../design/composer.md).

Report execution details borrow that same Agent composer and native column
placement. Exact-execution drafts are shared with Agent history/result readers
for the same Thread/execution pair. The editor opens after its horizontal travel
settles. Returning to the list, folding, Browser selection or departure
restores Moku and retains the draft;
editor Escape follows Report's auxiliary Back. Only the viewed current active
execution exposes Stop; historical input cannot stop a newer execution. The shared sender uses the existing expected-execution admission fence. An
explicit pre-admission `EXECUTION_CHANGED` rejection takes the historical fork
path once; uncertain writes are never automatically resent. A failed follow-up
retains both the exact draft and its admitted fork for review across these readers. Successful exact sends open the accepted Agent execution
after catalog admission, fenced to the owning route/composer visit. Ordinary
current sends keep their existing visit-scoped execution reveal. TOC selection changes drafts without acquiring editor focus. Initial input,
explicit Browser annotation mode and Moku retain their existing autofocus. Pending focus requests wait for editor eligibility and are applied once, so an
unavailable first render cannot lose the request and later availability cannot
repeatedly steal the reader's focus. See the
[focus ownership contract](../../../../../design/composer.md). Execution completion lends input publication only to the current native reader
seat. The retained outgoing reader cannot overwrite or clear that target, and
canceling a handoff republishes the restored reader's target. The workspace
withdraws its input owner when it leaves, independently of either reader's
teardown. Each continuation phase retains its original source, input, destination and
command ID. During Send, a confirmed fork transfers its durable receipt to
the first follow-up in one journal transaction before dispatch. After a lost
response, Check previous receipt only reads the identified command. If the
fork exists and its input was never accepted, the composer keeps its protected
receipt until the user chooses Restore to draft or Keep next draft. Either
decision releases the barrier and lets the user continue in the created branch.
A confirmed final send consumes its own draft and leaves the successor intact.
The saved successor records the receipt until journal cleanup has completed,
including when the original owner closes. This policy is
shared by Report and Agent input; there is no force-resend button. See [Execution continuation](../../../../../design/reading.md)
for native constraints and evidence limits.

Direct Thread sends admit three-dot orbit feedback as soon as the Dock captures
the submission. Open input hides the orbit, including retiring dot ink; closing
input reveals applicable pending/running feedback without waiting for the
retained editor to unmount. The pinned editor keeps its own Send/Stop controls.
Agent detail's persistent input suppresses this feedback for its whole ownership
lifetime, including reading travel and the Harness flip before input opens.
Entry, replacement and return therefore cannot mistake delayed editor admission
for a user-closed input or reveal retained orbit ink. Ordinary closed-input
running/submission feedback and the running story remain unchanged. See the
[composer admission contract](../../../../../design/composer.md).
This feedback skips
the running choreography's initial three-beat prelude; it does not grant Stop
authority, consume a draft or navigate before a confirmed receipt. Failure or
an unresolved receipt retires submission feedback and leaves the existing draft
and error/recovery path intact. Accepted continuation keeps its pending feedback
while waiting for a new Thread's catalog event. Confirmed execution activity can continue the
same orbit clock; unrelated Moku execution updates cannot restart it.

An accepted exact-execution continuation retains the previous Dock column,
expanded shell and Harness logo seat while its new reading visit prepares. Native column
markers belong to a route and publish only after auxiliary layout admission;
retained outgoing Report markers cannot overwrite the destination. The Dock
travels directly to that committed column with monotone easing, without
adding an intermediate layout destination. Replacements use
the currently presented horizontal position; resize, dragging and deactivation
settle travel directly. This preserves the existing draft,
receipt, input-readiness and late-callback fences. See the
[composer geometry contract](../../../../../design/composer.md).

The [Host receipt replay](../../../../../demos/moku-panel-transition/README.md#host-receipt-replay)
exercises the production client transport and journal with fixture outcomes.
The [composer ownership guide](../../../../../design/composer.md) describes
the implemented admission and cancellation boundaries.

Settings starts with a 900-point preferred height and grows to the active tab's
natural document height (including header and form insets). The shared Dock shell
keeps its 780-point preferred width and caps both dimensions to the workspace
viewport with 24-point margins. General, Moku, Tag and Report use this same sizing,
including inherited and independent Harness forms. Smaller windows, app zoom,
expanded editors and notices retain native scrolling; extreme zoom also scrolls
the whole shell so navigation remains accessible. No scrollbar is hidden to fit
content.

Super Thread document/list state does not admit Moku input. The shared scene
admission gate blocks capsule clicks, Compose menu/shortcut actions, scripted
toggles and direct open requests; its compact capsule exposes no input launcher
or hint. Selecting an associated execution still borrows and pins the ordinary
Agent composer after reading/content admission, with its existing historical
continuation, Stop authority and receipt handling. Returning to the list, folding
or replacing the associated reader immediately retires input, including pending
focus work. Escape retains the report's auxiliary Back or normal close; IME,
completions and covering routes keep their existing precedence. Overview and
exact-execution drafts retain their existing storage identities. No associated
Agent receives unselected input.


## E2E contract

[`E2E-COMPOSER-001`](../../../../../tools/e2e/README.md#composer-system-input-boundary)
uses real system text input and the mounted `moku-send` / `moku-stop` controls in
an isolated ordinary Agent Thread. The operator observes the selected Thread,
typed draft, Send, consumed draft and visible completed reply. A second typed
input holds the real Codex execution at the external model-service boundary;
its empty composer must expose Stop in the same reader visit. Clicking Stop
interrupts that exact execution, removes the Stop action and leaves the editor
usable. This is cancellation, with no pause/resume contract.

The Dock retains its selected Thread as an observable snapshot, refreshed by
normal catalog/presence events. Its running/finished action seat therefore updates
without requiring a route change; unrelated indexed catalog reads remain quiet.
The current Thread's empty input shows Stop while active, and nonempty input
shows Send in that same seat. Existing source/draft ownership and exact-execution
admission still govern the action.

Preconditions are an exclusively scheduled desktop, current checked production
artifacts, a unique test App/profile, real native Codex discovery and a system
input operator with Accessibility access. The runner checks exact persisted user
prompts, completed output, mounted execution identity and `interrupted` public
state; `operator-send/stop.json` records actual AX observations and confirmation
of the clicks. Those receipts are operator attestations, not unattended AX
capture. Missing receipts or controls cannot pass. Report/source/manifest and
cleanup records bind every attempt to its implementation and retained evidence.

This scenario is operator-assisted and is not run by the hosted workflow. It
covers ordinary current-Thread text submission and cancellation only. It does
not certify IME, attachments, historical forks, Report input, Moku-wide cancel,
uncertain receipts, restart recovery or real external-provider behavior. Runtime
invariants remain PBT's responsibility; latency and animation quality belong to
benchmarks. A scenario definition is not evidence that a particular commit ran.
