# Related hosted midpoint failure (2026-11-02)

[PR #220 run 41404231833](https://github.com/hupao-creator/Mokusei/actions/runs/41404231833)
failed on attempt 1, head `ff5441c`, actual synthetic merge `3c30dcd`. The
`native/tag-glass-captures` process exited 1 after 83.560 seconds because
`retainedOverviewReturnsWithLatestContent` did not observe its original
40–60% opening midpoint. The job waited 4 seconds for a runner and executed
1812 seconds; the run took 1849 seconds from trigger to its last job, with
2420 seconds of newly executed runner work. This failed run is not a successful
performance sample.

The retained diagnostics contain 56 opening checks. Two adjacent native-view
samples crossed from x=752 to x=464 in 17.59 ms, skipping the unchanged
472–708 band. The largest gap across all opening checks was 99.934 ms. The
samples alone cannot tell whether the view committed a qualifying midpoint
between those checks or jumped across it; a later successful run cannot
classify this failure as harmless. The new geometry callback candidate must
still demonstrate a current native midpoint and pass the final hosted gate.

The [raw replay log](tag-glass-captures.log), [native report](native-report.json)
and [run/job data](run.json) are retained here. The complete original native
artifact remains at `/private/tmp/mokusei-ci-pr220-41404231833-evidence` and in
the run's `macos-native-evidence-attempt-1` artifact. No run or PR was modified.
