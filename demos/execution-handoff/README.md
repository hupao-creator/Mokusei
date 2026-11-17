# Execution handoff preview

```sh
python3 demos/execution-handoff/build.py --open
python3 demos/execution-handoff/build.py --capture
```

`--skip-build` reuses current Debug production objects; `--disable-sandbox`
applies to SwiftPM compilation. The independent signed app path is recorded in
`.build/execution-handoff/app-path.txt`. `--capture` records a presentation reel
and exports evidence; it does not run a test suite.

Fixture content, execution state and transition controls belong to this demo.
Shared native components supply text, shell and resources. The demo's authored
handoff is a visual experiment, not the production completion route. Production
[reading](../../design/reading.md) folds the execution Sidecard for 380ms and
waits independently for destination content before its 420ms vertical page turn.

Requires the repository macOS/Xcode toolchain. This preview has no automated
correctness acceptance gate; it does not install or replace the production app.
