# Super Thread native preview

```sh
python3 demos/report-thread/build.py --production --open
python3 demos/report-thread/build.py --cover --open
```

`--skip-build` reuses current production objects. `--disable-sandbox` and
`--skip-update` control SwiftPM compilation/resolution. The app path is recorded
in `.build/report-thread/app-path.txt`; resources and synthetic workspace remain
in an independent temporary directory.

Production mode mounts the real reading stack/panel, Report/WebKit and related
execution reader factories with synthetic bodies. List/detail widths follow
3:7 and 5:5. Source card and Close use production motion. A local slow-motion
control changes only this preview, and recording captures only its own window.
Cover mode uses passive HTML/CSS and the production Report card/cover renderer.
Its canvas size comes from current production geometry; see the
[cover contract](../../design/overview.md).

The default nonproduction composition and `--capture` target the independent
fixture surface. `--cover --capture` is rejected. Generated PNG/geometry output
belongs to that fixture and cannot certify production data, Runtime persistence,
real conversations, continuous-frame performance or receipt delivery.

Requires the repository macOS/Xcode toolchain. This preview has no automated
correctness acceptance gate; it does not install or replace the production app.
