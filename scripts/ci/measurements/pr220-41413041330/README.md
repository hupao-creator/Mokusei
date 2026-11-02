# Related full-CI failure on main `9a849d0`

[PR #220 run 41413041330](https://github.com/hupao-creator/Mokusei/actions/runs/41413041330)
failed on attempt 1. Its PR head was `fcc6c0f`; the actual built synthetic
revision recorded in its Swift receipt was `a4f5f1ed73ac7d0b8d4d4e273be87e6a931d691a`.
The native job queued 14 seconds and executed 1,970 seconds; the run took
2,012 seconds to the final `Complete coverage` failure.

The complete ordinary Swift test command exited 1. Its original
`RollingNumberCellTests.incomingDigitsMoveDownFromAbove()` assertion observed
`bestShift = 0` where `< 0` is required. The ordinary step ran 699 seconds and
the test reported 1.017 seconds. This revision did not save that test's actual
bitmaps, sampling times or foreground state, so its cause cannot be inferred
from the outcome. The [Swift log (gzip)](swift.log.gz) and
[audit summary](swift-summary.json) are retained.

The later original native `rolling-numbers` owner exited 1 in 30.957 seconds
because the Git flip's `foreground` prerequisite was false at input. All three
other rolling methods passed there, including direction. Its
[initial](git-initial.png), [during](git-during.png) and [settled](git-settled.png)
images differ; the [receipt](git-measurements.json) records the later app as
active, key and visible, but the individual conditions at input were not
recorded. They do not classify that failure. The [rolling log](rolling-numbers.log),
[native report](native-report.json), [job metadata](jobs.json) and
[full job log (gzip)](native.log.gz) are retained. Full downloaded artifacts
remain at `/private/tmp/mokusei-ci-pr220-41413041330-evidence`.

The foreground launcher change addresses a different execution path from the
ordinary Swift test. The new source retains direction bitmaps and timing in
both paths; neither a prior pass nor the later native result explains the
ordinary failure.
