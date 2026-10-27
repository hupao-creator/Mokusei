# Production Moku blink replay

Run serially with other native UI replays and SwiftPM builds:

```sh
make check
xcrun swift test --package-path app/macos --filter NativeMokuBlinkTests
MOKU_BLINK_EVIDENCE=/tmp/mokusei-moku-blink-evidence python3 tools/verification/moku-blink/run.py --skip-build
python3 tools/verification/moku-blink/run.py --skip-build --negative-control
```

The runner links the current production objects into a disposable AppKit application. Its plain NSHostingView supplies the active scene phase explicitly (and inactive while minimized), since it has no SwiftUI App scene to supply that lifecycle. It mounts `NativeMokuScene` and `NativeMokuDock`, using their real eye surface, glass and composer. It does not modify or launch the talk, cloud or reasoning demos, use a backend account, or send a message.

WindowServer screenshots use ScreenCaptureKit's **current-process** window filter, matched by window ID, process ID and full window dimensions. LaunchServices activates the fixture to avoid capturing a Stage Manager thumbnail. Captures are written inside the temporary application directory, then copied by the runner to `MOKU_BLINK_EVIDENCE` (default `/tmp/mokusei-moku-blink-evidence`), avoiding a GUI application's Desktop folder permission prompt.

For each state, the replay samples actual presented pixels about every 25ms plus screenshot latency. It requires eye ink to drop below one third of the observed open area, then recover above four fifths, within a natural blink deadline. It never calls `draw`, `cacheDisplay`, `needsDisplay`, or a clock advance to manufacture a blink. The collapsed state must complete two cycles. Other states cover input expansion, running, streaming talk updates, search hide/show, miniaturization and remounting. The replay does not read or change OS motion preferences. Production blinking and running eyes use the system animation schedule without a fixed frame interval; capture polling is an observation interval, not an animation frame cap. Inactive scenes pause animation, and Reduce Motion keeps open eyes with static running dots.

The negative control supplies an inactive scene phase to the production Dock, stopping its real blink schedule. The replay must then report `no natural close/reopen`; an unrelated capture, compilation or window visibility error does not count as detecting the regression.

Screenshots and `measurements.json` contain only this fixture window. This tests real native rendering and scheduling with fixture presentation states, not live harness/network behavior. It requires a logged-in macOS GUI session and does not overwrite the installed/running Mokusei app.

The independent review found that Stage Manager may transform a restored window
without changing its reported full-size frame. The replay now waits for an
opaque, fully presented WindowServer image, excludes transparent pixels from
ink counts, and activates its own fixture after deminiaturization. Invalid
captures fail as capture errors, so they cannot satisfy the inactive-schedule
negative control. Failed captures and their result are retained under
`MOKU_BLINK_EVIDENCE/failure`; negative-control captures use `negative-control`.
The host is an auxiliary floating fixture window so ordinary app switching
does not turn its scene into a Stage Manager thumbnail. This changes only the
replay host; the production Scene/Dock, real minimize/restore and hidden states
are still exercised, and system preferences are left untouched.


The focus regression also renders the production eyes above a direct Shape
reference in the same WindowServer frame. An unread reply gives Moku its happy
expression; opening the input changes the semantic expression to focus. The
reference continuously blends happy geometry into focus geometry. The replay
compares ink masks during opening, closing and an interrupted opening, requiring
at least 12 frames and less than 20% mask difference. Comparing both seats in the
same capture avoids timing drift between independent screenshots. Baseline code
failed with a 53% difference because only focus, rather than expression geometry,
was animatable. The actual Dock replay also checks that the right eye retains its tilt toward
happy during collapse. The retiring editor must not temporarily select idle and
reverse that tilt. It saves all Dock transition frames for review.

For just the input-transition checks, use `--focus-only`. Evidence includes
`focus-measurements.json`, `focus-*.png`, `dock-frames.json` and `dock-*.png`.
The normal run also checks natural blinking, input expansion and visibility.


2026-10-21 validation: `make check` and 10 Swift tests across blink, input
presentation and history composer suites passed. The native replay passed 16
focus frames with zero mask difference, 36 Dock transition frames without the
idle detour, and all natural blink/visibility/remount scenarios. The original
focus-only code failed the same pixel comparison at 53% mask difference.

The broader legacy `moku-attachments` runner was also attempted, but its
unchanged fixture does not compile against the current NativeColor palette API.
It is not counted as a passing check. This change validates input expansion,
collapse, reversal and eye rendering through the production Dock pixel replay;
the full Swift test suite was not run.

Running fallback restoration:

```sh
MOKU_BLINK_EVIDENCE=/tmp/mokusei-orbit-evidence python3 tools/verification/moku-blink/run.py --skip-build --orbit-only
```

This mode captures a complete cycle of the production Dock, requires colored
pixels beyond all four sides of the capsule, rejects any colored pixel touching or entering its rounded glass outline, and checks frozen pixels while inactive
and under Reduce Motion. It also checks that tool ownership, expanded input,
idle and cancellation remove the dots, and a new run restores them. Since the
system Reduce Motion environment value is read-only, the static check
mounts the same production running-eye component with its Reduce Motion input
enabled, without changing the system preference. Static dots must remain three separate groups with enough visible pixel area for the production 5-point diameter. The screenshot crop includes 12 points outside the glass on each side, covering the outward-offset path and exposing clipping regressions. Each WindowServer frame is retained as `orbit-*.png` for animation review.
