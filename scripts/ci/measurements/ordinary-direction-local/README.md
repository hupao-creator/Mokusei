# Focused local SwiftPM direction capture

At integration commit `6199e05`, after a successful current test-target
build, the original direction test ran once through SwiftPM's `--skip-build`
`--no-parallel` path with a positive filter. It exited 0 in 9.81 seconds; the
Swift Testing test itself passed in 1.054 seconds. The [command receipt](report.json),
[full log](swift-test.log) and [source hashes](source-sha256.json) are retained.
The separate zero-test XCTest listing is not counted as a passing test.

The 2x [during](during.png) and [settled](settled.png) frames and
[row/timing/input receipt](measurements.json) record `bestShift = -28`, with
the first capture starting 68.848 ms after input. The ordinary host reported
`applicationRunningAtInput = false`, `applicationActiveAtInput = false`,
`windowKeyAtInput = false`, `windowOcclusionVisibleAtInput = false`, and
`reduceMotionAtInput = false`. A visible window still supplied the bitmap.
This one observation demonstrates that absence of a foreground AppKit app
alone does not make this direction assertion fail. It cannot explain an
earlier failure whose actual frame, timing and input state were not saved.

The test held the same native graphical-session lock used by the replay
launcher. A separate `ThreadPanelDemo` was backgrounded and left untouched;
therefore the machine was not otherwise an exclusive graphical session. This
is a focused local diagnostic, not the complete ordinary suite or hosted CI.
