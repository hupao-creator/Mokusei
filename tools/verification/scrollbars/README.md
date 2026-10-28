# Windowless scrollbar replay

Run `python3 tools/verification/scrollbars/run.py` on macOS. It compiles the
production shared viewport source with a small AppKit integration driver into a
temporary executable, then runs it with `MOKUSEI_TEST_HEADLESS=1`. No window is
created, no preference is written and no other application receives input.

The driver checks native scroller targets and axes, document/clip identity,
selection and offsets through repeated styling, programmatic scrolling,
appearance variants and a preferred-style notification. An unrelated scroll view
must retain its original configuration. Compilation and execution have separate
timeouts and a failed assertion exits unsuccessfully.

This checks native control state, not rendered pixels or physical input. It does
not simulate a real preference/device change; the notification reuses the current
system preference. Mounted SwiftUI nesting, hover, fade timing, light/dark and
accessibility pixels, WebKit overflow and mouse/trackpad feel require the existing
graphical suites or a visual session. See the [shared inventory and integration
contract](../../../app/macos/Sources/Shared/PluginUI/README.md#scrollbars).
