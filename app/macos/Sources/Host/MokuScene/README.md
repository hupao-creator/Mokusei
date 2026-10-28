# Moku presentation

[NativeMokuWorkspacePresentation](NativeMokuWorkspacePresentation.swift) derives the current Moku execution's display from public transcript operations. [NativeMokuSceneState](NativeMokuSceneState.swift) owns transient presentation and dismissal. The [Go coordinator](../../../../../internal/services/moku/README.md) owns task admission, tool results, notes and voice routing.

Settings uses the SwiftUI [reveal overlay](../Settings/NativeSettingsTransition.swift)
inside the persistent scene. Scene state retains Settings through return and
reports its transition lifetime; the overlay owns animation completion and
settling, without restoring the retired AppKit scene host.

## Dock and composer

The shared input row places the attachment plus between Moku's eyes and the editor. It reuses the workspace draft's device file chooser; hosts with file browsing also offer host files and directories through the existing picker. The control has a localized help/accessibility label and is disabled while attachment import or the owning surface is unavailable.

[NativeMokuDock](NativeMokuDock.swift) uses one native glass capsule with a bottom-center anchor. Idle size is 168×44 points; expanded width is bounded to 560 points and the available viewport. [NativeMokuComposer](NativeMokuComposer.swift) shares the input row between the Dock and history. History stays expanded and keeps the same workspace-owned draft, attachment services, voice client and send callback. Collapsing and reopening the Dock input restores the caret/selection saved while it was open; the first open keeps the existing autofocus behavior. Both surfaces expose an execution-fenced Stop action while Moku is running; voice controls retain their separate media semantics. A normal click can acquire the native editor without being undone by a delayed SwiftUI focus report.

Directory completion opens above the editor within the same capsule. The editor stays seated at the bottom; scrolling suggestions are clipped to their own area. Selection keys and IME handling use the existing completion state. On macOS, native paste/drop imports files. The Dock and history capsule surfaces have no Moku context menu on right-click or Control-click. Native text editing menus and the voice control's own menu remain available. An accepted send consumes only its submitted draft revision; failure retains it.

The Dock and history input placeholder follows the displayed directory tags, including the retained draft during Dock dismissal. With no directory it remains `Ask Moku…`; selected directories use `Ask Moku about <name>…` (Chinese: `向 Moku 询问关于 <name> 的问题…`). Two directories show both names joined by `and` / `和`; three or more show the first name and the remaining count (`<name> and N other directories` / `<name> 等 N 个目录`, with the Chinese count including all selected directories).

On macOS, physical two-finger left swipe over Moku opens input; upward swipe opens the note. [NativeMokuSwipe](NativeMokuSwipe.swift) requires a precise phased gesture, threshold and dominant direction, rejects inertia/outside-origin gestures, and respects input/voice/interaction ownership. A single click does not substitute for these gestures. Voice mode allows the same upward note gesture on the retained Moku row (only the eyes when a transcript/notification is visible), excluding the measured voice control bounds. Left swipe cannot open the composer during voice. Note scrolling, Escape, outside click and the close button reuse the ordinary note path without changing the media owner or saved composer restoration state.

The compact running fallback reuses [MokuRunningStory](../Moku/MokuRunningStory.swift): three rainbow beats, lift, a three-second orbit, landing and recovery, with the eyes following the same clock. The choreography comes from Bart commits `2c3125ac7` and `45578f321`; the eyes retain their existing seat while the dots follow the capsule's outer contour. The path uses the actual surface size and clamped glass corner radius, offset outward by the 2.5-point dot radius plus 3 points of clear space. Dots are 5 points in diameter (formerly 2.5), with separated resting positions below the glass. The running layer is mounted after the glass clip and its Canvas reserves 12 points on every side, so neither the rounded ends nor the top/bottom runs are clipped. It appears only while execution is running and the display queue selects the running fallback. Input/note expansion, tool/operation/message ownership, interactions and voice replace it. Idle, cancellation and waiting for the user remove the view and its schedule. Both running eyes and ordinary blinking use SwiftUI's system animation schedule without a minimum interval or fixed-rate sampling. Inactive scenes pause their schedules; Reduce Motion keeps open eyes and static colored dots. Blink shape is evaluated continuously at the system-provided timestamp rather than generated 30fps entries. Validation uses the production Dock pixel replay's `--orbit-only` mode.

Overview derives its persistent bottom reservation from the same idle capsule
geometry. Expanding the composer, note or notification does not change that
reservation or trigger a card repack; those surfaces retain their existing
interaction/overlay ownership.

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

Input/permission interactions take precedence over the note; leaving Overview or opening another covering route closes it. Escape, outside click, the close button and the note command dismiss it. The macOS note command is `Cmd+Shift+N` when the Dock is available. The Dock's surface/eye expansion explicitly respects Reduce Motion.

## Voice display

The current user transcript takes precedence over Talk/dispatch while present. Partial/final snapshots replace the same session/item; final or handoff alone does not hide it. The first nonempty assistant item or explicitly associated Moku answer consumes it once. Duplicate assistant fragments cannot hide a newer input, and a late final cannot resurrect a consumed item. Owner/media termination clears the projection. [Native voice](../../Voice/README.md) owns these identities and microphone lifecycle; mounting the Dock/history or cloud never starts media.

The [voice cloud](../VoiceControls/NativeMokuVoiceCloud.swift) is driven by the production capture analyser's bounded loudness/onset signals. Moku reasoning trace is not rendered in the Dock or history.

Force Touch uses AppKit's stage-2 deep click in
[NativeForceTouchVoiceTrigger](../VoiceControls/NativeForceTouchVoiceTrigger.swift),
then immediately starts the workspace-owned voice client. Its preparing through
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
