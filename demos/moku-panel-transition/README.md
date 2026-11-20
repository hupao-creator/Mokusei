# Resident input visual preview

```sh
python3 demos/moku-panel-transition/build.py --open
```

`--skip-build` reuses the current production build. The app path is written to
`.build/moku-panel-evidence/app-path.txt`. The preview mounts production Scene,
Dock, composer, native editor, eyes and capsule glass; the reading background and
business states are fixtures. An isolated app launched with `--capture` records
its own presentation PNGs and `samples.json`, without correctness assertions.

The main window accepts typing, Escape, outside click and resize. A separate
control window changes input state, running state, route, size and local animation
transaction. The production [composer contract](../../design/composer.md)
owns pinned Agent input and its single active-execution action seat; fixture
route toggles cannot establish real Runtime or receipt behavior.

## Overview Dock replay

Build the preview as below and run its executable under the shared desktop
verification lease with `--capture-overview`. A small isolated panel mounts
the running Chief's production Dock over a plain backdrop. It records two
open/close cycles at production speed. Use `--english` for English (the default
is Chinese) and `--reduce-motion` to set the fixture's SwiftUI accessibility
environment. Each combination writes its own `overview-*/window.mp4` and
`observations.json` next to the temporary bundle. Use a fresh output directory.

Add `--system-input` to drive the panel externally. Once `ready.json` identifies
its PID and window, click the eyes, click the blank area inside the panel,
activate **Open Chief input** via AXPress, then click or AXPress **Stop Chief**.
The replay checks the open/closed/open sequence and the
fixture's cancellation callback. Run
`python3 demos/moku-panel-transition/check_overview.py <capture-directory>`
on the system-input movie using FFmpeg and ffprobe. With the pointer over the
compact eyes before each opening, the square must remain visible as the
capsule widens. Its measured distance from the right edge stays between
the compact and open seats, including while it fades on outside click.
With Reduce Motion each width change goes directly between 168pt and 560pt.
Review the input ink as the capsule folds.
The fixture uses an in-memory draft and a simulated running task.

## Collapse replay

Build the preview without `--open`, then run the printed app's executable directly.
The replay needs the repository macOS/Xcode toolchain and a WindowServer session
with ScreenCaptureKit current-process capture. Use the shared verification lease
when running alongside other native verification.

```sh
python3 demos/moku-panel-transition/build.py
replay_app="$(cat .build/moku-panel-evidence/app-path.txt)"
"$replay_app/Contents/MacOS/MokuPanelPreview" --capture-collapse
```

A nonactivating panel starts with the Report list's input gate closed. Selecting
a fixture execution publishes the right column through the production native
marker and waits for Dock travel and the Codex identity flip before expanding
the composer. The replay checks that the list and moving Dock have no editor,
that the selected column admits one editor, and that returning to the list
and reselecting releases and restores input. Pass `--narrow` to exercise the
two-row layout in a 480-point window. Build a fresh bundle for each capture.

The replay then switches to a separate in-memory Overview draft with continuous
Dock eligibility, closes and reopens the Overview editor during its
420ms retention window. It marks and commits text through the mounted
`NSTextInputClient`, then types into the same editor. It checks the exact multiline
draft and UTF-16 selection after reopening and checks that closing again
presents queued Talk without consuming the draft. The harness calls AppKit's
input-client methods directly. A system IME candidate UI needs separate
system-input verification. See the
[Dock contract](../../app/macos/Sources/Host/MokuScene/README.md#dock-and-composer).

The app exits and saves `collapse/window.mp4` and `collapse/observations.json`
next to its temporary bundle. Inspect intermediate opening frames. The first
visible placeholder glyph and the attachment button must clear the Codex logo.
The compact editor must enter above the logo. Check that outgoing ink disappears
at the start of closing and that the reopened draft and Talk reply are readable.
The replay uses real rendering and native editor state with synthetic routes
and no Runtime or system input. Pixel review is manual. A reused output
directory, missing window capture or failed semantic check cannot establish a pass.

## Agent entrance replay

Use the same isolated preview build and the shared verification lease.

```sh
replay_app="$(cat .build/moku-panel-evidence/app-path.txt)"
"$replay_app/Contents/MacOS/MokuPanelPreview" --capture-agent-entrance
```

A nonactivating panel uses an in-memory Agent draft and a separate Overview
draft. It opens a short Chinese title and a long title in the same narrow
right column on successive visits. The production reading panel, column
marker and Codex identity drive Dock travel and input admission. The fixture
suppresses the column during panel return, as the workspace does. A two-point
click-through strip at the screen edge keeps the window rendering during
current-process capture. The replay checks the 168×44pt idle target after
each return. All four short/long Agent visits use production-default autofocus. The replay
interrupts an Overview entrance at 80ms and reopens it after another 80ms.
It also reopens a populated editor during its 420ms retention window. It marks
and commits text through the mounted `NSTextInputClient`, then types into
the same editor. It checks the exact multiline
draft and UTF-16 selection after reopening and checks that closing again
presents queued Talk without consuming the draft. Both titles then open again on
the ordinary reading clock to check autofocus at production speed. A separate pinned Agent
visit drives the explicit Compose command at admission. The harness calls AppKit's
input-client methods directly. A system IME candidate UI needs separate
system-input verification. See the
[Dock contract](../../app/macos/Sources/Host/MokuScene/README.md#dock-and-composer).

The app saves `agent-entrance/window.mp4` and `agent-entrance/observations.json` beside
its temporary bundle. Run the frame check with Python, NumPy, OpenCV and
`ffprobe` against this 2×, 1024pt-wide Chinese-language fixture.

```sh
python3 demos/moku-panel-transition/check_frames.py "$(dirname "$replay_app")/agent-entrance"
```

A blue tile beside the responder marker identifies the fixture phase. Each
numbered phase in the native receipt has its own horizontal position in the
recording. The checker reads every frame in presentation order and requires
one unambiguous tile and every phase in sequence. Its JSON pairs each phase's
first frame and movie PTS with the native elapsed time for diagnosis. All
frame ranges use the recorded markers. For each Agent, the template comes
from the middle frame of the marked settled hold before Close. The return
includes every frame from the Close marker up to the next visit. Recordings
need phase markers to run this checker.

The first two Agent entrances measure geometry. For admitted input in these
visits the native Dock evaluates its production opening animation at every
1/60s of source time, holding each step for 100ms of replay time. This gives
the recorder several refreshes to see ink while the shell is still moving.
The fixture installs the clock before admission. The responder, editor,
glass and glyphs are rendered together. Return, rapid reversals and the
subsequent real-time Agent visits use their ordinary animation clocks.
The held frames describe geometry at the sampled source times. Use the
real-time visits for focus timing at normal speed.

On all four returns the checker measures from the Close marker to the first
frame showing 10% of the width change from expanded to idle. That frame must
fall within the first half of the 420ms panel return. The silhouette includes
both vertical seats so its rounded corners remain measurable during travel.

For each geometry visit the check matches the first placeholder glyphs against their
settled pixels and measures each returning glass silhouette against both the
open width and the narrowest frame so far. The placeholder must disappear during
contraction and the shell must reach its initial idle width. The check allows one point of glyph displacement and
two points of silhouette variation for rasterization, compression and the changing glass backdrop.
Each direction must supply intermediate widths. The JSON result reports the
largest displacement, width and regrowth with their movie times. It also
reports the count, distinct widths and first/last PTS of readable frames
strictly more than four pixels short of the open width. Missing that window
fails the visit even when its settled reference is readable.

The capture panel paints a red or green marker when AppKit changes the actual
first responder. For default Agent focus and both Overview reversals, each
green frame during acquisition must show the settled placeholder or draft
strokes at 10% or more of their settled contrast. Focus must arrive by the
next recorded frame after visible ink and persist through the hold. The
explicit Compose visit must acquire focus before ink appears. The marker
and glyphs share a movie frame and presentation timestamp. Inspect the movie
for partial glyphs crossing the Harness mark, tail truncation, immediate ink
retirement on Close and readable draft and Talk after rapid reversal.
Missing or fully occluded motion cannot establish a visual pass. These frames
exercise synthetic routes and in-memory drafts without a Runtime or system input.
After capture, the focused Agent editor sends via Return and commits a new
draft through AppKit marked text. The fixture returns to Overview and rejects
the earlier send. It checks the exact restored Agent draft and that Overview
keeps its own draft and focus.

## Chief input replay

Run `--replay-chief-input` under the same shared desktop verification lease to
check the [Chief composer contract](../../app/macos/Sources/Host/MokuScene/README.md#dock-and-composer).
The nonactivating panel mounts the production Overview Dock and current Chief
history in turn. It delivers local AppKit key events, pastes through a private
pasteboard, edits the text and submits through Return. The replay checks that
typing `@` opens no completion UI and that bare `@` and messages with and without
`@` reach the submission callback as exact text parts. **Show user messages**
reveals a recorded message with a directory mention from fixture subscription
data. A reopened draft sends a saved catalog path as plain text. The replay
feeds host metadata to the draft action used by the directory picker's
**Choose** button and checks that the explicit selection stays structured.
The app prints the covered cases and exits nonzero on a failed assertion.
The isolated callback captures the payload without starting a Runtime.
The [Chief file picker procedure](../../tools/e2e/README.md#chief-file-picker)
covers system interaction with the picker UI.

## Pending send replay

Build the preview as above and run the executable with `--replay-send` under
the shared desktop verification lease. Its panel cannot become key or main and ignores system pointer input. It mounts the pinned
Thread composer with the editor's normal text input settings. The fixture
delivers local AppKit mouse events to Send, Return to the native editor, and
marked text and commits through the NSTextInputClient interface. It supplies
the admission result. It never opens a Runtime connection.

Send, the next insertion, rejection and another insertion can all occur on the
same event stack. Assertions compare the native text, the saved draft and the
peer's captured payloads, including duplicate presses, equal successive text,
composition and reselecting the same directory through `@` completion. For
delayed receipts the fixture waits only for the send operation to settle.
Two mounted native editors share a saved scope. While the first holds marked
`pin`, the second inherits it and adds only a directory, adds only a fixture
attachment, or selects the body and replaces it with `B` or the same `pin`.
Each case runs with acceptance and rejection. The first editor commits `拼`
and inserts `C` on the same event stack. Assertions cover native text, model,
reopened draft, chips and the exact payload of the next explicit Return. An
additional acceptance case finishes composition with AppKit’s `unmarkText`.
Separate writer and reader processes share a temporary draft scope: the writer
exits before admission, and each local recovery choice must yield the expected
text with zero deliveries in the reader.

The executable prints the results and exits nonzero on a failed condition.
System input-source candidate selection, system-wide mouse routing and actual
Runtime delivery require separate verification. The
[operator-assisted Composer journey](../../tools/e2e/README.md#composer-system-input-boundary)
covers system input and persisted Runtime results.


## Host receipt replay

With the debug production build available, run
`python3 demos/moku-panel-transition/receipt_replay.py` under the shared
verification lease. The windowless replay attaches the production RuntimeClient
through a loopback fault proxy to the production Go transport in a temporary,
exclusively owned profile. The proxy disconnects after the Go ReceiptStore
reports pending. The Go Host fixture counts actual handler entries. A baseline
bare UUID must fail admission, and a duplicate of an admitted ID must return
the recorded result with no additional handler entry. The execution-change
path checks both derived fork and follow-up IDs. Both the live and reconstructed Host check the captured ID.
The Chief case begins with a saved send that carried a structured catalog
mention and checks the receipt under its original command ID.
Assertions cover a pending result, final acceptance and rejection, a different
draft with identical text, and a subsequent explicit send. The replay also
makes the temporary draft directory read-only for one edit, restores its
permissions and checks the durable successor and acknowledgement. A fresh process
finishes cleanup after a disk error on either side of journal acknowledgement.
Historical fork and follow-up phases cover explicit local recovery, with the
peer counting each mutation. A new send from the same historical checkpoint
must fork from that checkpoint again after late acceptance. A competing process tests the scope lock. The Go
attachment repository stages two real files, contends for the ownership lock,
and collects again after the editors exit. The replay checks the surviving bytes
and the released file's removal. The fixture supplies service bootstrap and
command outcomes.
