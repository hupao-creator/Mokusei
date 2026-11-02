# Local integrated replay at `60cdf95`

The current Swift test targets built successfully after main `9a849d0` was
integrated. Four affected native checks then ran serially with one fresh shared
compiler module cache. The [process report](report.json) records:

| Check | Result | Seconds |
| --- | --- | ---: |
| `moku-execution-links` | pass | 60.376 |
| `rolling-numbers` | fail, exit 1 | 15.884 |
| `tag-glass-captures` | pass, all seven methods | 84.970 |
| `isolated-input` | pass | 42.228 |

`RollingNumberCellTests.incomingDigitsMoveDownFromAbove()` reported
`bestShift = 23` while the unchanged assertion requires a negative shift.
The other three methods in that owner passed. The failing method did not save
its own during/settled bitmaps, so the available screenshots from the separate
Git token flip case cannot explain this failure. Its cause remains unclassified;
a prior hosted pass or a later pass alone cannot make it harmless. The raw
logs are retained here and complete local captures remain under
`/private/tmp/mokusei-ci-geometry-local/main-9a849-scratch`.

A separate `ThreadPanelDemo` process was already running from 16:14:43 local
time and overlapped the rolling-number replay at 16:19:38–16:19:53. The initial
process check searched only the standard reading launcher and missed that demo.
Its foreground state and any effect on the failure are unknown; this local
round cannot establish an otherwise exclusive graphical session.

A first attempt to collect the direction method's frames with added diagnostics
exited before compilation because another replay held the graphical-session lock.
Its [report](instrumented-lock-report.json) and [log](instrumented-lock.log)
are retained. No native test ran in that attempt and it is not a passing retry.


After the earlier foreground failure in hosted run 41413193436, the replay was
changed to request LaunchServices and the two original tests were instrumented
to retain their inputs/observations without weakening their assertions. The
current local Swift test targets built in 17.69 seconds. A single diagnostic
run of all four `rolling-numbers` methods then passed in 28.301 seconds on the
2x local display. Its [report](instrumented-report.json),
[log](instrumented-rolling-numbers.log) and
[input hashes](instrumented-input-sha256.json) identify the uncommitted test
source that ran at `60cdf95`; the same test/launcher sources were exercised by
[hosted run 41414562373](../rolling-41414562373/README.md).

The retained 2x [during](instrumented-direction-during.png) and
[settled](instrumented-direction-settled.png) bitmaps show the incoming glyphs
above the final baseline; [row/timing evidence](instrumented-direction-measurements.json)
records bestShift -28 and the capture starting 65.870 ms after input. The Git
flip was active, key and visible at its input and all three frames differed;
its [receipt](instrumented-git-measurements.json),
[initial](instrumented-git-initial.png), [during](instrumented-git-during.png)
and [settled](instrumented-git-settled.png) images are retained.

The graphical lock was free, and the separate `ThreadPanelDemo` process was
reparented to launchd and not frontmost before the replay. It was neither
closed nor stopped. It remained present, so the run was not an otherwise
exclusive graphical session. This new-source pass does not classify or erase
the earlier 2x +23 failure, which did not retain its actual frames.
