# Canvas pan frame and cost measurement

```sh
./scripts/go.sh run ./cmd/mokusei-dev bundle --channel development   # Release bundle
python3 tools/verification/overview-pan/run.py \
  --app "app/macos/dist/Mokusei Native Dev.app" \
  --source-profile "$HOME/Library/Application Support/Mokusei Native Dev" \
  --workdir /private/tmp/mokusei-pan --label release --pairs 3 \
  --baseline tools/verification/overview-pan/baseline.json --enforce regression
```

Only a signed bundle is accepted. A raw SwiftPM executable is not the product:
it has no `Info.plist`, no bundle resources, and its window may not be
high-resolution capable, which quarters the rendered pixels and makes a slow
build look fast. The runner opens the bundle with `open -n` so the window is
activated the way a user's is, reads the build provenance and window geometry
for the report, and fails if the two conditions or repeated runs disagree on
that geometry.

Dragging the Overview canvas must not get slower as the catalog grows. This
runner compares two catalog conditions on the **same** real profile — every
thread card visible versus a single card — and reports both the composed frames
and the main-thread cost of one camera update.

## Measurement contract

The profile is copied first: `sqlite3 .backup` for the store (one consistent
snapshot while the owner app keeps running) and APFS clone copies for Harnesses,
attachments, reading caches and drafts. The copy lives under `--workdir`; the
user's daily profile is never opened by the launched app. Conditions come from
`--conditions` (a JSON list of `{label, filterId}`); the default pair is the
whole catalog (`filterId: null`) and the single report-tagged card
(`semantic:inbox:研报`). Expected card counts are **observed**, then asserted
against the settled snapshot, so a profile that changes shape cannot silently
change the workload.

Each condition is measured in two independent phases:

| Phase | Observation | Why it is trustworthy |
| --- | --- | --- |
| cost | Production `overview.pan` driven through the automation socket at an unbounded request rate; per-request service time on the UI main actor | The socket round trip is served on the same main actor as the drag gesture; the median is the marginal cost of one camera update. Absorbs >1000 requests/s on an idle canvas, so the driver never becomes the limiter |
| frames | `xcrun xctrace record --template 'Animation Hitches' --attach <pid>` while the canvas is dragged for the whole recorded window | Frame lifetimes, per-surface frame intervals and hitches come from the compositor, not from a product timer. Any build can be certified with the same numbers |

Every phase asserts `ok` on each action and requires the camera to have moved, so
a rejected action can never be reported as a fast one. Conditions run ABBA
across `--pairs`; medians are reported per condition plus the wide/narrow A/B
ratio.

Measured per condition: `panP50`/`panP95` (main-actor cost of one camera update),
`framesPerSecond`, `intervalP50`/`intervalP95`/`intervalMax`, `longIntervalRatio`,
`lifetimeP50`/`lifetimeP95`, `renderP50`, `hitches`, `hitchRatio`, `cpuMean`/
`cpuMax`, and per-surface frame counts.

Deliberately **not** used as evidence: displayed surface swaps per second (equal
in both conditions — the compositor keeps presenting while the app coalesces),
Animation Hitches frame colors (they identify surfaces, not frame health), and
Release hitch counts alone (bimodal). A headless or offscreen run cannot certify
anything here: the numbers require a real WindowServer session and a visible
window.

## Where the cost is

Sampling the Release application while this runner drives the camera shows the
main thread inside SwiftUI's graph flush for roughly half of its busy time
(`NSHostingView.beginTransaction` → `GraphHost.flushTransactions` →
`AG::Subgraph::update`), and inside that flush in `ForEachChild.updateValue`,
`_ZStackLayout.sizeThatFits`, `GeometryReaderLayout.placeSubviews` and each
card's `onGeometryChange` viewport read. A camera change therefore re-lays out
the whole canvas instead of only moving it: the semantic plane applies the
camera with layout-affecting `scaleEffect`/`offset`, and every card re-reads its
own geometry per frame. The decorative shell plane already avoids that path with
`OverviewCameraAffineEffect(...).ignoredByLayout()`; moving the semantic plane
onto it requires moving the per-card viewport decision into the canvas, because
cards currently derive their visibility from that geometry read.

## Acceptance

`--enforce target` requires the A/B ratios to reach parity: `panP50` ≤ 1.1,
frames/s ≥ 0.95, CPU ≤ 1.5. `--enforce regression` compares each condition
against the retained `baseline.json` (`panP50` ≤ 1.15, frames/s ≥ 0.95, CPU ≤
1.15) and fails if a condition's card count changed. `--enforce both` runs both
checks. Nothing is asserted unless requested, so a run can be recorded before a
fix lands.

## Retained baseline

`baseline.json` — packaged Release bundle (`bundle --channel development`) built
from this tree, opened with `open -n` so its window is activated, on an Apple M1
Pro with macOS 26.5.1 and the built-in display. Three ABBA pairs, four-second
drags at 120 Hz, `--label release`, window 1283×905 points. The store held 10
cards for the whole catalog (6 agent threads and 4 report documents) and 1
report document for `研报`.

| Condition | cards | panP50 | frames/s | interval p95 | CPU mean |
| --- | --- | --- | --- | --- | --- |
| all | 10 | 4.35 ms | **41.2** | 133.62 ms | 70.0 % |
| yanbao | 1 | 0.14 ms | 119.4 | 33.87 ms | 33.6 % |
| A/B | | **31.1×** | **0.35×** | | 2.08× |

Dragging the whole catalog renders at a third of the single-card rate while
costing 31× the main-thread time per camera update, and that is the reported
symptom: the Release application visibly stutters with every card visible and
not with one. Earlier numbers taken from a raw SwiftPM executable reported
117–119 frames/s for the same content; that build has no `Info.plist` and its
window is not high-resolution capable, so it rendered a quarter of the pixels.
Do not measure a raw executable, and do not compare numbers recorded before this
runner required a signed bundle.

## Acceptance

`--enforce target` requires the A/B ratios to reach parity: `panP50` ≤ 1.1,
frames/s ≥ 0.95, CPU ≤ 1.5. `--enforce regression` compares each condition
against the retained `baseline.json` (`panP50` ≤ 1.15, frames/s ≥ 0.95, CPU ≤
1.15) and fails if a condition's card count changed. `--enforce both` runs both
checks. Nothing is asserted unless requested, so a run can be recorded before a
fix lands.

## Retained baseline

`baseline.json` — Release executable built from this tree on an Apple M1 Pro,
macOS 26.5.1, built-in display, three ABBA pairs, four-second drags at 120 Hz,
`--label release`. The store held 10 cards for the whole catalog (6 agent
threads and 4 report documents) and 1 report document for `研报`.

| Condition | cards | panP50 | frames/s | interval p95 | CPU mean |
| --- | --- | --- | --- | --- | --- |
| all | 10 | 3.93 ms | 117.4 | 33.87 ms | 66.4 % |
| yanbao | 1 | 0.14 ms | 119.4 | 38.92 ms | 23.5 % |
| A/B | | **28.1×** | 0.98× | | 2.83× |

These ratios are the defect this runner exists to remove: one camera update
costs about 0.38 ms of main-thread time per additional card, and the whole
catalog drags at 66 % of a core against 23 % for a single card. The Debug
development application is not part of the retained baseline; rebuild it and
pass its bundle to `--app` when its frame pacing matters, because an earlier
Debug run driven by the snapshot-shaped bridge was charged for work no drag
gesture performs and is not retained evidence.

Frame-rate claims require this runner's compositor tables; a display-link
callback, a timer or a CPU measurement alone does not establish them.
