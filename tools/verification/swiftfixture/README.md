# Swift fixture commands

Go integration replays use this helper only to construct `xcrun swift test`.
Each caller still owns its real fixture, environment, output and execution oracle.
Local calls build by default. `MOKUSEI_SWIFT_SKIP_BUILD=1` is for CI consumers
after the shared build manifest has verified the current run, commit, checkout
path, architecture and toolchain. It never permits cached test results.
