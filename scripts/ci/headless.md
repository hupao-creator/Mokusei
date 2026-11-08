# Windowless Swift execution

The ordinary CI and `make check-swift` launchers run reviewed windowless suites
first with `MOKUSEI_TEST_HEADLESS=1`, then the remaining suites in the graphical
process. Both commands use the same current build, stay serial and exclude the
unchanged mandatory native owners. Their disjoint method lists must cover the
complete ordinary inventory exactly once. Every headless method must pass;
display skips cannot substitute for native execution.
The graphical process explicitly sets `MOKUSEI_TEST_HEADLESS=0`, so an inherited
windowless override cannot suppress its display admission. It still needs the
real graphical session; this setting does not manufacture display capability.

The registry in [swift_execution.py](swift_execution.py) contains 36 self-contained
suites, including the offline reading cache's isolated scope/reopen case, and four
fixture-backed suites. The latter move only when their existing Go producer's
environment is present: Moku dispatch/status, Timer, tag emoji and voice events.
Without those variables they retain their previous ordinary execution/deferral.
The [migration audit](../../tools/verification/swift-tests/headless-migration-20261104.md)
records the source evidence, retained graphical suites and validation limits.

Run from the repository root with the macOS 26/Xcode/Metal toolchain:

```sh
xcrun swift build --package-path app/macos --build-tests --force-resolved-versions --disable-index-store -j 2
python3 scripts/ci/swift-native.py prepare
python3 scripts/ci/swift-native.py headless --evidence /tmp/new-windowless-evidence
```

Use a fresh evidence directory. This independent command runs the same reviewed
selection without launching its graphical remainder. It includes the four
fixture-backed suites only when their producer variables are supplied. Counts
above describe suites, not parameterized cases or a completed run;
the actual current-build inventory remains authoritative.
Every selected method must pass exactly once; absent suites, missing/duplicate
outcomes, any skip, incomplete summaries and nonzero process status fail.
The receipt records source revision, dirty state, requested methods, actual
outcomes and process exit. This command does not publish remote statuses or
require credentials/extensions.

It creates no test window or activation request and runs with
`MOKUSEI_TEST_HEADLESS=1`. AppKit, macOS and a Metal device remain dependencies;
a capability override does not establish physical absence of WindowServer.
The full hosted native run still covers all current methods plus the real
input/focus/WebKit/window/pixel owners and audits both ordinary execution modes.
The standalone windowless result never replaces Complete coverage.

Independent Go fixture producers also retain two bounded workers and per-command
evidence; use `replays.py fixtures --jobs 1` for the serial diagnostic control.
The retired direct embedded-selector suites are not carried forward as headless
coverage. Current Settings and Harness-form paths remain covered separately.
