# Obsolete-test cleanup, 2026-11-04

Reviewed source baseline: `a77d3a354887eb054516e10d432f825378ca7c8a`.
Worktree: `/Users/felixwang/Desktop/.Mokusei-mokusei-worktrees/remove-obsolete-tests`.

The user enabled Spring Mode during this audit. All still-running regression
processes and their children were terminated. No tests were added. No further
regression runs, PR creation or main integration are part of this delivery.
The detached-worktree commit is for caller-owned integration.

## Removed cases and source evidence

`b240c75` (Route Agent detail input through the Moku bar) removed Conversation's
composer, draft, attachments and send implementation. The current
[Sidecards contract](../../../app/macos/Sources/Plugins/Sidecards/README.md#conversation)
and `ConversationSidecardPresentation` expose an execution display. These are
removed production capabilities, rather than failures in an existing composer.

The entire `NativeSidecardAttachmentPasteTests.swift` was specific to that old
Conversation owner. Removed its five methods and their private fixtures:

- `shortcutDisplaysRemovesAndSendsAttachments(content:)` (five content variants).
- `completedAttachmentsSurviveReleaseAndAreConsumedOnSend()`.
- `lateReceiptConsumesRestoredAttachmentsWithoutClearingNewText()`.
- `pendingRemovalAndLimitsUseSharedDraftPolicy()`.
- `lateReceiptConsumesOnlyAcceptedAttachmentIdentity(successor:)` (five variants).

In `NativeSidecardNavigationTests.swift`, removed only
`conversationConsumesOnlyTheAcceptedDraftAfterReopening(edit:)` (three variants)
and its exclusive plugin fixture/import. Retained
`sidecardAndNestedScrollCannotTakeOverWindowNavigation()` and its actual native
timeline/host fixture.

The shared composer and other Sidecards still have valid input behavior. Kept
`NativeComposerPasteTests`, `NativeComposerAdmissionReplay`,
`NativeMokuHistoryComposerTests`, `NativeThreadSendFeedbackTests` and
`NativeBrowserAnnotationTests`. They exercise current production owners for
paste, attachment admission/identity, late receipts, draft reopening, Thread
input, and Browser annotation sends. Removed Conversation APIs were not recreated
to keep their former tests compiling.

`f78909b` (Make Talk and Note share one reading surface) superseded simultaneous
Talk/Note reading. The current
[handoff contract](../../../app/macos/Sources/Host/MokuScene/README.md#talk-dispatch-and-notes)
retains Talk's native viewport while hiding its ink and accessibility during
Note; Note's footer owns eyes and History/Stop/voice actions.

In `NativeMokuTalkTests.swift`:

- Removed the two `noteOpen == true` parameter combinations from
  `longMessagesKeepClearOfEyesWithoutOpeningAWindow`. Kept idle/running Talk,
  ten widths, ordinary/landing sizes, both languages and all eye/Stop clearance
  assertions for the visible Talk surface.
- Removed the Talk/dispatch-plus-History message-width threshold loop from
  `noteActionsFitMeasuredControlsAtBoundaries`. In production the Note actions
  are visible only when `noteExpanded`, which supplies `hasMessage: false`.
  Kept its existing compact/stacked control boundary assertions.
- Adapted `narrowActionStackKeepsMountedControlsInsideItsBounds` to the current
  `hasMessage: false` input. Kept all five widths and every bounds/non-overlap
  assertion. This is an existing valuable case, not another deletion.

Kept Note's current History/covered-transcript checks, Talk projection, Unicode
budgets, dismissal/deadline checks, selectable clipping, voice scrolling and
Stop-retirement coverage. No visual threshold, timeout or skip was changed.

## Adapted expectation, retained safety coverage

`4838020` (Queue direct-to-thread notices without waking idle Moku) deliberately
makes `SendMokuDelivery` return a successful no-op for an already consumed or
uncertain notification, so a stale poll cannot resubmit it.

`TestMokuDeliveryAdmissionFence` still required an error in those two cases.
Changed those expectations to a nil error and empty admission result. Retained
the exact native call counts, durable uncertain state, operator reconciliation,
pre-admission failure and successful receipt-consumption checks. The initial
failure therefore did not justify deleting the case.

## Execution record and limits

The following checks ran **before** Spring Mode was requested:

| Check | Observed result |
| --- | --- |
| `go test -json -race -count=1 ./...` through the pinned Go/reporter | 455 named nodes passed, 4 skipped, 1 failed: the old `TestMokuDeliveryAdmissionFence` error expectation. 88 packages, including 57 without tests. |
| `go test -json -race -count=1 ./internal/core/runtime` after adapting that expectation | All 16 methods passed; exit 0. |
| CI `runtime` replay group | All 10 checks passed: transport, runtime concurrency, storage/workspaces, command boundaries, application host, settings shell, metadata, search, Git and content publication. |
| CI `fixtures` group | All five producers passed and exported six nonempty Go/Swift fixture files. |
| CI `adapters` group | Claude passed. Codex was interrupted on request; all six later checks were not run. No complete-group pass. |
| Initial Swift `--build-tests` | Failed on removed Conversation draft/attachment/send APIs. |
| Swift `--build-tests` after removing the Conversation-only cases | Passed, before the subsequent Talk-case cleanup. |
| Ordinary serial Swift run using the generated fixtures | Interrupted on request. Its intermediate inventory contained 536 methods; the log has 84 passing Swift Testing method outcomes and 7 fixture skips, but no final Swift Testing summary. XCTest completed 17 cases with 8 interop skips and zero failures. This is not a complete-suite pass. |

The four Go skips require `MOKUSEI_SYSTEM_CODEX`. Swift interop/native-owner
skips or exclusions remain the existing capability boundaries; none were added
by this cleanup. Standalone AppKit owners, native CLI/system matrices, the rest
of the adapter group and hosted CI were not completed.

Raw local evidence is under `.build/obsolete-tests/` (ignored build output).
The interrupted adapter report may still say `running`, and Swift's receipt may
be incomplete after termination; neither is treated as successful evidence.
The two Swift build logs are `/tmp/mokusei-obsolete-swift-build.log` and
`/tmp/mokusei-obsolete-swift-build-2.log`.

After Spring Mode, review was limited to source/history comparisons, reference
searches, diff/whitespace/local-link review and confirmation that the owned test
processes exited. The final Talk edits have no regression-run result. Main's
actual remote rules require an up-to-date PR and `Complete coverage`; this work
does not claim that gate passed or change/bypass it. No product defect was
established by the completed checks, but the interrupted native/adapter coverage
leaves the final suite unverified.
