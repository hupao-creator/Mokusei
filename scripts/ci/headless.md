# Windowless developer feedback

Run from the repository root with the macOS 26/Xcode/Metal toolchain:

```sh
xcrun swift build --package-path app/macos --build-tests --force-resolved-versions --disable-index-store -j 2
python3 scripts/ci/swift-native.py prepare
python3 scripts/ci/swift-native.py headless --evidence /tmp/new-windowless-evidence
```

Use a fresh evidence directory. The reviewed selection covers protocol and
cancellation boundaries, pure camera/packing/directory models, card composition
and production offscreen Metal rendering. It currently contains 37 methods.
Every selected method must pass exactly once; absent suites, missing/duplicate
outcomes, any skip, incomplete summaries and nonzero process status fail.
The receipt records source revision, dirty state, requested methods, actual
outcomes and process exit. This command does not publish remote statuses or
require credentials/extensions.

It creates no test window or activation request and runs with
`MOKUSEI_TEST_HEADLESS=1`. AppKit, macOS and a Metal device remain dependencies;
a capability override does not establish physical absence of WindowServer.
The full hosted native run still covers all current methods plus the real
input/focus/WebKit/window/pixel owners and performs exactly-once coverage audit.
The standalone windowless result never replaces Complete coverage.

Independent Go fixture producers also retain two bounded workers and per-command
evidence; use `replays.py fixtures --jobs 1` for the serial diagnostic control.
The retired direct embedded-selector suites are not carried forward as headless
coverage. Current Settings and Harness-form paths remain covered separately.
