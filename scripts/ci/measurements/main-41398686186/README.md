# Latest main diagnostic at `fe4af9a` (2026-11-02)

[Run 41398686186](https://github.com/hupao-creator/Mokusei/actions/runs/41398686186),
attempt 1, failed `Complete coverage`. Its macOS job waited 3 seconds and ran
1623 seconds; the entire run took 1646 seconds from trigger through its last
job, with 2221 seconds of runner execution across newly run jobs. These are
failure diagnostics, not a successful performance baseline.

The ordinary Swift suite and the other native replays completed, but
`native/tag-glass-captures` exited 1 after 84.370 seconds. Its title cancellation
case failed to observe a qualifying current WindowServer frame during incoming.
The last analyzed live samples around the interval had 6,359 and 89,223 ink
against a 141,325 reference (4.50% and 63.13%); both were under 50 ms old but
outside the unchanged 10–60% band. The original assertion failed; these data
do not determine whether the product's intermediate rendering was correct.
The saved [native report](native-report.json), [replay log](tag-glass-captures.log)
and representative [early](incoming-61.png) and [later](incoming-65.png)
frames retain the failure. The complete original artifact is preserved at
`/private/tmp/mokusei-ci-main-41398686186-evidence` and in the run's
`macos-native-evidence-attempt-1` artifact.

The job used `macos-26-arm64` image `20261026.0455.2` and restored the Swift
cache ending `native-d3430ad` (425,496,777 bytes). The full run and job metadata
are in [run.json](run.json). Its source predates any later main update and cannot
certify a PR merge tree. No rerun was requested for this failure.
