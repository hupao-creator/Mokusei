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
