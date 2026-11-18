# Overview layout and Super Thread presentation

The [Overview guide](../app/macos/Sources/Host/Overview/README.md) owns membership,
filtering, camera and layout. [Report](../internal/plugins/applications/report/README.md)
owns documents, exact execution references, binding and cover admission.

## Layout and camera

The logical 1×1 grid cell is 320×196pt with 16pt gaps; 1×2 is 320×408pt and
2×1 is 656pt wide. All window sizes share these metrics at the default 1× camera.
In a 1512×900pt client area with filters and the idle Moku Dock, the framing
region is 1384×690pt inside a card viewport with equal 82pt top and bottom
insets. Twelve 1×1 cards occupy four columns and three rows (1328×620pt).
At 1× the card envelope has 140pt above and below it, and card text keeps its
declared point sizes.

The pure solver returns placements and bounds from one input.
Mixed spans can fill gaps within horizontal or vertical bands. The four-card
mix of a wide card, a tall card and two single cells fills a 3×2 or 2×3
rectangle according to the usable viewport. FitAll centers the card union at
the configured floor and cap. The presentation camera shows the first row
at the top of the card viewport when the centered layout is too tall.
Cards are clipped to the card viewport, and overflow is reachable by panning.
Layout and camera targets are latest-wins, fenced by identity and
revision. Content-only updates do not restart structural motion. Interrupted
travel samples current poses; hidden work coalesces to the latest target.
Automatic focus can refit after membership shrinks, including increasing scale;
a blank click restores automatic FitAll rather than preserving an obsolete
smaller scale indefinitely. Manual pan/zoom remains a distinct ownership mode.

Agent card titles reserve one line and truncate at the tail so title swaps do
not shift model, time or body content. Empty, missing and error facts keep their own
presentation; zero Git line totals omit the extension, while unavailable totals
do not become zero. Read-only ink does not inherit disabled-control dimming from
Moku's input overlay. Canvas/card accessibility groups precede gesture/action
attachment so repeated descendants do not each create an open action.

Source: [layout](../app/macos/Sources/Host/Overview/NativeOverviewLayout.swift),
[camera](../app/macos/Sources/Host/Overview/NativeOverviewCamera.swift),
[card text](../app/macos/Sources/Shared/PluginUI/Cards/ThreadCardText.swift).

## Cover dimensions and ownership

The passive cover's logical viewport is 360×308 CSS pixels. Native height is
width × 308/360: 273.8pt at 320pt width, followed by a 4pt gap and 130.2pt metadata
region. One outer 1×2 card owns open/archive actions; introduction display allows
three lines. The agent prompt asks for concise text suited to two lines; this
writing guidance is distinct from the three-line native limit.

`coverHTML` persists separately from report HTML and has its own revision. Catalog
carries only that revision; mounted covers query the matching source. A bounded
16-entry source/revision/appearance cache holds markup and a final-frame poster,
not live browsers. Nonpersistent WebKit disables author scripts, navigation,
external resources and input. Invalid/missing cover content leaves native actions
usable. Authored internal whitespace is content, not an inferred crop or padding
error; the host scales the full logical canvas uniformly.

Source: [cover](../app/macos/Sources/Plugins/Applications/Report/NativeReportCover.swift),
[card](../app/macos/Sources/Plugins/Applications/Report/NativeReportCard.swift),
[Report model](../internal/plugins/applications/report/model.go).

## Playback and collections

Finite CSS timelines finish within six seconds. A recognizable title/key visual
is present at time zero and the final composition communicates the result.
Standalone cards hold the last frame five seconds and replay. Collection covers
play once per selection and hold until selection changes; reselecting gives a
new run. The 11s carousel dwell begins only after entrance and actual WebKit
playback acknowledgement. Inactivity, hidden viewports and cover gestures pause
motion. Neighbor preloads stay at the beginning. Theme is source-keyed and live.

Carousel travel and metadata ink share 460ms easing; backward motion mirrors the
shared ink mask. Open/archive recheck the actual selection and motion owner,
including actions from an already-open native menu. Hover mounts the bottom
capsule over the fixed cover viewport without shifting the cover, metadata or
upper-right count. Retained focus and menu tracking do not extend hover
visibility. The hovered controls retain native keyboard/accessibility operation; on exit
the entire bottom control surface unmounts, including hit/AX children. Menu
tracking pauses automatic paging. Stale removed-member actions are rejected.

Collections are a native presentation of real Report identities, not Runtime
entities. Close/read eligibility and report content fingerprints belong to
profile-local reading state. Selection alone is not a read event. A content
fingerprint change revokes old eligibility; source status/tag propagation alone
does not. The member panel's archive control is icon-only at the upper-right
corner and invokes the same atomic archive operation as the card menu. Fewer
than two visible members dissolves a collection without deleting its survivor.

Source: [collection](../app/macos/Sources/Plugins/Applications/Report/NativeReportCollection.swift),
[members](../app/macos/Sources/Plugins/Applications/Report/NativeReportCollectionMembers.swift),
[playback](../app/macos/Sources/Plugins/Applications/Report/NativeReportCoverPlayback.swift).

[Geometry and mounted-state properties](../app/macos/Sources/Host/Overview/README.md#property-boundaries)
cover bounded generated layouts and latest-state convergence. They do not cover
Report content, physical gestures or appearance. Current [external benchmarks](../tools/benchmarks/README.md) measure
fixed-count app workloads; internal CPU probes do not establish visible frame
pacing, GPU attribution or complete interaction coverage.
