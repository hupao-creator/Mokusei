# Overview performance work

Formal baseline: `c17a3fcb270b8d862bbd9cc03ae18c45c4c133fd`, including the reviewed
child-tag opening and replay isolation changes. The initial `73a9929c` checkout
was inspected/built but not measured. Work stays in the detached Overview
worktree; the caller reviews and integrates the independent commits.

## Contract and scenario matrix

Reduce measured work without changing card membership, content, ordering,
geometry, transitions, glass, controls, focus or accessibility. No frame-rate
claim follows from a display-link callback, timer or CPU measurement. Caches
must have explicit ownership, invalidation and storage bounds. Stop optimizing
a path when its repeatable benefit no longer justifies complexity.

| Scenario | Fixed cases | Measurement / correctness boundary |
| --- | --- | --- |
| First / warm content load | 0, 5, 30, 100, 500 catalog cards | Fresh model and repeated catalog admission + Overview projection; excludes process launch, disk cache and first visible frame |
| Overview leave / return | Same catalog, hidden updates, recovery | Production presentation facts + native reading replay; lifecycle and retained content |
| Directory / semantic selection | 10 scopes, up to 5 tags each; Unicode labels | Real selection and model, exact scope/count/order; GUI Chrome separately |
| Child expand / collapse / interrupt | Wide/narrow, short/long labels | Existing production AX and visible pixel replay; preserve the reviewed opening and closing timings |
| Horizontal scroll | Overflowing top and child rows | Mounted production scroll callbacks and input replay; no synthetic OS gesture claim |
| Growth / frequent state updates | One changed card among 5/30/100/500; insertion/removal | Catalog/model timings, retained current content, membership invalidation |
| Layout / reordering / resize | 5/6 mixed footprints; 12/30 equal footprints; wide/narrow | Production solver timings plus packing/capacity/camera replay |
| Appearance / material | Light/dark × glass on/off | Fixed native captures, mounted identity and independent CPU sampling |
| Empty / small / large | Empty catalog, five readable cards, dense collection | Empty state, mounting, layout failure/recovery; all placements remain mounted |
| Search / clearing | Keyword hit/miss and return to browse | Public metadata search and camera/semantic-search regression suite |

Not exposed by the current product: Overview tag CRUD/multiselection, mobile
orientation sensors and Windows UI. This CPU fixture does not measure provider/
network/account latency, process launch, GPU attribution, optical FPS, scan-out
or energy. Window aspect changes cover desktop “rotation”; no device-rotation
feature is invented. Large catalog CPU tests do not assert that 500 cards fit in
one readable viewport. GUI runs require a coordinated exclusive slot; competing
compilers/native replays invalidate stable timing comparisons.

## CPU benchmark

`run.py build --label baseline` links an optimized executable against this
worktree's Release production objects (`-enable-testing` only exposes internal
test seams). It launches no GUI, Runtime, provider or model request. It creates
an isolated temporary profile. `run.py measure --labels baseline,candidate`
alternates AB/BA in fresh processes, after both builds have finished. Raw samples,
environment and process-load observations are retained. Production Codex card
projection, catalog admission, Overview model and layout solver execute directly;
fixture creation and file output are outside measured intervals.

Each model condition has three untimed warmups and repeated timed operations.
Fresh-model admission is reported separately from warm operation. Timings are
monotonic elapsed CPU-path latency, not rendered frames; process user/system CPU
is recorded independently. The baseline binary is preserved across optimization
rounds. No performance threshold is asserted by correctness tests.

## Acceptance

Each round: record bottleneck evidence, change one coherent cost center, run the
same conditions, compare paired medians/ranges and retain regressions/exclusions.
Review the final diff, run `make check`, affected native Overview/reading/glass
replays, and the scenario-specific correctness checks before delivery. The final
report records what actually ran and what remains unmeasured.
