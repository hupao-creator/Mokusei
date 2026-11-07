# Windowless scrollbar replay

Run `python3 tools/verification/scrollbars/run.py` on macOS. It compiles the
production shared viewport, its layout-diagnostics dependencies and WebKit style sources with a small integration
driver into a temporary executable, then runs it with `MOKUSEI_TEST_HEADLESS=1`. No window is
created, no preference is written and no other application receives input.

The driver checks native scroller targets, accessibility role and axes,
document/clip identity, selection and offsets through repeated styling,
programmatic scrolling, appearance variants and a preferred-style notification.
Normal and highlighted slots must paint no pixels into an offscreen bitmap in
both legacy and overlay styles. Vertical and horizontal content are measured just
below, exactly at, and just above the overflow threshold: the legacy gutter and
clip size must not change, the resident scroller must paint nothing while content
fits, and only content that can scroll may draw a knob. A location that prefers
overlay indicators instead keeps the resting scroller blank at every content
height, because AppKit fades that knob in only during scrolling; the runner's
preferred style therefore selects which observable applies. Overlay scrollers
must never consume layout space. An unrelated scroll view must retain its original
configuration. Compilation and execution have separate
timeouts and a failed assertion exits unsuccessfully.

Mounted windowless SwiftUI TextEditor and List controls overflow inside the
production NativeScrollView. The production control-scoped modifier must retain
native target/action/AX role, editor binding updates, row/text selection and
scroll offsets through preference notifications, control replacement and List
viewport width while rows cross its own overflow threshold. An adjacent unstyled
editor must keep its original scroller. These control-adapter checks remain
windowless, without a popover or input injection.

The plain SwiftUI viewport checks run once in the ordinary graphical suite as
[`NativeScrollViewportTests`](../../../app/macos/Tests/Integration/Host/NativeScrollViewportTests.swift).
CI 361 observed a 0×0 document in both the styled and unstyled windowless hosts,
even though their native viewports were 360×300; that setup could not establish
real content overflow. The relocated fixture uses two nonoverlapping visible
360×300 windows. Each 80→900→80 content transition waits up to three seconds for
both actual content-height callbacks, positive document/viewport dimensions and
both native overflow states to match the requested phase, with the production
trackless scroller installed and the reference's real scroller still unstyled,
then checks the original overflow, autohiding, knob, scroll-offset and loaded
clip/document-width comparisons. Geometry is retained on readiness or assertion
failure. Loading longer content may allocate a legacy gutter; scrolling that
loaded content in either direction must preserve both widths. For the runner's
preferred style, its scroller must paint only while scrolling is possible
(legacy) or stay blank at rest (overlay). The windowless AppKit and scoped
TextEditor/List checks retain their separate resident-gutter policy. No second
launcher or native owner runs the relocated graphical method.

The windowless WKWebView fixture checks the shared styling script in the main
document and a child frame, page-authored tracks, dynamic overflow, restrictive
inline-style CSP, native thin viewport geometry, both scroll axes and textarea
selection. After the actual 420×280 viewport is ready, decoration must preserve
the exact geometry of WebKit's independent width-only `thin` reference; the
production policy intentionally replaces the page's initial `auto` metrics.
The main document, overflow pane, textarea and child frame must all compute
`thin`. The original production sheet is restored in `finally`; the exact
before/reference/after dimensions are retained in stderr.
A black-body/white-text page with no color-scheme must retain a white
viewport and overflow thumb; a nested white region must get a black thumb. Body
theme changes must refresh the viewport color while all tracks stay transparent.
Changing the actual WKWebView frame crosses a CSS width media query in both
directions. Inserting, editing and removing head styles, and inserting a body
style must refresh the viewport foreground. A test-only URL scheme holds an
actual CSS resource until the insertion refresh has completed, then releases it
to independently verify the load notification (no synthetic load event or
network server). Real computed-style calls are counted in the script's isolated
world: ordinary content/meta mutations must cause zero reads; one synchronous
resize/style burst must cause one read, including after the resulting root write.
These are computed-style assertions, not final composited-pixel claims. The
fixture uses nonpersistent data and local HTML, without network pages. Its
all-frame injection does not verify the production Report document-ownership guard
or the absence of styling in external Browser pages.
WebKit still needs access to its system XPC services; a sandbox denial or timeout
is incomplete execution, not a pass. Run with the environment's normal WebKit
service access while retaining the no-window constraint.

This checks native control state and track-part pixels, not composed
overlay/WebKit pixels or physical input. It does not simulate a real
preference/device change; the notification reuses the current
system preference. Complete application mounting, hover, fade timing, light/dark and
accessibility pixels and mouse/trackpad feel require the existing
graphical suites or a visual session. See the [shared inventory and integration
contract](../../../app/macos/Sources/Shared/PluginUI/README.md#scrollbars).
