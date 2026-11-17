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

Requires the repository macOS/Xcode toolchain. This preview has no automated
correctness acceptance gate; it does not install or replace the production app.
