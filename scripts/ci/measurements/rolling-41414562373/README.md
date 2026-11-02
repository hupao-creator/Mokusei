# Hosted rolling owner diagnostic with LaunchServices

[Run 41414562373](https://github.com/hupao-creator/Mokusei/actions/runs/41414562373)
completed successfully on attempt 1 at diagnostic-only commit `19ced22`. One
macOS runner queued for 3 seconds, executed for 409 seconds, and finished 414
seconds after the dispatch. The unchanged `rolling-numbers` owner passed all
four selected methods in 56.371 seconds. Its [report](report.json), [test log](rolling-numbers.log),
[full job log (gzip)](job.log.gz), [run](run.json) and [jobs](jobs.json) are retained.

With the replay requested through LaunchServices, the Git flip test recorded
application active, key window and visible occlusion state **at input**; all
three original frames differ. Its [input-time receipt](git-measurements.json),
[initial](git-initial.png), [during](git-during.png) and [settled](git-settled.png)
frames are retained. The during capture began 94.369 ms after input.

The direction method passed at 1x with `bestShift = -19`; the first capture
began 69.256 ms after input. Its unchanged assertion and 65/330 ms sleeps were
retained, as were the [during](direction-during.png), [settled](direction-settled.png)
bitmaps and [row/timing receipt](direction-measurements.json).

This is one diagnostic result on a different hosted runner and commit, not a
retry proving why [run 41413193436](../rolling-41413193436/README.md) failed its
foreground prerequisite; its individual components at input were not recorded.
Nor does a 1x pass explain the earlier local 2x `bestShift = +23` failure, whose
actual bitmaps were not captured. The workflow is dispatch-only, has no
`Complete coverage` gate, and is not part of the integration branch.
