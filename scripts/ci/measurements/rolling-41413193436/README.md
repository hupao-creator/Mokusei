# Hosted rolling-direction diagnostic

[Run 41413193436](https://github.com/hupao-creator/Mokusei/actions/runs/41413193436)
failed on attempt 1 at diagnostic-only commit `fdd079f`. Its single macOS job
queued 4 seconds and ran 441 seconds. The original `rolling-numbers` owner
exited 1 after 59.451 seconds; the whole run took about 7 minutes 26 seconds.
This dispatch-only workflow has no `Complete coverage` check and is not part
of the integration branch.

The originally failing `incomingDigitsMoveDownFromAbove()` passed on this 1x
runner with `bestShift = -19`. Its actual [during](direction-during.png) and
[settled](direction-settled.png) bitmaps and [row/timing receipt](direction-measurements.json)
are retained. The first capture began 74.82 ms after input; the original
65 ms sleep, 330 ms sleep and negative-shift assertion were unchanged. This
separate observation does not explain the earlier local 2x `+23` failure.

The owner nevertheless failed because
`sharedTokenFlipAnimationWorksAtSummaryAndOriginalSizes()` did not meet its
foreground prerequisite at input. Its [initial](initial.png), [during](during.png)
and [settled](settled.png) images differ, and its [receipt](git-flip-measurements.json)
records `foregroundAtInput = false`; by the later receipt the application was
active and the window was key and visible. The individual foreground components
at input were not retained, so the reason remains unclassified. The assertion
and required marker were not bypassed, and the owner did not pass.

The [process report](report.json), [raw log](rolling-numbers.log),
[run/job metadata](run.json) and original screenshots are retained here. The
complete artifact remains in the run and at
`/private/tmp/mokusei-ci-rolling-41413193436`. No automatic retry was requested.
