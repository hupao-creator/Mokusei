# Moku input capsule: native expansion

## Scope and ownership

This implementation starts from local main
`5d8ec7da12d5d29869be6ad209126718aa74511c`, then rebases onto local main
`a81321c8b40ee4036f89e99ba33e8a7c915b8321` (the independent timeline glass
control repair) before final compilation. It moves the ordinary
resident/input shell, identity seat travel and input ink opacity to Core
Animation. The SwiftUI Dock still computes fitted destination geometry and owns
its draft, selection snapshots, focus requests, directory completion, native
editor and input lifecycle. There is no new animation phase task or display link.

The native surface has persistent, separately hosted chrome, editor/completion
and identity content. Observable content updates keep each hosting root fixed;
changing input visibility, composer generation or the 260pt compact breakpoint
does not replace the editor's host. The existing draft identity still owns actual
editor replacement. Settings height preferences are consumed inside the chrome
host, and each full-viewport host establishes the named coordinate spaces used
by native anchors and directory completion.

## Shell, face and ink

The ordinary input/resident material uses `NSGlassEffectView` in Clear style,
with native gradient and rim layers matching the existing warm palette. Its
bounds, position, radius, rim, aperture and shadow animate together for 420ms.
Native glass uses AppKit's layer-backed frame animator to propagate sizing into
its material internals. Reading retains the existing emphasized timing function;
the ordinary native morph uses a monotone eased curve in place of SwiftUI's
smooth spring. Exact perceptual parity needs on-screen acceptance.

Note, Settings, Talk and voice keep their existing SwiftUI chrome/material path;
that host stays mounted while ordinary input uses the native glass. The owner
switch settles shell geometry at the shared destination rather than stretching
those reading surfaces. The identity host remains independent of both material
paths. It moves in scene-space points and retains the existing identity flip
inside its seat. Running decorations remain outside the glass/editor clips.

The editor always lays out once at its destination width. Width and shell height
never become a transform on glyphs. A rounded aperture reveals the editor and
completion; the identity is outside that aperture. Collapse fades retained ink
within 120ms, while the existing scene lifetime keeps the editor for 420ms.
Reopening during retirement reuses that editor and its current ink opacity.
The full-viewport host keeps retiring content available beyond the compact
shell's destination bounds, so it cannot be prematurely cut by a shrinking host.

Shell geometry, corner radius, identity position, editor opacity and baseline
translation are sampled from presentation layers on retarget. Before a first
compositor commit, active animations retain their starting pose as a fallback;
a completed animation uses the settled model value. No completion callback can
open input or revive an obsolete draft. Height changes preserve the bottom
editor seat; centred landing changes translate ink without scaling it, with an
opposite mask translation keeping the aperture on the shell. Viewport resize,
column dragging, Reduce Motion, inactive/hidden presentation and detach settle
at the destination. Reduce Transparency selects the existing opaque warm fill.

## Input and entrance

Horizontal column travel and its independent rebound/descent retain their
existing owner. Admission still waits for actual travel completion, then the
Harness flip completion, then input expansion. The existing 180ms automatic
focus delay, explicit focus requests, UTF-16 selection restoration, marked-text
ownership and pinned Agent input rules are unchanged.

Pointer routing, outside-click retention, hover and the note swipe target sample
the native shell's presented geometry. Rounded hit tests use the presented
radius as well as its rectangle. AppKit conversion and the outer travel delta
map scene/window events into that same coordinate space. During ordinary
expansion, visible destination-layout editor controls accept native input;
during actual baseline translation, presses are absorbed because AppKit event
coordinates still refer to model frames. Closing input can be reopened by a
press on its visible shell, including while the retained editor is fading.

The canvas input-region registry has an optional native geometry contract.
Ordinary SwiftUI regions keep their rectangle behavior. The native capsule
registers its live outline and suppresses duplicate destination-only anchors in
its ordinary editor/chrome hosts, so a full-viewport native host does not claim
scroll/pinch input over the surrounding canvas. Legacy chrome retains its
existing region anchors. Native hit testing explicitly bypasses transparent
editor and passive identity hosts in those modes; layer opacity alone does not
retire AppKit hits.

Integration review found that the ordinary native shell bypassed chrome hit
testing altogether, preventing closed-input Stop and idle voice controls from
receiving presses. The integrated version routes those controls to their
existing chrome host once the presented shell agrees with its model frame.
During morphs the visible shell absorbs presses; closing-input retirement still
uses the shell's reopen path. This correction is based on static routing review,
not a GUI interaction measurement.

The integrated source with that correction passed the headless Debug `Mokusei`
product build (84.25s), Swift frontend parsing of the four changed Swift files,
diff whitespace review and the new local documentation links. Build output is
in `/tmp/mokusei-ca-input-review-build.log`. No tests, graphical replay or CI
were run. The Go-only pre-commit lint is omitted under the caller's focused
sprint scope. These checks do not certify glass rendering, pointer delivery,
selection, focus or IME behavior on screen.

## Sprint validation and limits

Validation is headless product compilation, Swift syntax parsing, diff review
and local documentation-link checks. No tests are added; no test suite, replay,
graphical acceptance or hosted CI is run. The first sandboxed dependency
resolution failed; a permitted build with a temporary cache resolved the pinned
dependencies and compiled the Debug product. Review then addressed completion
layer order, presentation-radius reversals, native navigation regions, Settings
preference delivery, invisible-host hit routing and the retiring-shell click
reopen gate before rebuilding. The final
combined-source Debug `Mokusei` build passed in 28.45s; syntax, diff and local-link
checks also passed. No compiled source changed after that build.

Rendered glass/corner continuity, visual timing parity, rapid user-driven
reversal, real pointer selection/IME/candidate windows, focus, narrow/zoomed
windows, material handoff and physical swipe/Force Touch still need on-screen
acceptance. No profiling was performed and no performance improvement is claimed.

Delivery is a detached local commit only: no push, branch/ref change or main
integration. The caller owns integration. The read-only remote gate inspection
found an effective PR rule requiring resolved review threads; it did not return
a required-status-check rule. Historical CI results do not certify this revision.
