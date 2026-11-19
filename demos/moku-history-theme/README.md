# Moku conversation history preview

```sh
python3 demos/moku-history-theme/build.py --open
```

`--skip-build` reuses current production objects. The independent app path is
written to `.build/moku-history-theme/app-path.txt`; its own process can capture
a presentation sequence with `--capture`.

The real Moku history reader, Codex reader, shared Markdown, scene, Dock and Note
use in-memory content-subscription data. The history card follows the application
appearance while the separate composer retains dark capsule styling. Current
conversation input is editable; retained Moku history is read-only without a
composer. Theme, window size, Note and simulated execution controls affect only
the fixture. Send/Stop change fixture state; voice and attachment import do not
connect to devices/files. Stored [evidence](evidence) is attributed to its recorded
source, not certified current-frame or Runtime coverage.

Requires the repository macOS/Xcode toolchain. This preview has no automated
correctness acceptance gate; it does not install or replace the production app.
