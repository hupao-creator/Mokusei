# Moku presentation

[NativeMokuWorkspacePresentation](NativeMokuWorkspacePresentation.swift) derives the current Moku execution's display from public transcript operations. [NativeMokuSceneState](NativeMokuSceneState.swift) owns transient presentation and dismissal. The [Go coordinator](../../../../../internal/services/moku/README.md) owns task admission, tool results, notes and voice routing.

Settings uses the SwiftUI [reveal overlay](../Settings/NativeSettingsTransition.swift)
inside the persistent scene. Scene state retains Settings through return and
reports its transition lifetime; the overlay owns animation completion and
settling, without restoring the retired AppKit scene host.

## Dock and composer

All Moku capsule surfaces use the approved theme-aware gradient over native clear
glass: warm black in dark appearance and pearl white in light appearance, fading
toward the bottom with a fine warm edge. Production density is 85%. The shared
material covers the Dock (idle, composer, Talk and note), landing notices, history
composer and interaction panel; the latter retains its existing explicit dark appearance.
Reduce Transparency uses opaque warm-black or pearl-white fills. Content ink,
caret, eyes and the external reasoning Arc retain their existing theme ownership.
The material does not change layout, clipping, voice ownership or motion clocks.
The [material demo](../../../../../demos/moku-gradient-material/README.md) now
compiles this same production material; its regular-glass option is a historical
baseline, and adjustable density/opaque simulation are local preview controls.
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
filtering to no results does not. No one-time onboarding flag is persisted.

Submitting input keeps the center open. A durable first-task shell can precede
native admission, so it remains behind landing while `create_thread` is pending.
A successful public result for an eligible Thread returns the Dock to its existing
bottom seat. Failure without an admitted conversation keeps the center available;
an independently admitted conversation also ends it. Existing workspaces hydrate
at the bottom. The same surface and Reduce Motion policy own the transition.

Talk and dispatch notices appear above the open landing composer without taking
its editor, focus or draft. They reuse ordinary selectable Talk/dispatch content,
outside-click dismissal and the deadline that starts only after actual presentation.
Directory suggestions can temporarily cover the notice when vertical room is too
short. Ordinary bottom-Dock notices retain their existing capsule presentation.
The [native landing replay](../../../../../tools/verification/reading-presentation/README.md#empty-workspace-and-first-dispatch)
exercises real workspace/catalog/presentation integration; the
[interactive visual fixture](../../../../../demos/moku-landing/README.md) retains the
approved appearance and editor checks without a live Runtime.

Directory completion opens above the editor within the same capsule. The editor stays seated at the bottom; scrolling suggestions are clipped to their own area. Selection keys and IME handling use the existing completion state. On macOS, native paste/drop imports files. The Dock and history capsule surfaces have no Moku context menu on right-click or Control-click. Native text editing menus and the voice control's own menu remain available. An accepted send consumes only its submitted draft revision; failure retains it.

An empty or whitespace-only draft without attachments/directories mounts no Send
button or circular background, including in accessibility. Its empty layout seat
keeps the editor width stable. Attachment/directory-only input still exposes Send;
importing, submission and unavailable states retain their ordinary admission rules.
Moku editors use a shortened, rounded 2.6-point caret with a warm-yellow upper
halo and cool-blue lower halo, plus the reference’s blurred gradient fringe.
Composer padding lives inside the native viewport so these halos are not cut at
the text line edges. A 2.4-second breathing cycle replaces native on/off
blinking; the white dark-mode core retains native dark ink in light appearance.
Light-mode ink stays at 80–100% opacity so the dim phase remains visible;
dark-mode ink uses 20–100%, while the halos fade fully in both appearances.
Same-line movement remains 120ms and interruptible. IME composition uses the
native caret; line changes stay immediate. Selection and focus/visibility loss
remove the layer and animations. Reduce Motion keeps the caret steady and makes
movement immediate.

The Dock and history input placeholder follows the displayed directory tags, including the retained draft during Dock dismissal. With no directory it reads `Ask Moku… or hold to speak` (Chinese: `向 Moku 提问，或长按说话…`); selected directories retain `Ask Moku about <name>…` with `or hold to speak` appended (Chinese: `向 Moku 询问关于 <name> 的问题，或长按说话…`). Two directories show both names joined by `and` / `和`; three or more show the first name and the remaining count (`<name> and N other directories` / `<name> 等 N 个目录`, with the Chinese count including all selected directories).

On macOS, clicking the collapsed Moku row opens input; when a message is visible, only the eyes are the input target so prose remains selectable and controls retain their actions. Clicking the retained row beneath an open note switches to input. Physical two-finger upward swipe opens the note; horizontal swipes do not open input. [NativeMokuSwipe](NativeMokuSwipe.swift) requires a precise phased gesture, threshold and dominant direction, rejects inertia/outside-origin gestures, and respects input/voice/interaction ownership. The click entry uses the existing composer focus and draft-restoration path. Voice mode allows the same upward note gesture on the retained Moku row (only the eyes when a transcript/notification is visible), excluding the measured voice control bounds. Clicking Moku cannot open the composer during voice. Note scrolling, Escape, outside click and the close button reuse the ordinary note path without changing the media owner or saved composer restoration state.

The compact running fallback reuses [MokuRunningStory](../Moku/MokuRunningStory.swift): three rainbow beats, lift, a three-second orbit, landing and recovery, with the eyes following the same clock. The choreography comes from Bart commits `2c3125ac7` and `45578f321`; the eyes retain their seat while the 5-point dots follow the capsule's outer contour, with 3 points of clear space. [NativeMokuRunningGeometry](NativeMokuRunningEyes.swift) shares that authored path between the persistent character host and the standalone reference. Decorations paint outside the glass clip. Input, note, tool, message, interaction and voice ownership retire the running decoration through the same host rather than replacing the eye view.

[NativeMokuCharacterMotion](NativeMokuCharacterMotion.swift) owns one AppKit display link and logical clock for the persistent eye and decoration seats. Ordinary expression changes take 420ms; running/thinking handoffs take 550ms. Interrupted transitions inherit the currently sampled geometry and derivative, without an intermediate idle pose or overlapping eye views. Same-segment text updates do not redirect a role. Inactive, hidden and occluded scenes pause the clock; Reduce Motion snaps to static open eyes and static running dots. Blink shape uses the continuous timestamp rather than fixed-rate samples. The production transition replay checks rapid redirection, persistent eye identity, text-clock continuity, viewport fitting and retirement; the existing blink replay retains natural-blink and running-orbit pixel coverage.

Overview derives its persistent bottom reservation from the same idle capsule
geometry. Expanding the composer, note or notification does not change that
reservation or trigger a card repack; those surfaces retain their existing
interaction/overlay ownership.

## Thinking arc

The current public Harness reasoning foreground supplies a
[MokuReasoningContent](../Moku/MokuReasoningContent.swift) identified by Thread,
Harness, execution and foreground sequence, including its UTF-16 source offset.
The live projection is separate from generic display-role leases: assistant/tool
foreground changes, terminal states and disconnects immediately retire its
content. A visible handoff may finish painting its captured glyphs, but it cannot
restore an expired source or delay a user interaction until a backlog is read.

The native arc keeps the capsule body. Its open circular span is 288°, centered
at −110°, with radius half the capsule's largest dimension plus 19 points.
CoreText paints 12.5-point medium glyphs with 1.3-point tracking in their tangent
direction, including the inverted lower edge. Short text centers by measured
width; the two ends fade. The glyph FIFO follows absolute source positions,
retains unread middle input and at most 112 measured graphemes, and settles on
the latest complete-grapheme tail of at most 56 Unicode code points. Same-segment
append preserves the reading clock; segment/execution changes, known source gaps
or revisions reset its reader. Reduce Motion shows the latest tail directly.

The arc model and painter own no timer. The persistent activity host coordinates
eyes, running dots and the text's gather/reveal handoff from their currently
painted state. Composer, notes, Talk/dispatch, voice and permission/question
surfaces retain priority. The Dock reserves visible ink space by continuously
lifting the capsule, eyes and arc together only as far as the viewport requires;
If a short or narrow viewport cannot contain the complete glyph envelope, the capsule and arc scale together to fit. Overview's fixed bottom reservation and card packing stay unchanged.

Validation uses the [native reasoning replay](../../../../../tools/verification/moku-reasoning/README.md),
which drives Runtime fixture transactions through the real Harness, workspace
projection and Dock, and the [transition replay](../../../../../tools/verification/moku-transitions/README.md)
for interrupted visual handoffs. The [native study](../../../../../demos/moku-thinking-orbit/README.md)
reuses the production Arc; its historical circular and contour tabs remain
comparison-only.

## Talk, dispatch and notes

[NativeMokuTalk](NativeMokuTalk.swift) shows the latest valid `talk` or `create_thread` operation. Talk is selectable text in a four-line viewport with scrolling for overflow. It does not edit the draft or grab focus. Clicking outside the capsule dismisses the presented notification without consuming the click, including clicks in another window or app; clicks and scrolling inside retain it. The cross-app mouse observer is removed when the notification is hidden or the Dock unmounts. Dismissed/presented operation identity survives refresh and remount within its scene; a notification covered before presentation waits until it can actually be shown.

Text shorter than the Talk viewport is vertically centered beside the eyes.
Overflow keeps its bottom anchor and follows new text only while the reader is
at the tail; the same layout applies to the voice transcript. The Dock's Stop
square is revealed by pointer hover, keyboard focus or VoiceOver focus and fades
out otherwise. The Button itself stays in the accessibility tree, while pointer
hit testing follows the visual state so an invisible square cannot be clicked.

Each notification expires 60 seconds after its first actual presentation, using a
monotonic deadline retained by the scene. Refreshes and in-place operation updates
do not extend it; a replacement operation gets its own full interval. The Dock's
deadline task is cancelled on replacement, dismissal or unmount and checks the
captured operation identity before expiry. Timeout consumes only the notification,
using the existing dismissal and capsule transition; it never deletes transcript
history or changes the persistent note, ordinary replies or voice transcript.

[NativeMokuDispatch](NativeMokuDispatch.swift) projects the same operation while pending and settled. Success requires `completedAt`, no error, `ok:true` and a nonempty `threadId`; it confirms dispatch, not task completion. The 400×58-point layout contracts for narrow viewports. Configuration comes from that call's arguments. Details resolve the selected operation identity in the full transcript, preserving its original prompt and outcome when newer notifications arrive.

[NativeMokuNote](NativeMokuNote.swift) reads the persisted note and expands the same capsule, up to 480 points wide and bounded by the viewport. Markdown is read-only/selectable, with a fixed header and scrollable body. When the available note height is too short to show a complete body line below that header, the header scrolls with the body instead; the supported 5× app zoom therefore retains a usable reading viewport. The catalog's `lastExposure` is the only authority for the accessibility update indicator. Opening the panel does not acknowledge it. A user-opened panel or later body interaction can start a reading session; the production renderer must apply the exact note token, the key foreground window must remain visible, and each actual body viewport interval must stay stable for two seconds. Only complete coverage submits an authenticated receipt. Code, tables, images and local-file previews stay unknown in this first version. Each mounted window owns its partial coverage; failed receipts remain pending for a later same-version UI activity, with no optimistic indicator change.

Coverage retains the union of settled ranges, so revisiting text does not accumulate duplicate intervals. Disconnect cancels the in-flight submission while retaining at most one completed receipt. Snapshot rehydration reconciles that receipt against the exact catalog incarnation/version before retrying; a new version, cleared note or released workspace discards it. The native note replay checks failed submission, same-version retry, stale pending eviction, short-note dwell and long-note viewport gaps/complete traversal. The backend's `-swift-note-exposure` replay connects the actual Swift tracker and sender to an isolated authenticated Runtime and checks the next Moku context.

The fixed-header versus scrolling-header layout depends on the Dock's available
viewport height, independently of the document's fitted height. An initially
empty Markdown layout must not replace the scroll container when parsing
finishes: replacing it retires the mounted renderer and its armed read session.

Input/permission interactions take precedence over the note; leaving Overview or opening another covering route closes it. Escape, outside click, the close button and the note command dismiss it. The macOS note command is `Cmd+Shift+N` when the Dock is available. The Dock's surface/eye expansion explicitly respects Reduce Motion.

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
