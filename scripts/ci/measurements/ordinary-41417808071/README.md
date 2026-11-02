# Ordinary and native direction diagnostic on one runner

[Run 41417808071](https://github.com/hupao-creator/Mokusei/actions/runs/41417808071)
succeeded on attempt 1 at diagnostic-only commit `a5b6e48`. Its single
macOS job queued 2 seconds and executed 1,190 seconds; trigger to completion
was 1,194 seconds. It built once and ran the original ordinary Swift command,
then the native rolling owner serially. The relevant production rolling-number
file was identical on old main `9a849d0` and new main `845c5b5`; the instrumented
direction test source matches the integration branch. The workflow itself is
not part of the PR.

The ordinary Swift process exited 0; Swift Testing reported 502 tests with 24
existing framework skips, and XCTest reported 17 tests with 8 existing fixture
skips. The original command also excludes separately owned native methods.
This diagnostic ran only the rolling native owner, not the other owners or the
full aggregate, so neither the suite summary nor the dispatch is complete CI.
The original direction assertion passed with `bestShift = -9`. Its
[bits](ordinary-during.png), [settled image](ordinary-settled.png) and
[receipt](ordinary-measurements.json) record a 92.395 ms input-to-capture delay,
`applicationRunningAtInput = false`, `applicationActiveAtInput = false`,
and a window reported visible but not key or unoccluded. Motion reduction was
off. The [Swift receipt](swift.json) and [full log (gzip)](swift.log.gz) remain
available for the unabridged outcomes.

The subsequent original native owner exited 0 in 38.213 seconds and passed all
four selected methods. Its direction result was `bestShift = -19`, sampled
69.359 ms after input. Its [during](native-during.png), [settled](native-settled.png)
and [receipt](native-measurements.json) show an active, running app and a
visible, unoccluded window, which was not key during this direction method. The
separate Git flip did have all three foreground components true at input and
its three original frames differed; its [receipt](git-measurements.json),
[initial](git-initial.png), [during](git-during.png) and [settled](git-settled.png)
images are retained. See also the [native report](native-report.json) and
[log](rolling-numbers.log).

These actual samples show the ordinary host can pass while inactive and its
65 ms sleep was observed at 92.395 ms in this run. They do not establish why
[the earlier hosted ordinary failure](../pr220-41413041330/README.md) returned
0 or the earlier local failure returned +23: neither saved its own bitmaps and
input timing. No later pass alone classifies those failures as harmless. The
[build manifest](build-manifest.json), [run](run.json), [jobs](jobs.json),
[full job log (gzip)](job.log.gz), and complete original artifact at
`/private/tmp/mokusei-ci-ordinary-41417808071-evidence` are retained.
