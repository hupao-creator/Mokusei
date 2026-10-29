# Windowless Moku appearance replay

Moku uses the existing dark style on both light and dark systems. Application
appearance preferences still belong to the workspace; Settings keeps that
preference even inside the resident Dock. Ordinary threads, Overview, onboarding,
Browser/Report rendering and Report Agent's generated-content requirements are
outside this change. No system preference, persisted theme or runtime contract
changes, and no light-cursor demo is included.

Run on macOS 26 with Xcode 26:

```sh
python3 tools/verification/moku-appearance/run.py
```

The launcher builds current production modules and links their actual objects.
After a current build, use `--skip-build`; `--scratch-path PATH` selects an isolated
SwiftPM build directory. Compilation and execution have bounded deadlines.
The executable forces headless admission, mounts only unattached NSHostingViews
and NSTextViews, and asserts that no host attaches to a window and no window is
visible. SwiftUI may allocate its own invisible offscreen-rendering helper window.
The replay never constructs or opens an app window and never activates
an app, writes preferences, starts a Runtime or opens a microphone.

Coverage includes the actual Dock/history composer under light → dark → light
inherited environments, native editor appearance and identity, preserved Unicode
drafts, Settings/ordinary-composer theme isolation, and identical rendered opaque capsule fills.
The production caret is exercised under four native appearances: the white
2.6-point core, rasterized halo, 2.4-second breathing cycle, same-line motion,
Reduce Motion and removal. This detects accidental reintroduction of a light
caret or a window-wide theme override.

This is focused integration evidence, not screen acceptance. Actual glass
sampling/refraction, visible glow clipping, animation cadence, focused IME and
sheet presentation still need the hosted graphical suites or later graphical
review. A headless skip of those suites does not certify them.
