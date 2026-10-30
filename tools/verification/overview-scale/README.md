# Overview card-count scale harness

Verification-only measurement of how the native Overview behaves as the catalog
grows from 10 to 500 ordinary Agent Threads. It links this worktree's Release
production objects and runs the production `NativeWorkspaceModel`,
`NativeOverviewWorkspaceModel`, `NativeOverviewCanvas`,
`NativeOverviewWorkspaceView`, `HarnessThreadCard`, layout solver, camera and
motion policy. It never starts the Runtime, opens a user profile or sends a
model request.

## Build

```sh
python3 tools/verification/overview-scale/run.py build --label formal
python3 tools/verification/overview-scale/run.py build --label diag --diagnostics
```

`formal` has no per-frame instrumentation and supplies wall/CPU/memory numbers.
`diag` adds `-DOVERVIEW_PERF_DIAGNOSTICS` and counts actual `TimelineView`
callbacks per card layer, motion samples, `from == to` samples, projection cache
hits/misses, retained snapshots and layout comparison calls. Do not mix timings
from the two builds: diagnostic atomics add work.

Both builds use SwiftPM Release (`-O`) with `-enable-testing` only to expose
internal verification seams. The app bundle is ad-hoc signed, isolated under
`.build/overview-scale/<label>`, and is launched through LaunchServices so the
window can become key.

## Modes

```sh
# Pure production solver matrix: N=10/40/100/500, initial/content/insert/delete/
# grow/shrink/mixed/resize/capacity and repeated same-scene resizes.
run.py run --label formal --mode layout --output /absolute/new/layout.json

# L1 production admission + model projection: first/warm install, K=1 and K=0
# content transactions, 10/20 Hz fixed-clock updates, filters/search/leave.
run.py run --label formal --mode model --n 40 --output /absolute/new/model-40.json

# L3 JSON parse, RuntimeState.applying, RuntimeClient.acceptMutation delivery,
# actor preparation/catalog install and model projection.
run.py run --label formal --mode runtime --n 40 --output /absolute/new/runtime-40.json

# GUI: actual visible window. The production workspace view supplies Chrome,
# Canvas, glass shells and HarnessThreadCard content.
run.py gui --label formal --mode gui-first-load --n 40 --output .../first-load-40.json -- --scenario capture
run.py gui --label formal --mode gui-idle --n 40 --seconds 60 --output .../idle-40.json
run.py gui --label formal --mode gui-update --n 40 --hz 10 --seconds 20 --warmup 5 \
  --target visible --running none --output .../update-40.json
run.py gui --label diag --mode gui-update --n 40 --hz 10 --seconds 5 --warmup 2 \
  --target offscreen --running offscreen --output .../update-diag-40.json
run.py gui --label formal --mode gui-motion --n 40 --scenario remove-all --output .../motion-40.json
run.py gui --label formal --mode gui-update --n 40 --sequence no-change --output .../update-k0-40.json
run.py gui --label formal --mode gui-motion --n 40 --scenario remove-all \
  --overview-visible 0 --output .../motion-hidden-40.json
```

`--sequence no-change` delivers valid revision-only mutations with no card
content delta (the K=0 control). `--overview-visible 0` hides the production
canvas after baseline settle, so the same membership change exercises layout and
model delivery without presentation policy waits.

If LaunchServices launches from the build tree stall in dyld (observed on this
host when the build and framework paths live under `~/Desktop`), use
`relocated.py` in place of `run.py gui`. It copies the signed bundle to
`/tmp/MokuseiOverviewScale/<label>`, makes the bundled framework the first
rpath, launches with `open -n`, then activates with `open -a`; the original
build metadata and production source hash are retained in the result sidecar.

`gui-idle` runs no high-frequency heartbeat. `gui-update` and `gui-motion` use a
main-actor wake probe and retain every late wake; the probe is reported as a
responsiveness proxy, not rendered FPS. `gui-first-load --scenario capture`
takes WindowServer screenshots through ScreenCaptureKit and records the first
pixel-change timestamp; when screen-recording permission is unavailable the
error is retained and proxy timestamps remain explicitly labelled.

## Fixed viewport

For `gui-update` the harness uses the production manual-camera path to frame the
4×2 block at the layout origin. The same camera transform and the same block
shape apply to N=10/40/100/500, so fully visible cards and inter-card geometry
are held fixed while the remaining cards stay outside the viewport. The raw
`visibleFull`, `visiblePartial` and `visibleArea` values are retained; a shape
that cannot supply the block (for example a two-row 10-card layout) is reported
rather than silently treated as matched.

## Evidence and limits

Each run writes JSON with environment, window state, per-sample resources,
wakeup counters, diagnostics, layout counts, items/mounted identities and raw
per-update samples. GUI runs also write the bundle executable hash in
`build.json` and Windows screenshots when capture succeeds. `metrics.py`
extracts the report's selected medians, actual rates and per-update diagnostic
deltas into `summary/key-metrics.json`; `analyze.py` writes the complete CSVs.

The harness does not measure GPU time, WindowServer cost, optical FPS/energy,
physical input or Runtime transport/network. `xctrace` traces are collected
separately and are not mixed into formal timings. Export the Time Profiler table
with `xcrun xctrace export --input <trace> --xpath
'/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'` and aggregate
it with `summarize_time_profile.py`. Raw `.trace` files capture the launching
shell environment, so the evidence copy is removed after export; the exported
XML and summary contain only samples/symbols. The `overview-input` and
`overview-layout` tools remain the authorities for their existing scenarios;
this tool adds the N/K matrix and mounted production-card path.
