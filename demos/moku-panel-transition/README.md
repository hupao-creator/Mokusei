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
