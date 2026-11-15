# Running Sidecard entry: measurement and preparation

The new `reading.active-open` workload opens one completed 8 KiB main reply
beside a running execution containing one settled progress message. It holds
that execution without new output until capture and its observation tail finish.
Public scoped content and source timestamps verify both identities and the
running state. Fixture setup, returning to Overview and offline OCR are outside
measurement. This is a warm open, not application startup.

## Initial candidate: paired Release observation

Both signed Release artifacts use the same calibrated external collector, a
1280 × 820-point window, 8,552-byte main reply and fixed 622-byte Sidecard reply.
There is one trial per artifact, with a 10-second formal interval and 3-second
tail. See the [machine-readable record](reader-active-opening-20261114.json)
for binary/report digests, raw evidence paths, scroll results and resource roles.
These candidate production sources match `536f2a8f`; this PR is benchmark-only
and does not include the separate Overview badge work.

| Observable endpoint | Before | Candidate |
| --- | ---: | ---: |
| First main body checkpoints | 560–764 ms | 614–813 ms |
| First Sidecard body checkpoints | 711–915 ms | 614–813 ms |
| Both columns' body anchors settled | 711–915 ms | 763–961 ms |
| App CPU during formal interval | 3.192 s | 3.193 s |
| Sampled peak app footprint | 92.6 MiB | 91.7 MiB |

The latency intervals overlap, and CPU is unchanged. This does **not** establish
a throughput, frame-rate or opening-latency improvement. All three scheduled
scroll probes moved in the correct direction in both trials; business outcome
passed. Overall measurement remains incomplete because process exit/lifecycle
CPU coverage and independently validated native hitch collection are unavailable.
Requested capture cadence was 20 Hz; actual delivery was about 6.6 Hz (92/93
frames over the observation), so it cannot certify short stutters or 60 Hz pacing.

## Preparation decision

The existing text views already retain up to eight width/scale height measurements.
A separate diagnostic sample of baseline entry recorded 90 `text.layout` calls
with 9.25 ms total and 0.48 ms maximum. This covers instrumented TextKit layout,
not all SwiftUI layout. Sampling substantially disturbed opening preparation;
its timing/resource results are excluded from the comparison above.

The initial candidate prepared main at the pending execution's actual destination
width (including 1:1). The existing Workspace replay rejected it: title handoff
moved 38 points, violating its measured-anchor contract. That early main-width
proposal was removed; these paired results describe the rejected experiment,
not final production performance.

After the user requested closure on the AttributeGraph fix, all experimental
reader preparation and ink-admission changes were also removed. Final production
changes are limited to the focused-parent hide repair; the new benchmark remains.
No speculative width cache or preloading policy is shipped. Existing live resize
and per-view eight-width measurements remain unchanged.

## Moku and AttributeGraph

The raw frames include Moku's compact execution state, horizontal movement and
composer expansion. In these two captures, the first visible composer ink is
around 1.36 s before and 1.27 s after; by about 1.7 s both appear expanded.
These are sampled visual observations, not focus readiness or frame-pacing
measurements. No independent Moku improvement is established by this change.
The production horizontal animation is a 520 ms native keyframe translation with
a 2.5%/6 pt maximum settling excursion, followed by the existing 420 ms composer
expansion; outdated spring and 380 ms descriptions were stale. Choreography is
delivered separately in PR4 and is outside this benchmark change.

The [parallel AttributeGraph investigation](attributegraph-focus-20261114.md)
reproduced focused-parent hide reentrancy (35 warnings in five iterations) and
verified the narrow deferred-hide repair (zero in the same five iterations).
The Release benchmark logs have no such warning before or after, so that repair
must not be used to explain a benchmark speedup. The separate historical burst
near Moku state changes remains unattributed.

## Validation

The intermediate integrated candidate passed 31 reading scorer/provider controls,
115 shared adversarial/contract controls, the 10-test Workspace suite, 12 reading
presentation tests and five parameterized Sidecard/input test functions (including
live resize). Those native runs are candidate evidence, not final-source certification.
The first candidate Workspace run failed the heading-handoff assertion (38pt)
and one Close assertion. Removing early width preparation resolved both in the
next run; the second failure has no separately proven root cause.

Final focused-parent verification after restoring the original reader preparation
policy passed all 10 Workspace tests (26.181s). An earlier Sidecard click timeout
and its incomplete diagnosis remain recorded in the AttributeGraph report.
The final reading-presentation replay also passed 12/12 tests (17.654s). The final repeated Release
build was explicitly stopped at the user's request to close this investigation;
no final performance improvement or frame-rate certification is claimed. Earlier
packaging attempts also rejected concurrent source/input changes and were rebuilt
successfully after freezing inputs. No remote push or CI submission is part of
this local-only delivery.
