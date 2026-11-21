# Moku Note visual preview

The preview links current Release production objects and mounts the real scene,
Dock, Note Markdown, eyes and glass. Background cards, note text, draft and
execution state are synthetic. A production scene owns visibility; mounting a
Dock alone does not admit foreground motion.

```sh
xcrun swift build --package-path app/macos --configuration release --product Chief -Xswiftc -warnings-as-errors
python3 demos/moku-note-transition/build.py --label candidate
mkdir -p /private/tmp/moku-note-preview-output
ditto .build/note-dismiss/candidate/MokuNoteTransitionPreview.app /private/tmp/MokuNoteTransitionPreview.app
open -W -n /private/tmp/MokuNoteTransitionPreview.app --args /private/tmp/moku-note-preview-output
```

Use a new empty output directory. The independent nonactivating panel records
only its own window, without audio. It emits video, observations and size-scene
PNGs, then exits. `build.json` records source/binary hashes and the production
diff. Rebuild production before linking and keep sources fixed during collection.

The sequence includes long/short Note, rapid reversal, narrow/resize, landing,
5× zoom and a locally disabled transaction animation. That last fixture is not a
system preference or a production motion branch. [Stored evidence](evidence/observations.json)
retains recorded source/video identity; it does not certify current behavior,
GPU performance, full-app zoom, real exposure receipts or Runtime sends.

Requires the repository macOS/Xcode toolchain. This preview has no automated
correctness acceptance gate; it does not install or replace the production app.
