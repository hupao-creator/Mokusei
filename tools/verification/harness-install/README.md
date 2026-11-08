# Harness installation lifecycle replay

Run from the repository root:

```sh
./scripts/go.sh run -race ./tools/verification/harness-install
```

The replay calls the real Claude, Codex and OpenCode `Install` implementations
with a private environment and local `curl`/`npm` executables. No download,
package installation, native CLI, account or model service is used. Pi has no
`plugin.Installer` implementation; its native client opens an installation guide.

Each adapter must retain successful and nonzero-exit outcomes, preserve
`context.Canceled`, reject a pre-cancelled launch and enforce the 8 MiB combined
output limit. The process fixtures create a real descendant that inherits stdout
and stderr and ignores SIGTERM. Both owner cancellation and successful leader
exit must join within eight seconds, leave no executing group member, and restore
the process's open-file-descriptor count. A zombie waiting for its OS reaper is
not executing and cannot retain pipe writers. This checks actual subprocess and
pipe cleanup rather than a mocked cancellation callback.

The fixtures publish their PID/group readiness before cancellation; fixed sleeps
do not decide when the owner is cancelled. A warm success initializes the Go
poller before descriptor comparisons. Failure cleanup kills only fixture-recorded
processes/groups and joins the outstanding installation, independently of the
production path, before removing its temporary directory.

Use `-harness claude|codex|opencode` and
`-case cancelled|leader-exit|failure|overflow|precancelled` for a focused replay.
The ordinary CI `adapters` group owns this check. It validates lifecycle behavior,
not compatibility with a remote installer or a future upstream package release.
