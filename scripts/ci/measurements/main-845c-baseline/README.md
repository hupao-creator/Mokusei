# Latest main same-tree baseline

[PR #236 run 41413504727](https://github.com/hupao-creator/Mokusei/actions/runs/41413504727)
passed the complete CI on attempt 1. Its [build manifest](build-manifest.json)
identifies synthetic commit `a8eabe7a8b67202c7746e8fc17354072f10ab39c`, whose
Git tree `cacf9ac54ac984e2a5627d9d8660f89c86a5b105` exactly equals the tree
of the merged main commit `845c5b5df977591a4f0bb43d82fdba1969d4a2c1`. The
[native report](native-report.json) records all native owners passing. The full
artifact remains at `/private/tmp/mokusei-ci-pr236-41413504727-evidence`.

From trigger to final job completion: 2,066 seconds (34m26s). First job
creation delay: 0 seconds. Summed runner execution: 2,601 seconds. The native
job queued 4 seconds and ran 2,031 seconds (33m51s), including 281 seconds
in its build step and 1,670 seconds in verification-command steps. Those
steps include staging and compilation, not just test execution. See the
[raw jobs](raw.json) and [profile](summary.md).

The runner used image `20261026.0455.2` and restored a Swift archive of
435,729,411 bytes from a key ending in `native-5fee69554247f1a43634924de50cecbd498643c1`;
see the [native log (gzip)](native.log.gz). This is a PR-event run on an
independent runner, not a same-machine A/B or proof of a speedup. The direct
main push run `41417892642` was still in progress when this baseline was
recorded; neither it nor this prior PR run can certify #225's final commit.
