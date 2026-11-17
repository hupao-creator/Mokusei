# Animated Super Thread covers

The cover is a silent, passive HTML/CSS composition, authored by Super Thread
Agent from report evidence. Its finite animation includes all delays and
repetitions and lasts at most six seconds: the carousel's eight-second dwell
minus at least a two-second final-frame hold. Collection covers play the complete
admitted timeline once per selection, then hold their final composition until
paging. Short covers do not replay during that dwell. Returning to the same cover
after another selection starts a new run. Standalone cards retain their repeating
animation/two-second-hold cycle.

## Ownership and timing

The Report plugin owns the live WebKit document and a bounded markup/poster
cache. Author JavaScript, SVG, external resources, navigation and input remain
unavailable. A trusted isolated content world admits and controls the CSS effects;
it supplies no application bridge to the document. Native Swift tasks own the
cycle/hold timers, because page timer callbacks do not run while author
JavaScript is disabled. Its only injected styles
pause CSS effects and suppress transitions, without changing cover layout.
WebKit's computed effect timing is the rendering boundary: infinite iterations
become one iteration, an oversized timeline is accelerated uniformly to six
seconds, and final styles remain filled. Empty timelines remain static.

Preloaded neighbors stay at the beginning. Outgoing covers freeze their current
pose while sliding away. Incoming covers start only after native travel ends;
the carousel waits for WebKit's playback acknowledgement before starting its
eight-second dwell. Failed covers still admit navigation and automatic advance.
Visibility/activity/gesture pauses preserve elapsed motion or hold time; resume
does not count hidden wall-clock time. The carousel starts a fresh dwell on
resume. Reselection resets the cover for a fresh first run. Collection completion
survives hover chrome changes, focus, ordinary redraws and pause/resume; a completed
or reduced-motion presentation cannot restart before reset. New cover revisions,
appearance-specific documents and a newly mounted collection have new document
lifetimes and therefore new playback admission.

Reduce Motion shows the completed composition without a playback timer. The
cache captures a final-frame poster before live admission and leaves it under
the WebKit surface through native layer commits. Only source/revision/appearance
matched images are reused; browsers do not survive card lifetimes. The existing
16-entry cache and four-cover collection mounting bound remain unchanged.

Only the effects captured by `document.getAnimations()` at document-end admission
participate in this playback policy, including their finite delays/repetitions.
CSS transitions remain suppressed. Author JavaScript/WAAPI, SVG/SMIL, media and
external resource animations are unavailable under the existing admission/CSP;
this change does not add control for effects created after admission. No cover
prompt, markup, report data or machine accessibility setting is rewritten.

The Agent instructions and both report write tools describe purposeful motion,
finite CSS keyframes, a recognizable title/key visual from time zero, complete
final compositions, light/dark palettes and
host-owned replay. Report-body ELI5 and safe-area rules remain separate. No bulk
regeneration or data migration runs.

## Verification

`NativeReportCoverTests` mounts production covers and collections with local
HTML fixtures. It checks rendered first/middle/final/restarted pixels, the
two-second hold, preload/reset, visibility/activity pause, the reduced-playback
poster, theme/remount behavior, oversized/infinite author timing, delayed cover
admission, eight-second dwell selection replay and a pending preload failing after selection. The reduced-playback input
is fixture-driven; it does not modify the machine's accessibility preferences.
WebKit snapshots prove authored pixels, not WindowServer intermediate-frame
continuity; that visual boundary requires the separate presentation capture.
These methods belong to the mandatory `native/report-covers` AppKit owner.
Ordinary SwiftPM leaves WebKit's document hidden and its animation timeline
pending, so its process is not a valid playback host. The ownership registry
excludes these methods from ordinary execution and requires their exact passing
outcomes and markers in the native replay; no test-level skip is added.

The collection one-shot change was locally checked with headless compilation and
a temporary diagnostic executing the actual native playback controller against
an in-memory script-command sink. It covers completion, redraw deduplication,
pause/resume, reset/reselection, cancellation, Reduce Motion and unchanged
standalone repetition. This does not validate WebKit rendering, native IPC timing
or continuous display frames; the graphical owner above was not run in that sprint.

The existing Runtime report-scope replay checks the actual injected create and
update tool contracts. The standalone carousel demo continues to use the same
production views with animated fixtures.

Real-model acceptance uses the installed OpenCode CLI's native runtime and
`opencode-go/deepseek-v4.1-flash`, with completed historical user/assistant
records as evidence. Export the production Report participant's actual
instructions and tool schemas; capture writes in isolated acceptance storage
through the production HTML admission functions. Mount the unchanged generated
cover HTML in `NativeReportCard` and `NativeReportCollection`, then inspect
first/middle/final/hold/restarted frames and both palettes. Keep source session
identities, model/version, generated HTML, timings and screenshots in ignored
local evidence, not repository fixtures containing private history. This
explicit real-model acceptance supplements the deterministic native CI owner.

The initial real-model pass exposed empty opening compositions. The generation
contract now requires a recognizable title or key visual from time zero, and
the same model revises the covers before another rendered inspection. Carousel
control placement/occlusion is deferred at the user's request. ScreenCaptureKit
recording was denied by this machine's TCC; WebKit snapshots and a separate
native UI inspection do not certify continuous WindowServer frame continuity.

Focused command:

```sh
python3 tools/verification/reading-presentation/run.py --report-covers
```

User delivery is local main for acceptance, without a remote push or hosted CI.
Final local results and any remaining capture limitations are recorded at
delivery; unexecuted checks are not represented as passing.

The controller uses [Web Animations timing](https://www.w3.org/TR/web-animations-1/)
and [WebKit's isolated script evaluation](https://developer.apple.com/documentation/webkit/wkwebview/evaluatejavascript(_:in:in:completionhandler:));
[author script execution stays disabled](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript).
