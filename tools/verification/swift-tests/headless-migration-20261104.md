# Headless migration after obsolete-test cleanup, 2026-11-04

Base/cleanup commit: `4418041b17682c7844e66ba95057691752872ad6`
(Remove tests for retired Conversation input and stacked Talk/Note).
It was fast-forwarded into the clean detached worktree before these edits.
Follow-up cleanup `a83c22164c87f65088adddce69583ada70f50652` (Align Overview
chaos assertions with global search) was also fast-forwarded after checking its
three-file diff. Its real-app Overview interaction driver remains graphical;
the changed global-search oracle is retained verbatim. There was no file overlap
with the migration and no change to the Swift suite inventory. The migration's
direct parent is this follow-up, which already contains `4418041`.
Worktree: `/Users/felixwang/Desktop/.Mokusei-mokusei-worktrees/headless-test-audit`.
The migration is a separate descendant commit for caller-owned integration.
No branch/main changes, PR, push, new tests or regression execution are included.

## Inventory and meaning of headless

The cleanup tree has three Swift test targets in
[Package.swift](../../../app/macos/Package.swift): Core, Host and Threads.
Static source enumeration finds 519 Swift Testing declarations and 17 XCTest
methods; parameterized cases are not expanded. These are not observed outcomes.
Go has 74 `_test.go` files in 31 directories, plus executable Go protocol/CLI
replays. Their existing process execution has no browser/display switch to turn
off. macOS-only profile/clipboard/platform boundaries remain on macOS.

No Playwright, Puppeteer, Selenium, Chromium, Xvfb or browser configuration was
found. The browser boundary is native WKWebView, not a launchable headless
Chromium process. [replays.py](../../../scripts/ci/replays.py) owns runtime,
adapters, fixtures, interop and native groups; the Go/Swift launchers retain their
original fixtures and native owners.

`MOKUSEI_TEST_HEADLESS=1` only denies the
[requiresDisplay trait](../../../app/macos/Tests/Support/NativeTestEnvironment.swift).
It does not remove WindowServer or disable GPU/WebKit services. Setting it on the
entire suite would skip valid coverage. `MOKUSEI_HEADLESS` is a different Runtime
option affecting environment/cache resolution; this migration does not set it.

## Selection and unchanged behavior

The [shared registry/runner](../../../scripts/ci/swift_execution.py) selects whole
suites only. The eight previously reviewed suites (37 methods) remain selected;
27 self-contained suites and four fixture-backed suites are added. At this
baseline, that is 35 self-contained suites/200 declarations, or 39 suites/229
when all four existing producer environments are available. The current build's
discovered inventory, not these static counts, controls actual execution.

No Swift/Go test source, production source, assertion, parameter, deadline or
native owner changed. No display trait or skip allowlist was relaxed. The
environment override has no production-code reader: selected suites have no
`requiresDisplay` trait and do not call window/activation/capture helpers.
The reviewed helpers remain the same implementations:

- Core wire/cancellation, Markdown source mapping, catalog projections, draft
  admission, Browser annotation lifecycle and cache tests exercise models,
  temporary files and existing transport/injection seams.
- Overview geometry/gesture/auto-return tests drive production camera tasks and
  their real clocks; they do not use the mounted canvas or a display link.
- Talk and reading-headless tests use unattached NSHostingViews/NSViews. Existing
  `host.window == nil` checks and teardown/cancellation assertions remain.
- Voice analysis consumes synthetic PCM. Capture wiring attaches the production
  processing delegate without starting a device. Voice ownership injects
  ReplayMedia/ReplayAudioDevice; transcript polling suspends the permission seam
  before device allocation. Timer injects its Player, so no real bell plays.
- Metal retains its actual packaged library, device and SwiftUI ImageRenderer
  pixel assertions. This is GPU-backed offscreen rendering, not CPU simulation.
- NativeSettingsDiscoveryTests shares a source file with a graphical helper,
  but its only test exercises installation replies/retirement and calls
  SwiftUIReplay.wait. That helper uses `NSApp?.windows` and does not initialize
  AppKit for model-only callers. NativeMarkdownHTTPMediaTests similarly shares
  the Browser viewport file but calls only the loopback HTTP fixture/media cache.

Each row below names the existing source, not a replacement test.

| Self-contained suite | Method declarations | Source |
| --- | ---: | --- |
| `RuntimeAppliedDeliveryTests` | 3 | [RuntimeAppliedDeliveryTests.swift](../../../app/macos/Tests/Core/RuntimeAppliedDeliveryTests.swift) |
| `RuntimeProtocolTests` | 5 | [RuntimeProtocolTests.swift](../../../app/macos/Tests/Core/RuntimeProtocolTests.swift) |
| `RuntimeQueryCancellationTests` | 1 | [RuntimeQueryCancellationTests.swift](../../../app/macos/Tests/Core/RuntimeQueryCancellationTests.swift) |
| `ClaudeErrorSurfacingTests` | 6 | [ClaudeErrorSurfacingTests.swift](../../../app/macos/Tests/Integration/Threads/ClaudeErrorSurfacingTests.swift) |
| `ThreadCardExtensionLayoutTests` | 3 | [ThreadCardExtensionLayoutTests.swift](../../../app/macos/Tests/Integration/Threads/ThreadCardExtensionLayoutTests.swift) |
| `ThreadCardStatusTests` | 2 | [ThreadCardStatusTests.swift](../../../app/macos/Tests/Integration/Threads/ThreadCardStatusTests.swift) |
| `MarkdownFallbackSourceTests` | 4 | [MarkdownFallbackSourceTests.swift](../../../app/macos/Tests/Integration/Host/MarkdownFallbackSourceTests.swift) |
| `MarkdownSourceIdentityTests` | 6 | [MarkdownSourceIdentityTests.swift](../../../app/macos/Tests/Integration/Host/MarkdownSourceIdentityTests.swift) |
| `MarkdownSourceRangeTests` | 8 | [MarkdownSourceRangeTests.swift](../../../app/macos/Tests/Integration/Host/MarkdownSourceRangeTests.swift) |
| `MarkdownTableRewriteTests` | 3 | [MarkdownTableRewriteTests.swift](../../../app/macos/Tests/Integration/Host/MarkdownTableRewriteTests.swift) |
| `NativeArchivedThreadsTests` | 1 | [NativeArchivedThreadsTests.swift](../../../app/macos/Tests/Integration/Host/NativeArchivedThreadsTests.swift) |
| `NativeBrowserAnnotationTests` | 4 | [NativeBrowserAnnotationTests.swift](../../../app/macos/Tests/Integration/Host/NativeBrowserAnnotationTests.swift) |
| `NativeCloudMetalTests` | 5 | [NativeCloudMetalTests.swift](../../../app/macos/Tests/Integration/Host/NativeCloudMetalTests.swift) |
| `NativeComposerAdmissionReplay` | 8 | [NativeComposerAdmissionReplay.swift](../../../app/macos/Tests/Integration/Host/NativeComposerAdmissionReplay.swift) |
| `NativeMarkdownHTTPMediaTests` | 1 | [NativeBrowserViewportTests.swift](../../../app/macos/Tests/Integration/Host/NativeBrowserViewportTests.swift) |
| `NativeMokuBlinkTests` | 4（历史记录；rebrand 后移除） | 眼睛与眨眼已退役 |
| `NativeMokuDirectoryMentionsTests` | 3 | [NativeMokuDirectoryMentionsTests.swift](../../../app/macos/Tests/Integration/Host/NativeMokuDirectoryMentionsTests.swift) |
| `NativeMokuExecutionLinkRoutingTests` | 2 | [NativeMokuExecutionLinkTests.swift](../../../app/macos/Tests/Integration/Host/NativeMokuExecutionLinkTests.swift) |
| `NativeMokuOperationTests` | 2 | [NativeMokuOperationTests.swift](../../../app/macos/Tests/Integration/Host/NativeMokuOperationTests.swift) |
| `NativeMokuTalkTests` | 15 | [NativeMokuTalkTests.swift](../../../app/macos/Tests/Integration/Host/NativeMokuTalkTests.swift) |
| `NativeOverviewAutoReturnTests` | 6 | [NativeOverviewAutoReturnTests.swift](../../../app/macos/Tests/Integration/Host/NativeOverviewAutoReturnTests.swift) |
| `NativeOverviewCameraReadabilityTests` | 12 | [NativeOverviewCameraReadabilityTests.swift](../../../app/macos/Tests/Integration/Host/NativeOverviewCameraReadabilityTests.swift) |
| `NativeOverviewDirectoryTagTests` | 13 | [NativeOverviewDirectoryTagTests.swift](../../../app/macos/Tests/Integration/Host/NativeOverviewDirectoryTagTests.swift) |
| `NativeOverviewGestureTests` | 6 | [NativeOverviewGestureTests.swift](../../../app/macos/Tests/Integration/Host/NativeOverviewGestureTests.swift) |
| `NativeOverviewPackingTests` | 5 | [NativeOverviewPackingTests.swift](../../../app/macos/Tests/Integration/Host/NativeOverviewPackingTests.swift) |
| `NativeOverviewScopeFilterTests` | 7 | [NativeOverviewScopeFilterTests.swift](../../../app/macos/Tests/Integration/Host/NativeOverviewScopeFilterTests.swift) |
| `NativePerformanceCacheTests` | 8 | [NativePerformanceCacheTests.swift](../../../app/macos/Tests/Integration/Host/NativePerformanceCacheTests.swift) |
| `NativePerformanceDeliveryReviewTests` | 2 | [NativePerformanceDeliveryReviewTests.swift](../../../app/macos/Tests/Integration/Host/NativePerformanceDeliveryReviewTests.swift) |
| `NativeReadingPageHeadlessTests` | 6 | [NativeReadingPagePresentationTests.swift](../../../app/macos/Tests/Integration/Host/NativeReadingPagePresentationTests.swift) |
| `NativeSettingsAnimationVisitTests` | 2 | [NativeSettingsAnimationVisitTests.swift](../../../app/macos/Tests/Integration/Host/NativeSettingsAnimationVisitTests.swift) |
| `NativeSettingsDiscoveryTests` | 1 | [NativeSettingsLoadingReplay.swift](../../../app/macos/Tests/Integration/Host/NativeSettingsLoadingReplay.swift) |
| `NativeThreadVisibilityTests` | 2 | [NativeThreadVisibilityTests.swift](../../../app/macos/Tests/Integration/Host/NativeThreadVisibilityTests.swift) |
| `NativeVoiceAnalysisTests` | 9 | [NativeVoiceAnalysisTests.swift](../../../app/macos/Tests/Integration/Host/NativeVoiceAnalysisTests.swift) |
| `NativeVoiceCaptureWiringTests` | 6 | [NativeVoiceCaptureWiringTests.swift](../../../app/macos/Tests/Integration/Host/NativeVoiceCaptureWiringTests.swift) |
| `NativeVoiceOwnershipTests` | 29 | [NativeVoiceOwnershipTests.swift](../../../app/macos/Tests/Integration/Host/NativeVoiceOwnershipTests.swift) |

| Fixture-backed suite | Method declarations | Existing producer variable / source |
| --- | ---: | --- |
| `NativeMokuDispatchTests` | 7 | `MOKU_STATUS_NATIVE_FIXTURE`; [NativeMokuDispatchTests.swift](../../../app/macos/Tests/Integration/Host/NativeMokuDispatchTests.swift) |
| `NativeMokuTimerTests` | 8 | `MOKU_TIMER_NATIVE_FIXTURE`; [NativeMokuTimerTests.swift](../../../app/macos/Tests/Integration/Host/NativeMokuTimerTests.swift) |
| `NativeOverviewTagEmojiTests` | 4 | `MOKUSEI_CONVERSATION_CONTRACT_EXPORT`; [NativeOverviewTagEmojiTests.swift](../../../app/macos/Tests/Integration/Host/NativeOverviewTagEmojiTests.swift) |
| `NativeVoiceInputTranscriptTests` | 10 | `MOKUSEI_VOICE_EVENT_EXPORT`; [NativeVoiceInputTranscriptTests.swift](../../../app/macos/Tests/Integration/Host/NativeVoiceInputTranscriptTests.swift) |

The four fixture suites move only when their existing environment variable is
nonempty. Their own file decoding/validation remains authoritative; an invalid
path still fails in the original test. Without the variable they remain in the
ordinary graphical process, preserving their previous fixture deferral. Hosted
CI already exports all four before ordinary execution. No fixture producer runs
merely to decide the selection.

## Execution and coverage contract

`swift-native.py run` and local `swift-tests.py --run` share the same plan:

1. Run the reviewed suites with the existing anchored suite-prefix filter,
   `--skip-build` and `MOKUSEI_TEST_HEADLESS=1`. Hosted execution retains
   `--no-parallel`; local execution retains its previous framework scheduling.
2. Run the graphical complement serially with a negative suite filter. Both
   commands retain the full native-owner exclusion, including runtime source
   suffixes. Unknown/mixed suites remain in this complement.
3. Keep both method lists, commands, per-process environment override, actual
   exit code/status, timestamps and separate logs in `swift.json`,
   `headless-swift.log` and `swift.log`. A failure does not erase the other run's
   evidence. Cancellation unwinds deadline.run and drains its process group.
4. Audit each mode against its exact assigned IDs and framework summary, then
   reconcile both with the full ordinary inventory and unchanged native owners.
   Any headless skip, omission, duplicate, wrong mode or incomplete summary
   fails. Existing named graphical fixture/native deferrals still require their
   actual passing replay outcome. No unrelated replay inherits the override.

The local wrapper first builds/lists current sources once, then reuses that
binary for both modes. The hosted build/discovery and one-macOS-runner contract
remain intact. GUI/native replay groups stay serial. The existing CI controller
fixture only gains the new runner dependency in its staged-file list; no test
case or assertion was added.

## Retained graphical or uncertain suites

- All mixed suites remain on their original graphical path: IntegerWireTests,
  GitNativeTests, GitThreadExtensionTests, ThreadCardInitialResponseTests,
  NativeComposerAttachmentChipTests, NativeComposerPasteTests,
  NativeLoadingMarkTests, NativeMokuNoteTests, NativeMokuOutsideClickTests,
  NativeOverviewMembershipTests, NativeOverviewSearchTests,
  NativeReportNavigationTests, NativeSettingsUserFlows,
  NativeStartupPerformanceTests, NativeThreadSendFeedbackTests and
  SwiftUIOverviewInteractionTests. Some methods are pure, but routing the whole
  suite would also move mounted/pixel/focus or external-fixture cases. No method
  splitting or test-body refactor was attempted under the static-only scope.
- BrowserViewport keeps its suite-wide display admission. SPA history/cookies
  look separable, but other methods require key-window WebKit responders,
  annotation capture and live render-layer attachment. Removing its suite trait
  without runtime verification cannot establish equivalent coverage.
- Composer IME/paste/selection, native settings controls and transitions,
  Browser sheets/file panels, sidebar/pointer navigation and window controls
  retain their native hosts. They exercise actual responder/event-loop/window
  ownership. `SwiftUIReplay.window(offscreen: true)` still activates an app and
  orders a key window; offscreen placement is not windowless execution.
- Overview capacity/mounting/entry/centering/resizing/transitions, glass,
  loading clocks, Moku landing/history/voice layout and clipping retain display
  execution. Their assertions depend on mounted geometry, occlusion, live clocks
  or composed pixels. All 11 explicit methods in
  [swift_ownership.py](../../../scripts/ci/swift_ownership.py) keep their original
  capture/native owner, execution marker and intermediate-frame requirements.
- Standalone native replay apps keep NSApplication.run, activation, LaunchServices
  and graphical-session locking. Scrollbars and Moku appearance were already
  windowless; Overview geometry and model performance probes were already
  unmounted. Note-performance uses a prohibited-activation but real hidden
  NSWindow: it stays unchanged. Foreground Overview performance deliberately
  requires four visible running cards and cannot become a hidden measurement
  without changing the workload.

macOS 26/Xcode/Metal and packaged native frameworks remain required for Swift.
WKWebView requires system XPC service access even without a visible window.
No Linux port, virtual display, GPU fallback, global preference change or physical
no-WindowServer guarantee is introduced. Real microphone, physical trackpad and
optical/foreground performance acceptance retain their existing limitations.

## Validation and remaining uncertainty

Spring Mode limits this revision to static checks. Completed: in-memory Python
syntax compilation (no module/test entry point executed), static registry-to-source
matching/counting and window/display-call review, diff/whitespace review and local
Markdown-link review. Test/production source and native-owner registry diffs were
checked against the cleanup parent and are empty.

Not run: builds, Swift/Go/regression suites, replay launchers, CI controller tests,
real Swift Testing filter execution, cancellation probes, native windows, WebKit,
Metal or hosted CI. Static review supports the unchanged selected test bodies and
exact disjoint selection plan, but does not certify a successful native run,
physical headlessness, OS scheduling, process-startup cost or runtime filtering
on this revision. No speedup or coverage-pass result is claimed.

The cleanup audit's historical/interrupted results remain separate; none certify
this descendant migration. No hooks that launch checks are run for the commit.
No PR, push, main integration or remote protection change is part of delivery.
