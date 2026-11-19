# Resident composer ownership

The [MokuScene guide](../app/macos/Sources/Host/MokuScene/README.md) owns Dock,
Talk, Note, input and draft behavior. [Core](../app/macos/Sources/Core/README.md)
owns durable receipt and attachment handoff.
[E2E-COMPOSER-001](../tools/e2e/README.md#composer-system-input-boundary) uses
operator-assisted system Accessibility input with independent public persisted
results; it is excluded from unattended hosted CI. OVERVIEW/READ/SETTINGS use automated
semantic controls. These scenarios do not cover IME, historical forks or uncertain
receipt recovery; demo fixtures do not establish Runtime delivery.

## Route, input and focus

Ordinary Agent detail selects its Thread draft and pins input open. Exact
history/result readers use a separate Thread/execution draft shared with Report's
selected-execution reader. Thread title/status changes do not replace an unsent
draft. A callback may consume only the submitted draft revision and captured
source; a late result cannot reopen another visit.

The input pin exists before the editor opens, through reading preparation and
the Harness identity flip. It suppresses closed-input running/submission orbit
ink throughout that ownership. Current active Thread input uses one trailing
action seat: Stop for an empty draft, Send for sendable text/attachments/directory
mentions. Import/submission/unavailable gates still apply. Historical input has
no authority to stop a newer execution. Other Moku composer routes keep their
own Stop/Send arrangement. Stop is cancellation, without pause/resume semantics.

Escape and outside click do not fold a pinned Agent editor. Escape first lets
IME, completion, menus/sheets/popovers and explicit control cancellation act;
otherwise the bound current route closes through normal reading motion. A blank
panel-margin click closes detail only after a completed press. Reader,
Sidecards, capsule and directory candidates keep their normal actions. Press
ownership survives AppKit committing marked text or dismissing a popup.
TOC selection changes drafts without stealing focus. Initial input and explicit
Browser annotation retain autofocus; a pending request waits for eligibility and
runs once. Incoming-reader publication cannot be cleared by its outgoing owner.

An unselected Super Thread document/list denies input expansion through the
shared scene gate, including capsule, shortcut/menu and automation requests.
Its associated execution borrows the pinned Agent composer after content/column
admission. Folding, Back, Browser replacement or departure retires that input.
Browser annotation uses the resident composer beneath its actual Browser column;
its attachment/send ownership remains independent of Conversation Sidecards.

Source: [workspace](../app/macos/Sources/Host/Shell/NativeWorkspaceView.swift),
[scene state](../app/macos/Sources/Host/MokuScene/NativeMokuSceneState.swift),
[Dock](../app/macos/Sources/Host/MokuScene/NativeMokuDock.swift).

## Geometry and surfaces

The Dock uses one persistent character/eyes owner and one glass shell. The
168×44pt resident capsule, expanded editor, directory suggestions and actions
share production layout. Below 260pt available width, the editor and action
seats form two rows without replacing the NSTextView. The editor remains
scrollable and the shell stays within the viewport. Closing input hides its ink
immediately while retaining the native editor for the shell's 420ms travel.
Returning to Overview hides the Agent composer as soon as the reading panel
blocks input, including the interval before the workspace releases the draft.
See the [Dock contract](../app/macos/Sources/Host/MokuScene/README.md#dock-and-composer).

Native horizontal travel retains the current position on retargeting and moves
directly to the committed destination column. A route owns column markers;
outgoing markers cannot overwrite incoming geometry. Resize, dragging and
inactivity settle the admitted destination. Submission orbit begins on captured
input, but grants neither Stop authority nor navigation before confirmed
execution admission. Receipt uncertainty preserves draft/recovery state.

Ordinary Talk and Note share the capsule reading seat. Talk fades before Note
expands and returns after Note ink retires. A rapid reversal continues current
geometry and fences old completion callbacks. Hidden retained content keeps
native identity/scroll state while leaving hit testing and accessibility.
Talk's existing expiration can run behind an open Note; expired text does not
return merely because Note closes. The expanded Note uses dark Regular Liquid
Glass; the compact Dock uses its warm clear gradient. Reduce Transparency uses
opaque fallback. Background input suppression does not dim read-only card ink.

Source: [Dock](../app/macos/Sources/Host/MokuScene/NativeMokuDock.swift),
[capsule](../app/macos/Sources/Host/MokuScene/NativeMokuCapsule.swift),
[Talk](../app/macos/Sources/Host/MokuScene/NativeMokuTalk.swift),
[horizontal travel](../app/macos/Sources/Host/MokuScene/NativeMokuHorizontalTravel.swift).

## Send identity and ownership

Latest sends follow up on their original Thread. Exact historical continuation
forks at a verified native execution checkpoint before following up on the
accepted branch. Runtime's `expectedExecutionId` rejects a changed target before
reservation/dispatch. Only a proven pre-admission change can enter the historical
fork path once; uncertain outcomes query their original durable receipt.

Codex removes only a positively unadmitted input identity from the captured
execution; generic transport failures retain it. OpenCode keeps private submitted
message/session/execution associations until a prompt receipt or matching native
inbox/history fact produces one canonical message. Late evidence cannot borrow a
successor's current execution identity. Persistence precedes inbox deletion.
Full details live with the [Codex](../internal/plugins/harness/codex/README.md) and
[OpenCode](../internal/plugins/harness/opencode/README.md) adapters.

Attachments retain independent Thread, saved-draft, command-receipt, live-process
and active-writer owners. A visual chip in an unsent draft is not transcript
ownership. Native staging and collection use shared profile lifetime and atomic
handoff rules; see [attachment storage](../internal/services/attachments/README.md).
