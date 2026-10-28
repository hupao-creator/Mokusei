# macOS Swift test failure audit

Baseline: `a42e44c9943260e36ab4876f3619a43e5f20ec9b`. All commands ran in the
assigned detached worktree. No product source or behavioral assertion threshold
was changed.

## Reproduction environment and controls

- Apple Silicon macOS 26.5.1, build 25F80 (Darwin 25.5.0; SDK 26.5), Xcode-selected Apple Swift 6.3.2;
  Swift Testing library 1902. This machine has a graphical session.
- Baseline: `swift test --package-path app/macos` (unfiltered, default scheduling).
- Scheduling control: `swift test --package-path app/macos --skip-build --no-parallel`.
  The **same binary and assertions** passed every one of the 23 baseline-failing
  methods. One additional gesture sampling race appeared; see below.
- Host control: `python3 tools/verification/reading-presentation/run.py --settings-transition`.
  The unchanged three Settings tests passed in `NSApplication.run()` as well.
- The first sandboxed attempt stopped at manifest compilation with
  `sandbox-exec: sandbox_apply: Operation not permitted`; it ran zero tests.
  All recorded test results use approved execution outside that sandbox.
- The inherited launcher environment contained `ARGS=--fresh` and
  `MAKEFLAGS=ARGS=--fresh`. An initial `make check` stopped at Go's unknown `-fresh`
  flag. Clearing those launcher variables produced the baseline's green check:
  `env -u MAKEFLAGS -u MAKEOVERRIDES -u MAKELEVEL -u ARGS make check`.
  That check ran only 13 Swift DirectoryTag tests, despite the full suite failing.

## Baseline failure inventory

23 distinct test methods, **24 failing test-case instances**, 15 failed suites,
**56 issues**. Moku paste failed for `(png, control: false)`; sidecard paste
failed for both `files` and `mixed`. Repeated assertions within one instance
contribute more than one issue. Swift Testing reported 378 tests in 71 suites, including 22 skipped
methods. XCTest separately reported 17 tests, 8 skips, 0 failures.

A = confirmed product regression; B = test environment/scheduling; C = explicit
fixture/capability gate. All 23 baseline failures are B: every original assertion
passed with the unchanged binary under serial scheduling, then with the shared
native test gate under the default runner. No A has been established.

The location below is the **baseline's first recorded difference**, not the new
line number after adding test traits. `Issue recorded` is followed by its original
message where present. This is the complete first-failure list, not an audit-summary
extrapolation.

| Failed suite | Failed method | First difference in the baseline log | Class |
| --- | --- | --- | --- |
| `NativeSettingsDiscoveryTests` | `independentInstallationRepliesAndRetirement()` | `NativeSettingsLoadingReplay.swift:28:38` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `SwiftUIOverviewInteractionTests` | `searchEditsChineseAndRepeatedFocusSelectsCurrentText()` | `SwiftUIOverviewInteractionTests.swift:34:38` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `NativeOverviewCenteringTests` | `screenshotMixedFootprintsBalanceBothControlsAndRestoreAfterExtensionChanges()` | `NativeOverviewCenteringTests.swift:201:38` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `NativeSettingsTransitionTests` | `anchoredRevealUsesACircleWithoutScalingThePage()` | `NativeSettingsTransitionTests.swift:84:13` — `Expectation failed: sawReveal` | B |
| `NativeOverviewTransitionTests` | `recoveryDuringEntryFinishesEveryMountedCard()` | `NativeOverviewTransitionTests.swift:61:38` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `NativeVoiceOwnershipTests` | `enteringThreadDoesNotInterruptMokuAndThreadExclusivelyOwnsAudioUntilClosed()` | `NativeVoiceOwnershipTests.swift:72:6` — `Caught error: NativeVoiceError(message: "Replay timed out")` | B |
| `NativeComposerPasteTests` | `shortcutPastesIntoMoku(content:control:)` — `png, false` | `NativeComposerPasteTests.swift:105:42` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `RollingNumberCellTests` | `threadCardUsageRollsInsideStableCells()` | `RollingNumberCellTests.swift:60:9` — `Expectation failed: (initial != during && during != settled → false) && (initial != settled → <not evaluated>)` | B |
| `NativeOverviewAutoReturnTests` | `explicitReturnFitsBeforeResumingAttentionEvenWhenTargetIsVisible()` | `NativeOverviewAutoReturnTests.swift:24:24` — `Issue recorded; Camera did not reach the expected framing` | B |
| `NativeReadingPagePresentationTests` | `ordinaryDetailSlidesOpaqueOverTheVisibleOverview()` | `NativeReadingPagePresentationTests.swift:94:9` — `Expectation failed: (right.blueComponent > 0.9 → false) && (right.redComponent < 0.1 → <not evaluated>)` | B |
| `RollingNumberCellTests` | `projectedUsageUpdatesKeepTheirAnimation()` | `RollingNumberCellTests.swift:155:13` — `Expectation failed: (before != during && during != settled → false) && (before != settled → <not evaluated>)` | B |
| `NativeOverviewTagGlassTests` | `closedChildSelectionUpdatesDirectoryLabelAndClears()` | `NativeOverviewTagGlassTests.swift:420:38` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `NativeOverviewTransitionTests` | `ordinaryExitFinishesBeforeReflowAndEntryRisesWithoutScaling()` | `NativeOverviewTransitionTests.swift:149:9` — `Expectation failed: try redness(window, at: exiting) < originalRedness * 0.8` | B |
| `NativeOverviewCenteringTests` | `dockReservationRePacksThePreviousFiveCardCaseWithoutFalseCarousel()` | `NativeOverviewCenteringTests.swift:201:38` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `GitThreadExtensionTests` | `sharedTokenFlipAnimationWorksAtSummaryAndOriginalSizes()` | `GitThreadExtensionTests.swift:217:9` — `Expectation failed: (initial != during && during != settled → false) && (initial != settled → <not evaluated>)` | B |
| `NativeReadingPagePresentationTests` | `closeRetainsDestinationUntilReturnFinishesAndCanBeCancelled()` | `NativeReadingPagePresentationTests.swift:105:38` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `NativeReportNavigationTests` | `reportNavigationMovesWithPageSurvivesReplacementSuppressionAndZoomAndClicksBack()` | `NativeReportNavigationTests.swift:147:9` — `Expectation failed: (intermediateSamples → 0) > 0` | B |
| `NativeReadingPagePresentationTests` | `interruptedNavigationKeepsCloseActionAvailable()` | `NativeReadingPagePresentationTests.swift:131:42` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `NativeSettingsTransitionTests` | `reverseResizeAndInactiveSceneRetireObsoleteCompletions()` | `NativeSettingsTransitionTests.swift:116:38` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `NativeSidecardAttachmentPasteTests` | `shortcutDisplaysRemovesAndSendsAttachments(content:)` — `files` | `NativeSidecardAttachmentPasteTests.swift:145:42` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `NativeSidecardAttachmentPasteTests` | `shortcutDisplaysRemovesAndSendsAttachments(content:)` — `mixed` | `NativeSidecardAttachmentPasteTests.swift:145:42` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `RollingNumberCellTests` | `incomingDigitsMoveDownFromAbove()` | `RollingNumberCellTests.swift:219:9` — `Expectation failed: (bestShift → 0) < 0` | B |
| `NativeSettingsTransitionTests` | `unanchoredRouteAndExplicitSettleStillClose()` | `NativeSettingsTransitionTests.swift:138:38` — `Issue recorded; SwiftUI presentation did not settle` | B |
| `NativeWindowNavigationTransitionTests` | `expandsAndClosesThroughIntermediateWidthsAndCanReverse()` | `NativeWindowNavigationTransitionTests.swift:57:9` — `Expectation failed: closing.contains { $0 > closed + 1 && $0 < open - 1 }` | B |

The original summary, verbatim:

```text
Test Suite 'MokuseiNativePackageTests.xctest' passed at 2026-10-27 18:26:34.121.
	 Executed 17 tests, with 8 tests skipped and 0 failures (0 unexpected) in 0.042 (0.045) seconds
Test Suite 'All tests' passed at 2026-10-27 18:26:34.121.
	 Executed 17 tests, with 8 tests skipped and 0 failures (0 unexpected) in 0.042 (0.048) seconds
✘ Test run with 378 tests in 71 suites failed after 61.499 seconds with 56 issues.
```

## Diagnosis and repairs

1. **Cross-suite resource ownership.** `@MainActor` allows another test to run
   while a test awaits; `.serialized` only serializes inside its own suite.
   Host and Threads suites were simultaneously creating/ordering windows at the
   same origin, changing focus, replacing `NSApp.mainMenu`, reading/writing
   `NSPasteboard.general` and rendering every `NSApp.windows` entry from their wait
   loops. The serial control removed all 23 original failures without changing a
   product, an assertion or a timeout. The shared `MokuseiTestSupport` module now
   supplies `.serializedNative`: an asynchronous, process-wide gate held through
   each case's cleanup, across **both** integration targets. Main-actor model
   tests participate too, so rendering cannot consume their bounded polling time.
   The pure concurrent Core/protocol/geometry suites retain their scheduling.
2. **Reveal and cancellation.** The first reveal failure was `sawReveal`; the
   baseline also saw `settingsTransitioning == true` and a far pixel blue channel
   of `0.16159594058990479` instead of `> 0.9`. A later lifecycle wait timed out.
   `SwiftUIReplay.wait` itself recorded an issue and then threw `CancellationError`:
   that cancellation was a timeout artifact, not evidence that the product's
   animation task was cancelled. The helper now reports one located expectation
   failure with host/window diagnostics; actual cancellation from `Task.sleep`
   still propagates. It no longer initializes AppKit for model-only waits.
   Both plain serial SwiftPM and the existing AppKit host passed all three
   Settings cases, so **missing `NSApplication.run()` alone is not this failure's
   demonstrated cause**. Occlusion, focus and overloaded main-actor observation
   are shared-host mechanisms; the experiment establishes contention without
   pretending to isolate each mechanism individually.
3. **The additional serial-only gesture race.**
   `NativeOverviewGestureTests.panTakesOverTheVisibleAnimationRatherThanItsDestination`
   failed at baseline lines 60/61, with x/y discrepancies 6.170773145879025 and
   4.746748573753052 against the existing `< 2` limit. `liveTransform` and `pan`
   both sample `systemUptime`, but a Swift Testing `#expect` macro ran between them.
   The test now samples immediately around `pan` and checks the distance afterward.
   All distance assertions and the `< 2` limits are unchanged; no camera behavior
   or animation curve changed.
4. **Capability admission, not failure suppression.** `.requiresDisplay` checks
   `CGSessionCopyCurrentDictionary()` and `NSScreen.screens` before native tests
   enter their fixture. Apple SDK `CGSession.h` documents a nil dictionary when
   outside a Quartz GUI session or when WindowServer is disabled. The explicit
   `MOKUSEI_TEST_HEADLESS=1` override exercises that same skip path. Mixed suites
   gate only their UI cases; pure state/draft checks remain enabled. The skips
   name the missing graphical environment. No failed assertion triggers a skip.
5. **Check coverage and external fixtures.** `make check-swift` now runs the full
   suite, and `make check` includes it. The old DirectoryTag-only Swift invocation
   was removed from `check-directorytag`; its 13 tests run in the full suite.
   Existing environment gates now print their fixture/launcher requirements.
   The standalone native launcher compiles the same support source and rejects
   skipped tests rather than interpreting an incomplete green summary as coverage.

## Native mouse tracking capability (C)

The current Moku composer mouse/NFD case has an additional explicit AppKit-loop
gate. A plain graphical SwiftPM run was observed to exit with status zero while
inside native NSTextView mouse tracking, with no Swift Testing completion
summary. `reading-presentation/run.py --moku-composer` exercises the real click
and exact Unicode persistence in a running application; its seven-test replay
must not skip. The local shared Swift reporter now rejects incomplete captures.

## The eight XCTest skips (C)

These are explicit missing Go-fixture gates, not failed or disabled Swift assertions.
They do not require GUI. A plain `swift test` does not create their external Go
processes, manifests or authenticated profiles. Each guard checks the listed
variables before its first boundary operation; invalid supplied inputs still fail.

| XCTest method | Missing prerequisite / reason | Reproduction after `./scripts/go.sh run -race` |
| --- | --- | --- |
| `GoDeltaInteropTests.testGoGeneratedDeltasReconstructNativeContent` | `MOKUSEI_GO_DELTA_FIXTURES`: Go-generated before/patch/after corpus | `./tools/verification/transport -swift-deltas` |
| `IntegerWireTests.testExportActualSwiftRequestsToGo` | `MOKUSEI_SWIFT_INTEGER_REQUESTS` and `MOKUSEI_SWIFT_VOICE_THREAD`: output path and thread for the Go consumer | `./tools/verification/runtime -swift-voice` |
| `PiTokenUsageTests.testGoUsageProjectionsReachNativeCardAndExecutionUsage` | `MOKUSEI_PI_USAGE_FIXTURES`: 60 Go usage projections | `./tools/verification/pi -swift-usage -timeout 10m` |
| `RuntimeHostFilesInteropTests.testNativeUploadsAndDownloadsCrossTheGoTransportBoundary` | `MOKUSEI_SWIFT_FILES_PROFILE`: authenticated live Go file host | `./tools/verification/transport -swift-files` |
| `RuntimeSettingsCapacityInteropTests.testColdSettingsBurstAndCancellation` | `MOKUSEI_SWIFT_SETTINGS_PROFILE`: Go HTTP admission/cancellation fixture | `./tools/verification/transport -swift-settings-capacity` |
| `RuntimeShutdownInteropTests.testCanonicalProfileIdentity` | `MOKUSEI_PROFILE_IDENTITY_MANIFEST`: canonical paths, aliases and owned live profile | `./tools/verification/runtime-helpers --swift-shutdown` |
| `RuntimeShutdownInteropTests.testStaleDiscoveryRecovery` | `MOKUSEI_STALE_DISCOVERY_CASES`: 10 dead/live/invalid discovery fixtures | `./tools/verification/runtime-helpers --swift-shutdown` |
| `RuntimeShutdownInteropTests.testReopenAfterFailedShutdown` | `MOKUSEI_SHUTDOWN_PROFILE`, `MOKUSEI_SHUTDOWN_RUNTIME`, `MOKUSEI_SHUTDOWN_GATE`: owned runtime plus a controlled shutdown/restart gate | `./tools/verification/runtime-helpers --swift-shutdown` |

## Existing Swift Testing gates (C)

The ordinary baseline skipped 22 methods across these groups. Their gates are
preserved, now with visible reasons.

| Group | Methods | Missing prerequisite |
| --- | ---: | --- |
| `ThreadCardInitialResponseTests` | 4 | `MOKUSEI_INITIAL_RESPONSE_FIXTURES`; `reading-presentation/run.py --initial-response` |
| `NativeBrowserDialogTests` | 4 | Isolated AppKit file-panel host; `reading-presentation/run.py --browser-dialogs` |
| `NativeOverviewTagGlassTests` | 5 | Isolated native glass/capture host; `reading-presentation/run.py --tag-glass` |
| `NativeApplicationNavigationTests` | 1 (2 parameter cases) | Isolated AppKit host; `reading-presentation/run.py --application-navigation` |
| `NativeOverviewSearchTests` | 3 | `MOKUSEI_OVERVIEW_SEARCH_NATIVE_REPLAY`; `reading-presentation/run.py --overview-search` |
| `NativeSettingsUserFlows.dailySettingsFlow` | 1 | `MOKUSEI_SETTINGS_TEST_PROFILE`; Go Settings launcher |
| `NativeMokuDispatchTests` | 1 | `MOKU_STATUS_NATIVE_FIXTURE`; Go dispatch snapshots |
| `NativeVoiceInputTranscriptTests` | 2 | `MOKUSEI_VOICE_EVENT_EXPORT`; Go Codex event exports |
| `NativeOverviewTagEmojiTests.applicationConversationProducerMatchesStrictDecoder` | 1 | `MOKUSEI_CONVERSATION_CONTRACT_EXPORT`; Go contract export |

## Report WebKit input capability (C)

The current `NativeReportNavigationTests` mounted-document case additionally
drives trusted AppKit mouse/key events through production WebKit: a real POST
form click, editable and closed-Shadow-DOM word movement, and HTML dialog Escape.
It requires `MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY=1`, supplied by
`python3 tools/verification/reading-presentation/run.py --report-navigation`.
The route-state case in the same suite remains enabled in plain SwiftPM.

A graphical session alone does not provide this event-loop capability. The plain
SwiftPM process reported `NSApp.isRunning == false` and did not deliver the native
mouse-down to the DOM; the isolated `NSApplication.run()` launcher passed both
Report cases with every business assertion enabled. Plain SwiftPM therefore
reports one additional explicit capability skip for this method. The historical
baseline counts below predate that expanded input coverage. A green `make check`
must be supplemented by the isolated Report replay, whose launcher rejects skips.
No input wait or assertion was relaxed to accommodate the plain host.

## Verification results

All counts below are Swift Testing's discovered method/suite counts; skipped
methods are included in that framework summary. XCTest is reported separately.

| Run | Exit | Tests / suites | Issues | Swift Testing skips |
| --- | ---: | ---: | ---: | ---: |
| Unchanged baseline, default scheduling | 1 | 378 / 71 | 56 | 22 |
| Unchanged baseline, `--no-parallel` control | 1 | 378 / 71 | 2 (only the additional gesture sampling race) | 22 |
| Fixed, default `swift test` | 0 | 378 / 71 | 0 | 22 |
| Fixed, `MOKUSEI_TEST_HEADLESS=1 swift test` | 0 | 378 / 71 | 0 | 146 |
| Fixed, complete `make check` | 0 | 378 / 71 | 0 | 22 |

The graphical run executes 356 methods with **no additional skips**. The headless
admission run executes 232 methods and skips 146: 138 carry the display reason
(including 14 already-gated native methods), and 8 carry external-fixture reasons.
Thus it adds 124 capability skips to the original 22; it does not silently return
from a test body. The eight XCTest skips stay unchanged in both environments.

Complete framework tail summaries from the unfiltered fixed run:

```text
Test Suite 'MokuseiNativePackageTests.xctest' passed at 2026-10-27 18:42:32.591.
	 Executed 17 tests, with 8 tests skipped and 0 failures (0 unexpected) in 0.041 (0.042) seconds
Test Suite 'All tests' passed at 2026-10-27 18:42:32.591.
	 Executed 17 tests, with 8 tests skipped and 0 failures (0 unexpected) in 0.041 (0.045) seconds
✔ Test run with 378 tests in 71 suites passed after 214.794 seconds.
```

Forced-headless admission:

```text
Test Suite 'MokuseiNativePackageTests.xctest' passed at 2026-10-27 18:47:31.097.
	 Executed 17 tests, with 8 tests skipped and 0 failures (0 unexpected) in 0.026 (0.028) seconds
Test Suite 'All tests' passed at 2026-10-27 18:47:31.097.
	 Executed 17 tests, with 8 tests skipped and 0 failures (0 unexpected) in 0.026 (0.030) seconds
✔ Test run with 378 tests in 71 suites passed after 24.978 seconds.
```

Final `make check` (Go architecture/format/vet/build, Swift build, race-enabled
properties and module checks, DirectoryTag Go checks, **full Swift tests**):

```text
Executed 17 tests, with 8 tests skipped and 0 failures (0 unexpected) in 0.030 (0.035) seconds
✔ Test run with 378 tests in 71 suites passed after 214.486 seconds.
```

The focused default-scheduling replay also passed 18 tests in 5 suites (Settings,
rolling numbers, Moku paste, sidecard paste, camera gestures). The full suite now
takes about 215 seconds here, versus the invalid concurrent baseline's 61 seconds;
that cost preserves native resource ownership rather than weakening assertions.

The affected isolated AppKit replays all passed with no skips:

| `reading-presentation/run.py` option | Result |
| --- | --- |
| `--settings-transition` | 3 tests / 1 suite, 0 issues, 4.791 s |
| default (reading presentation) | 5 tests / 1 suite, 0 issues, 5.989 s |
| `--rolling-numbers` | 3 tests / 1 suite, 0 issues, 5.898 s |
| `--report-navigation` | 2 tests / 1 suite, 0 issues, 3.210 s |

A negative control, `MOKUSEI_TEST_HEADLESS=1 python3
tools/verification/reading-presentation/run.py --settings-transition`, correctly
returned **1** after printing three skip reasons and
`FAIL: native replay skipped required cases; inspect the reported environment requirements`.
This checks that an explicitly requested native replay cannot silently pass on
Swift Testing's otherwise-green all-skipped summary.

The eight XCTest Go-fixture replay bodies and the other pre-existing externally
gated Swift Testing flows were **not run** in this task. Their guards, required
variables and driver commands were inspected individually; no interop pass is
claimed. The four affected native replays above ran against the current sources.

Full logs are retained in `.scratch/swift-tests/` in this worktree; this report
records the portable result and original failure list. Source review confirmed no production
source changes, no deleted tests and unchanged assertion counts in every test
file; the timeout helper gained its single located `#require` in place of two
misleading failure records. Local diff and documentation links were checked.

Actual WindowServer-disabled / physically display-less macOS execution is not
available on this laptop. The forced-headless run validates admission and retained
model coverage, not the operating system under a logged-out session. UI reproduction
requires a logged-in macOS graphical session, a display, the selected Xcode
and (for animation cases that honor it) Reduce Motion off. Do not run a second
native replay concurrently or mutate focus/clipboard during the run. Screen-capture
permission is additionally needed only for the existing WindowServer capture
replays, not the Settings bitmap test. The eight Go fixture replays above remain
separate checks; a skipped plain-Swift invocation is not a passing interop replay.
