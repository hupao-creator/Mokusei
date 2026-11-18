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

A nonactivating panel uses an in-memory Agent draft and a separate Overview
draft. It drives the production scene's composer context change with continuous
Dock eligibility, then closes and reopens the Overview editor during its
420ms retention window. It marks and commits text through the mounted
`NSTextInputClient`, then types into the same editor. It checks the exact multiline
draft and UTF-16 selection after reopening and checks that closing again
presents queued Talk without consuming the draft. The harness calls AppKit's
input-client methods directly. A system IME candidate UI needs separate
system-input verification. See the
[Dock contract](../../app/macos/Sources/Host/MokuScene/README.md#dock-and-composer).

The app exits and saves `collapse/window.mp4` and `collapse/observations.json`
next to its temporary bundle. Check the closing frames for the outgoing Agent
placeholder and Overview draft to disappear as soon as the shell starts
shrinking, and check that the reopened draft and the Talk reply are readable.
The replay uses real rendering and native editor state with synthetic routes
and no Runtime or system input. Pixel review is manual. A reused output
directory, missing window capture or failed semantic check cannot establish a pass.
