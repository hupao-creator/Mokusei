# Local checks after main `845c5b5`

The current Swift test targets [built](build.log) in 78.03 seconds after main
`845c5b5` was integrated. After the later Tag event instrumentation built,
`MOKUSEI_TEST_HEADLESS=1 xcrun swift test --skip-build --no-parallel
--package-path app/macos --filter NativeMokuExecutionLinkRoutingTests`
exited 0. The [Swift Testing log](routing-headless.log) records two passed
tests: 12 route parameter cases and three resource-scope cases. The separate
zero-test XCTest listing does not count as a pass.

These window-free checks do not certify the mounted native Back/Escape replay
or the seven capture cases. Those require the graphical owner and the final
revision's hosted `Complete coverage`.
