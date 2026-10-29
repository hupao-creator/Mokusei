# Windowless scrollbar replay

Run `python3 tools/verification/scrollbars/run.py` on macOS. It compiles the
production shared viewport and WebKit style sources with a small integration
driver into a temporary executable, then runs it with `MOKUSEI_TEST_HEADLESS=1`. No window is
created, no preference is written and no other application receives input.

The driver checks native scroller targets, accessibility role and axes,
document/clip identity, selection and offsets through repeated styling,
programmatic scrolling, appearance variants and a preferred-style notification.
Normal and highlighted slots must paint no pixels into an offscreen bitmap in
both legacy and overlay styles. An unrelated scroll view must retain its original
configuration. Compilation and execution have separate
timeouts and a failed assertion exits unsuccessfully.

The windowless WKWebView fixture checks the production user script in the main
document and a child frame, page-authored tracks, dynamic overflow, restrictive
inline-style CSP, unchanged viewport geometry, both scroll axes and textarea
selection. It uses nonpersistent data and local HTML, without network pages.
WebKit still needs access to its system XPC services; a sandbox denial or timeout
is incomplete execution, not a pass. Run with the environment's normal WebKit
service access while retaining the no-window constraint.

This checks native control state and track-part pixels, not composed
overlay/WebKit pixels or physical input. It does not simulate a real
preference/device change; the notification reuses the current
system preference. Mounted SwiftUI nesting, hover, fade timing, light/dark and
accessibility pixels and mouse/trackpad feel require the existing
graphical suites or a visual session. See the [shared inventory and integration
contract](../../../app/macos/Sources/Shared/PluginUI/README.md#scrollbars).
