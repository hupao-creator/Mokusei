# Latest main CI baseline

[Main push run 41411550809](https://github.com/hupao-creator/Mokusei/actions/runs/41411550809)
succeeded on attempt 1 at `9a849d0a9ab80d5ba4f07d32267dbb63b832521a`. The
[build manifest](build-manifest.json) identifies this revision and the [native
report](native-report.json) lists all native checks as passed. Full downloaded
evidence remains at `/private/tmp/mokusei-ci-main-9a849-success-evidence`.

Elapsed trigger to final job completion was 1,957 seconds (32m37s); first job
creation delay 0 seconds; summed observed runner execution 2,535 seconds. The
native job queued 3 seconds and executed 1,931 seconds (32m11s), including
272 seconds in its build step and 1,579 seconds in verification-command steps.
The latter include staging and compilation, not just test execution. Raw job and
step data and timing classifications are [retained](raw.json) with the
[profile](summary.md).

The runner image was `20261026.0455.2`. Swift restored an approximately 414 MiB
archive, 434,519,119 bytes, from key suffix `native-3f402648494aa401ee9101631a899b28933110fe`;
see the [native job log (gzip)](native.log.gz). Cache keys, runner image, source tree,
event and test/CI differences must be checked when comparing a later PR run.
One observation on an independent runner cannot establish causation or a speedup.
