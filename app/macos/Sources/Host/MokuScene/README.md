# Moku presentation

[NativeMokuWorkspacePresentation](NativeMokuWorkspacePresentation.swift) derives the current Moku execution's display from public transcript operations. [NativeMokuSceneState](NativeMokuSceneState.swift) owns transient presentation and dismissal. The [Go coordinator](../../../../../internal/services/moku/README.md) owns task admission, tool results, notes and voice routing.

Question choices use the full visible rounded rectangle as their button hit
shape, including padding and the empty space beside the answer text.

Settings uses the SwiftUI [reveal overlay](../Settings/NativeSettingsTransition.swift)
inside the persistent scene. Scene state retains Settings through return and
reports its transition lifetime; the overlay owns animation completion and
settling, without restoring the retired AppKit scene host.
The Settings content suppresses inherited animation only for changes to the
expanded state, so its final layout remains stable during the shell morph while
subsequent child-owned animations retain their own transactions.

## Dock and composer

Moku always uses its existing dark appearance, independently of the system and
workspace appearance preference. This covers the Dock (idle, landing, composer,
Talk, dispatch and note), interaction panel, dispatch details, and the current and
archived Moku conversation reader with its history composer. The override is a
local SwiftUI environment, not a window/application appearance preference.
The Settings page and its regular-glass shell retain the workspace appearance
even while expanded inside the Dock. Overview, ordinary Agent Threads, onboarding,
Browser/Report surfaces and Report Agent's generated-document requirements keep
their existing appearance ownership.

All Moku capsule surfaces use the approved warm-black gradient over native clear
glass, fading toward the bottom with a fine warm edge. Production density is 85%.
Reduce Transparency uses the existing opaque warm-black fill. Content ink, eyes,
voice cloud and reasoning feedback use their existing dark palette. Overview's
expanded search carrier reuses the same gradient and local dark appearance
([shared material](NativeMokuCapsule.swift)), including its caret.
The material does not change layout, clipping, voice ownership or motion clocks.
The historical [material demo](../../../../../demos/moku-gradient-material/README.md)
compiles this production material; its old light/dark comparison is no longer a
product contract. No light-cursor demo is part of this implementation.
Material validation includes [glass-world captures](../../../../../tools/verification/overview-input/README.md#glass-world-live-changes-and-fixed-production-captures)
for both appearances, the mounted history composer/note suites, and the native
Talk, character-transition and voice-cloud replays described below.

The shared input row places the attachment plus between Moku's eyes and the editor. It reuses the workspace draft's device file chooser; hosts with file browsing also offer host files and directories through the existing picker. The control has a localized help/accessibility label and is disabled while attachment import or the owning surface is unavailable.

[NativeMokuDock](NativeMokuDock.swift) uses one native glass capsule with a bottom-center anchor. Idle size is 168×44 points; expanded width is bounded to 560 points and the available viewport. [NativeMokuComposer](NativeMokuComposer.swift) shares the input row between the Dock and history. History stays expanded and keeps the same workspace-owned draft, attachment services, voice client and send callback. Collapsing and reopening the Dock input restores the caret/selection saved while it was open; the first open keeps the existing autofocus behavior. Both surfaces expose an execution-fenced Stop action while Moku is running; voice controls retain their separate media semantics. A normal click can acquire the native editor without being undone by a delayed SwiftUI focus report.

The eyes retain the last open editor seat while the composer retires. Geometry
reported by the shrinking, read-only composer cannot move that seat; reopening
resumes live editor measurements. The Dock mounts directory completion above
the input as a separate overlay,
sharing its menu chrome with the history composer. Its measured target height
expands the shell without inserting rows into the editor's own layout. The
editor and the single persistent eye seat therefore share the shell's bottom
edge throughout the animation. The eye inset uses the input row's local height
and the error footer's height; it does not resolve an anchor through animated
ancestors, which would feed the shell's transient translation back into the face.
The native transition replay checks the mounted eye seat's window-space trajectory through full and
interrupted input transitions, plus its alignment with the actual editor during
menu opening, filtering, Escape and rapid reversal in bottom and landing layouts.

An initialized workspace with no globally eligible, unarchived conversation cards
opens the same Dock at the visual center: 680×76 points, 16-point text and at least
24-point horizontal viewport margins. Moku and its archived history do not count
as ordinary cards. Membership is measured before tags, search and report coverage,
including documents exposed only inside a directory. Loading is not an empty
workspace. Archiving/deleting the last eligible conversation restores landing;
filtering to no results does not. Landing eligibility does not depend on the
separate [first-run onboarding](../Onboarding/README.md) completion marker.

Landing opens input once on entry. Submitting uses the ordinary sealed-draft
collapse; failure reopens the preserved draft. Escape, input reopening and Stop
use the same paths as the bottom Dock. Outside clicks keep landing input open,
including clicks in another window or app, without consuming the click or losing
the draft. Bottom-Dock input still collapses on outside clicks. Returning from a
covering route or remounting cannot reopen input over a resident or message.
Hydrating a running Moku or waiting message presents that state immediately.
Focus loss, native menus, attachment sheets, modal panels and visible child
windows also retain landing input. Cross-app observers belong only to presented
Talk notifications and retire when the notification hides or the Dock unmounts.

The same persistent capsule and character host own running, thinking, Talk and
dispatch. There is no separate landing notice. A manually opened editor defers
notifications until it closes, without losing its draft. The centered compact
resident, eyes and running orbit scale together by 76/58. Expanded landing rows
retain the 680-point composer width and 76-point minimum height.

A durable first-task shell can precede native admission, so it remains behind
landing while `create_thread` is pending. A successful public result for an
eligible Thread returns the same Dock to its bottom seat. Failure without an
admitted conversation stays centered; an independently admitted conversation
also ends landing. Existing workspaces hydrate at the bottom. The same surface
and Reduce Motion policy own the transition.

The [native landing replay](../../../../../tools/verification/reading-presentation/README.md#empty-workspace-and-first-dispatch)
exercises real workspace/catalog/presentation integration; the
[interactive visual fixture](../../../../../demos/moku-landing/README.md) retains the
approved appearance and editor checks without a live Runtime.

Directory completion opens above the editor within the same capsule. The editor stays seated at the bottom; scrolling suggestions are clipped to their own area. Selection keys and IME handling use the existing completion state. On macOS, native paste/drop imports files. The Dock and history capsule surfaces have no Moku context menu on right-click or Control-click. Native text editing menus and the voice control's own menu remain available. An accepted send consumes only its submitted draft revision; failure retains it.

An empty or whitespace-only draft without attachments/directories mounts no Send
button or circular background, including in accessibility. Its empty layout seat
keeps the editor width stable. Attachment/directory-only input still exposes Send;
importing, submission and unavailable states retain their ordinary admission rules.
Moku editors always use the existing shortened, rounded 2.6-point
white core with a warm-yellow upper halo, cool-blue lower halo and blurred
gradient fringe, including on a light system.
The empty placeholder starts three points after the insertion origin.
Composer padding lives inside the native viewport so these halos are not cut at
the text line edges. A 2.4-second breathing cycle replaces native on/off
blinking; white ink uses 20–100% opacity, while its halos fade fully.
Same-line movement remains 120ms and interruptible. IME composition uses the
native caret; line changes stay immediate. Selection and focus/visibility loss
remove the layer and animations. Reduce Motion keeps the caret steady and makes
movement immediate.

Run the [windowless appearance replay](../../../../../tools/verification/moku-appearance/README.md)
when changing these appearance boundaries. It checks production AppKit/SwiftUI
components without opening a window; it does not certify on-screen glass pixels.

The Dock and history input placeholder follows the displayed directory tags, including the retained draft during Dock dismissal. With no directory it reads `Ask Moku… or hold to speak` (Chinese: `向 Moku 提问，或长按说话…`); selected directories retain `Ask Moku about <name>…` with `or hold to speak` appended (Chinese: `向 Moku 询问关于 <name> 的问题，或长按说话…`). Two directories show both names joined by `and` / `和`; three or more show the first name and the remaining count (`<name> and N other directories` / `<name> 等 N 个目录`, with the Chinese count including all selected directories).

On macOS, clicking the collapsed Moku row opens input; when a message is visible, only the eyes are the input target so prose remains selectable and controls retain their actions. Clicking the retained row beneath an open note switches to input. Physical two-finger upward swipe opens the note; horizontal swipes do not open input. [NativeMokuSwipe](NativeMokuSwipe.swift) requires a precise phased gesture, threshold and dominant direction, rejects inertia/outside-origin gestures, and respects input/voice/interaction ownership. The click entry uses the existing composer focus and draft-restoration path. Voice mode allows the same upward note gesture on the retained Moku row (only the eyes when a transcript/notification is visible), excluding the measured voice control bounds. Clicking Moku cannot open the composer during voice. Note scrolling, Escape, outside click and the close button reuse the ordinary note path without changing the media owner or saved composer restoration state.

The compact running fallback reuses [MokuRunningStory](../Moku/MokuRunningStory.swift): three rainbow beats, lift, a three-second orbit, landing and recovery, with the eyes following the same clock. The choreography comes from Bart commits `2c3125ac7` and `45578f321`; the eyes retain their seat while the 5-point dots follow the capsule's outer contour, with 3 points of clear space. [NativeMokuRunningGeometry](NativeMokuRunningEyes.swift) shares that authored path between the persistent character host and the standalone reference. Decorations paint outside the glass clip. Input, note, tool, message, interaction and voice ownership retire the running decoration through the same host rather than replacing the eye view.

[NativeMokuCharacterMotion](NativeMokuCharacterMotion.swift) owns one AppKit display link and logical clock for the persistent eye and decoration seats. Ordinary expression changes take 420ms; running/thinking handoffs take 550ms. Interrupted transitions inherit the currently sampled geometry and derivative, without an intermediate idle pose or overlapping eye views. Same-segment text updates do not redirect a role. Inactive, hidden and occluded scenes pause the clock; Reduce Motion snaps to static open eyes and static running dots. Blink shape uses the continuous timestamp rather than fixed-rate samples. The production transition replay checks rapid redirection, persistent eye identity, text-clock continuity, viewport fitting and retirement; the existing blink replay retains natural-blink and running-orbit pixel coverage.

Overview derives its persistent bottom reservation from the same idle capsule
geometry. Expanding the composer, note or notification does not change that
reservation or trigger a card repack; those surfaces retain their existing
interaction/overlay ownership.

## Thinking feedback

Moku temporarily hides its live reasoning text Arc. Deep thinking uses the same
three-dot running choreography described above, including Reduce Motion's static
dots. Live reasoning takes priority over a queued generic tool expression; source
appends do not restart the running clock. Composer, notes, Talk/dispatch, voice
and permission/question surfaces retain priority. Completion, failure,
interruption, waiting for input and runtime disconnect retire loading through
the existing execution and surface ownership state.

The public Harness foreground still supplies
[MokuReasoningContent](../Moku/MokuReasoningContent.swift), identified by Thread,
Harness, execution and foreground sequence with its UTF-16 source offset.
Assistant/tool foreground changes, terminal states and disconnects retire that
live projection as before. The Arc model, painter and layout remain available
for a future presentation change, but the Dock does not admit or paint their
text. Ordinary Agent Thread trace rendering and Moku's history reader are
unchanged; this is a Dock presentation policy, not a data/schema change.

Validation uses the [native reasoning replay](../../../../../tools/verification/moku-reasoning/README.md),
which drives Runtime fixture transactions through the real Harness, workspace
projection and Dock, and the [transition replay](../../../../../tools/verification/moku-transitions/README.md)
for interrupted loading/input handoffs. The [native study](../../../../../demos/moku-thinking-orbit/README.md)
retains the Arc for comparison only.

## Talk, dispatch and notes

The expanded note's **Moku history** button opens the existing conversation
reader, including its archived-session picker. It remains available when the
note or conversation is empty and supports keyboard and accessibility activation
with localized labels. History sits before Stop or voice controls in the trailing
action row. The Dock measures the actions and shares the row only when it
leaves at least 200 points for a message or 240 for a dispatch card. Narrower
capsules put actions below the retained message or eyes. If the full label
cannot fit beside the other control, History becomes an icon with the same
accessible label and help; if even that pair cannot fit, the controls stack.
The note body stays clipped above these rows; its header scrolls with the body
in short viewports, including 5× zoom.
Opening history uses the scene's ordinary navigation path, closing the note
without changing its exposure receipt or the workspace draft.

[NativeMokuTalk](NativeMokuTalk.swift) shows the latest valid `talk` or `create_thread` operation. Talk is selectable text in a four-line viewport with scrolling for overflow. Its trailing control seat stays reserved for the whole message so retiring Stop does not shift centered text or change its wrapping. It does not edit the draft or grab focus. Clicking outside the capsule dismisses the presented notification without consuming the click, including clicks in another window or app; clicks and scrolling inside retain it. The cross-app mouse observer is removed when the notification is hidden or the Dock unmounts. Dismissed/presented operation identity survives refresh and remount within its scene; a notification covered before presentation waits until it can actually be shown.

The two vertical strokes to the left of Talk are Moku's eyes, drawn by
`NativeMokuCharacterSurface` in its `.face` seat, rather than a pause button.
The row reserves a 34-point eye seat and a 15-point gap; with its 15-point
leading inset, the message viewport starts 64 points from the capsule's left
edge. The eye drawing uses its own centered 58×49-point canvas (scaled in
landing), so its painted bounds, rather than that canvas's frame, determine
clearance. `NativeMokuTalkTests.longMessagesKeepClearOfEyesWithoutOpeningAWindow`
mounts the production Dock in windowless hosting views at 188, 320 and 900
points, with Chinese/English long messages, ordinary/landing sizes and idle/running states. It checks
settled eye-path and native message-clip separation. This headless check does
not certify animation frames, rendered pixels or native scrolling behavior;
those remain in the display-gated transcript and transition replays.

Text shorter than the Talk viewport is vertically centered beside the eyes.
Overflow keeps its bottom anchor and follows new text only while the reader is
at the tail; the same layout applies to the voice transcript. The Dock's Stop
square is revealed by pointer hover, keyboard focus or VoiceOver focus and fades
out otherwise. The Button itself stays in the accessibility tree, while pointer
hit testing follows the visual state so an invisible square cannot be clicked.
Running messages reserve a 48-point trailing inset even before hover/focus,
keeping text and dispatch content clear of the 30-point Stop target and its
7-point edge inset. Revealing the square therefore does not rewrap the message.
This is cancellation (`moku:cancel`), with no pause/resume action. Composer Stop
is a separate item in the input HStack. Voice controls use a 34-point target and
the same 48-point message reservation; their “Voice paused during thread call”
status reports audio ownership suspension, while actions are mute/unmute,
start/end and takeover. Blink/cloud clock pauses are animation lifecycle state,
not message-bar controls.

Each notification expires 60 seconds after its first actual presentation, using a
monotonic deadline retained by the scene. Refreshes and in-place operation updates
do not extend it; a replacement operation gets its own full interval. The Dock's
deadline task is cancelled on replacement, dismissal or unmount and checks the
captured operation identity before expiry. Timeout consumes only the notification,
using the existing dismissal and capsule transition; it never deletes transcript
history or changes the persistent note, ordinary replies or voice transcript.

[NativeMokuDispatch](NativeMokuDispatch.swift) projects the same operation while pending and settled. Success requires `completedAt`, no error, `ok:true` and a nonempty `threadId`; it confirms dispatch, not task completion. The 400×58-point layout contracts for narrow viewports. Configuration comes from that call's arguments. Details resolve the selected operation identity in the full transcript, preserving its original prompt and outcome when newer notifications arrive.

[NativeMokuNote](NativeMokuNote.swift) reads the persisted note and expands the same capsule, up to 560 points wide and bounded by the viewport with 24-point side margins. Markdown is read-only/selectable, with a fixed header and scrollable body. When the available note height is too short to show a complete body line below that header, the header scrolls with the body instead; the supported 5× app zoom therefore retains a usable reading viewport. The catalog's `lastExposure` is the only authority for the accessibility update indicator. Opening the panel does not acknowledge it. A user-opened panel or later body interaction can start a reading session; the production renderer must apply the exact note token, the key foreground window must remain visible, and each actual body viewport interval must stay stable for two seconds. Only complete coverage submits an authenticated receipt. Code, tables, images and local-file previews stay unknown in this first version. Each mounted window owns its partial coverage; failed receipts remain pending for a later same-version UI activity, with no optimistic indicator change.

Coverage retains the union of settled ranges, so revisiting text does not accumulate duplicate intervals. Disconnect cancels the in-flight submission while retaining at most one completed receipt. Snapshot rehydration reconciles that receipt against the exact catalog incarnation/version before retrying; a new version, cleared note or released workspace discards it. The native note replay checks failed submission, same-version retry, stale pending eviction, short-note dwell and long-note viewport gaps/complete traversal. The backend's `-swift-note-exposure` replay connects the actual Swift tracker and sender to an isolated authenticated Runtime and checks the next Moku context.

The fixed-header versus scrolling-header layout depends on the Dock's available
viewport height, independently of the document's fitted height. An initially
empty Markdown layout must not replace the scroll container when parsing
finishes: replacing it retires the mounted renderer and its armed read session.

Input/permission interactions take precedence over the note; leaving Overview or opening another covering route closes it. Escape, outside click, the close button and the note command dismiss it. The macOS note command is `Cmd+Shift+N` when the Dock is available. The Dock's surface/eye expansion explicitly respects Reduce Motion.

Note ink has its own composited transition outside the native document's
non-animated layout transaction. Header and Markdown fade together over 120ms
on dismissal, before the 420ms glass contraction carries the header through the
eye seat. Opening retains the glass's ordinary reveal timing; Reduce Motion
removes both animations. Closing only dismisses this read-only presentation;
it does not clear the catalog note or change the composer draft.

## Voice display

The current user transcript takes precedence over Talk/dispatch while present. Partial/final snapshots replace the same session/item; final or handoff alone does not hide it. The first nonempty assistant item or explicitly associated Moku answer consumes it once. Duplicate assistant fragments cannot hide a newer input, and a late final cannot resurrect a consumed item. Owner/media termination clears the projection. [Native voice](../../Voice/README.md) owns these identities and microphone lifecycle; mounting the Dock/history or cloud never starts media.

The [voice cloud](../VoiceControls/NativeMokuVoiceCloud.swift) is driven by the production capture analyser's bounded loudness/onset signals. Active voice presentation covers the thinking arc; the history composer does not mount it.

Holding the text editor for 0.5 seconds starts the workspace-owned voice client
through [NativeMokuLongPressVoiceMonitor](../VoiceControls/NativeMokuLongPressVoiceMonitor.swift).
Landing, bottom-Dock and history editors share this entrance. The native press recognizer
preserves ordinary click/focus and cancels on movement, early release,
lost window activity, unavailable input or unmount. AppKit tracks the delivered
event stream, including native text selection. Only the editor is eligible; eyes, attachment/send controls,
notes and directory suggestions are excluded. Release after activation keeps the
voice session running and retains the draft. The localized placeholder/help and
VoiceOver Start voice action expose the entrance. Force Touch and the former
Ctrl+Option+V menu command no longer start or stop Moku voice. Its preparing through
stopping phases drive presentation. The cloud fades over the existing 0.42-second
smooth capsule timing; the drawing stays mounted with its timeline paused while
inactive, so resizing does not insert a final-width cloud mid-collapse. Dock
editor text fades out in 0.12 seconds before the eyes cross its seat, and the history
composer opens a 34-point control seat without replacing the editor or draft.
Transitions reverse directly from current presentation values, without timers,
delayed audio, or a second voice-session lifecycle. Reduce Motion disables these
transitions and uses the cloud's static drawing. Cancelling preparation restores
previously open Dock input. The [voice cloud replay](../../../../../tools/verification/moku-voice-cloud/README.md)
also exercises these production surfaces with the real client held at preparation.

Validation: existing Moku Dock, history composer, Talk, dispatch, note, gesture and transcript suites; [Moku backend replay](../../../../../tools/verification/moku/README.md), [native Talk replay](../../../../../tools/verification/moku-talk/README.md), [Talk dismissal and capsule edge replay](../../../../../tools/verification/moku-talk-dismiss/README.md) and `tools/verification/moku-note/run.py`. The note replay mounts the production Dock with voice presentation fixtures to verify gesture ownership, voice control clicks, note dismissal and composer draft/focus restoration. It also ends voice while the note is open with and without a saved composer, and checks the empty voice note in a narrow viewport. Voice functional hit tests disable animations to avoid inactive-app presentation pauses. It does not open a live microphone or prove WebRTC playback continuity. Add `--voice-only` to stop after the ordinary note lifecycle and voice routing checks, before the separate rapid-toggle/narrow-window long-note layout stress cases.

Switching the coordinating Harness retains the previous native conversation as a read-only Moku history session. The history selector opens those sessions through their original Harness reader; the current composer belongs only to the current session. Runtime prevents archive reactivation, fork and execution, while keeping attachment ownership until an explicit Moku history reset removes current and previous sessions.

Run `python3 tools/verification/reading-presentation/run.py --moku-composer`, `--composer-paste`, and `--moku-note-tests` serially for the mounted history editor, immediate-paste admission, Stop/Cancel controls and short note viewport regressions. These modes use the production components in an isolated AppKit event loop and reject skipped/incomplete suites.

Note Markdown accepts app-internal execution links in the form
`[label](mokusei://execution?threadId=THREAD_ID&executionId=EXECUTION_ID)`. The note
forwards a validated typed reference to the Host; other Markdown surfaces do not
open these links and they are never handed to the OS. Only ordinary public
Agent Threads qualify, including archived, failed and interrupted ones. Moku,
its history and missing/private targets produce an unavailable notice. The note
retains its existing character budget and viewport-exposure semantics.

The reader opens one fixed execution at its final visible reply, or its latest
visible content/status when no final reply exists. Running executions initially
scroll to the bottom and follow output until the user scrolls up; Jump to latest
restores following. The visit stays on the cited execution after a successor
starts. Run `python3 tools/verification/reading-presentation/run.py --moku-execution-links`
for the production note-to-reader replay across all four Harnesses.

## Settings expansion

Settings occupies the resident Dock's existing glass capsule, with a stable
viewport-bounded centered 780×680-point target. Its full panel uses untinted
regular glass and hides the persistent character row until returning; the other
Dock surfaces retain their existing gradient material and anchors.
The scene blurs and disables Overview, while the capsule and retained input/Note
visit stay mounted. Closing uses the Settings draft gate and restores the
previous valid surface; pending interventions resume only after Settings exits.
Voice media ownership and background execution are unchanged. A deferred voice
composer restoration is applied when Settings releases presentation ownership.
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
current workspace route with Moku's surprised eyes, the complete scrollable text,
a queue count and an always-present **已收到 / Received** button. It does not
navigate, replace the Dock editor, grab focus, or close voice/permission surfaces.
Its click region is excluded from composer outside-click dismissal. It has no
Escape, outside-click, focus-loss or timeout acknowledgment. Static eyes and
nonanimated presentation respect Reduce Motion. Native text/buttons expose the
content and action to accessibility; acknowledgment does not require audio.
Like the other Moku surfaces, the Timer bar uses a local dark environment even
in a light workspace; it does not override the window or Settings appearance.

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
one shared bell while the queue is nonempty, and never alters system volume or
voice ownership. Acknowledging the last item stops it; workspace shutdown stops
it before asynchronous runtime/media cleanup, and process exit ends playback.
Playback failure keeps the message and receipt button visible, reports the error
in the bar and offers an explicit retry. Muted devices, output routing, sleep,
OS audio interruption, and actual audibility are outside headless coverage;
no change to microphone/WebRTC state is made to force an audible bell.

Run the production binding/SQLite/catalog replay and Swift tests without windows
or real sound (all Timer tests inject fake players):

```sh
MOKU_TIMER_NATIVE_FIXTURE=/tmp/moku-timer-records.json ./scripts/go.sh run -race ./tools/verification/moku
MOKUSEI_TEST_HEADLESS=1 MOKU_TIMER_NATIVE_FIXTURE=/tmp/moku-timer-records.json xcrun swift test --package-path app/macos --filter 'NativeMokuTimerTests|NativeMokuTalkTests'
./scripts/go.sh test -race ./internal/services/moku ./internal/core/runtime
```

The new suites cover validation/audit failure, queue order, snapshot deduplication,
same-text calls, identity fencing, audio failure/retry, silent startup, reconnect,
workspace remounts, retained drafts/selection, and windowless production bar
accessibility. They do not certify rendered animation frames, actual keyboard
focus, active voice playback continuity, sound output, or real VoiceOver operation.
Those require explicit interactive acceptance; do not open windows or play the
production bell during headless verification.
