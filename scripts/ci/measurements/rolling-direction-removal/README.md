# Removal of the unstable incoming-digit direction check

The user explicitly authorized removal of the repeatedly unstable test
`RollingNumberCellTests.incomingDigitsMoveDownFromAbove()` after it blocked
complete CI. In [PR #225 run 41422140080](https://github.com/hupao-creator/Mokusei/actions/runs/41422140080),
the actual synthetic merge `2a75d9202b232175e07de1e3b36e31cd7817384c`
failed the unchanged assertion: `bestShift = +11`, expected `< 0`. The native
owner exited 1. The [during](during.png) and [settled](settled.png) bitmaps,
[row and timing receipt](measurements.json), [native log](rolling-numbers.log),
[native report](native-report.json), [coverage summary](swift-summary.json)
and [build identity](build-identity.json) are retained. The first capture began
66.993 ms after input and contains both old and incoming glyphs. These observations
do not by themselves identify whether the product or correlation oracle caused
the failure. The complete original artifact also remains at
`/private/tmp/mokusei-pr225-final-41422140080-evidence`.

The same assertion earlier reported `+23` in a [local run](../main-9a849-local/README.md)
and `0` in the ordinary Swift suite of [PR #220 run 41413041330](../pr220-41413041330/README.md).
Those older failures did not retain their actual frames, so they are not
classified as harmless by the later evidence.

Only this direction case and its private fixture were removed; no test was
converted to a skip. The retained cell/projection cases still check intermediate
versus settled frames, stable digit widths, snapshot changes, interruption and
convergence. The Git flip still requires its foreground window, three distinct
frames, fixed geometry and audited marker. **Direct automated coverage that
incoming digits enter from above is lost**; none of the remaining assertions
should be described as a replacement for it. `native/rolling-numbers` still
runs all three remaining cases, and the final PR still requires the real hosted
`Complete coverage` gate.

The affected Swift test targets [built](local-build.log) successfully after
the removal. A first local replay attempt failed to acquire a graphical lock
held by another task and exited before compilation or test execution. Its
[report](local-lock-report.json) and [log](local-lock.log) are preserved; it is
not a failed or passing execution of the three remaining cases.

The [current Swift test inventory](local-inventory.log) contains exactly the
two retained `RollingNumberCellTests` methods and the Git flip method; the
removed method is absent rather than skipped. Discovery is not test execution.
