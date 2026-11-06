# Message settlement flicker

## Scope and evidence

Investigated from the supplied 2026-11-06 local recording on baseline
`e6f5bf5330397b104417a4e7147d6325c112e50d`, in the detached managed
`fix-message-flicker` worktree. The original recording and user profile were
read only; no application restart, history edit, push or merge was performed.

AVFoundation reports 5.853333 seconds, 4096×2316 pixels and nominal 31.853931 fps.
The recording has variable frame timing. A 50ms extraction around completion
shows these actual frame timestamps in the right execution Sidecard:

| Actual time | Observation |
| --- | --- |
| 1.765s | Settled interim reply, work summary and final reply are visible. |
| 1.848s | Body disappears; the author changes to the unknown-model fallback. |
| 1.898s | Author, work summaries and footer return before final reply text. |
| 1.948s | Final reply returns; terminal interim text is folded into work. |

The Sidecard begins its completion handoff around 2.1s. The later main-reader
page travel is separate from the preceding blank-body defect. Local extracted
frames and the contact sheet are retained in `/tmp/mokusei-flicker-frames`;
private recording frames are not checked into Git or uploaded.

## Cause and repair

Codex's runtime renderer returns a plain row while an execution is active. On
termination, the same row becomes a `deferred-execution` envelope so collapsed
execution details can load separately. The final reply and author remain in its
inner state.

`ThreadDeferredExecutionContent` previously called its renderer in separate
SwiftUI conditional branches for these two envelope shapes. Settlement replaced
the entire mounted row, including `CodexLoadedTurnRow`'s asynchronous decoder,
the author preference, Markdown parsing/reveal state and native text selection.
This accounts for the blank body and unknown author before the same content is
prepared again. Message Markdown uses native TextKit here, not a WebView.

The shared wrapper now validates/unwraps the envelope before one stable render
site. Presence facts and the optional execution-detail loader update in place.
Malformed envelopes remain rejected; detail-group leases and teardown retain
their existing owners. No animation, transition, delay or subscription policy
was changed. The shared UI README documents this lifetime contract.

## Regression

`NativeThreadSendFeedbackTests.settlingScopedContentPreservesTheMountedReplyAndSelection`
mounts the actual workspace, Codex reader, asynchronous decoder and Markdown
controls in a disposable native app. It selects text in a visible settled reply,
delivers the completed scoped row before catalog completion, waits for the
completed author preference to prove UI admission, then samples the original
NSTextView and selection across 20 event-loop turns. Detachment or
replacement fails even if a new view eventually shows the same text.

The existing fixture now supplies scoped rows and completed envelopes instead
of sending a full plain transcript to every subscription. This also exercises
completion handoff with the actual envelope change.

The unchanged production build fails the new assertion:
`Settlement detached the reply or lost its native selection` (the exact final
regression source failed in 1.201 seconds against baseline).
An earlier admission attempt found an invalid author field in the test fixture;
that fixture was corrected and prevalidated before the effective red run.

## Validation and limits

- `xcrun swift build --package-path app/macos --build-tests --skip-update`:
  passed, including the four Harness consumers of the shared wrapper.
- `make lint`: passed (architecture/static registration/no-Node, formatting and
  Go vet). `git diff --check` and the added local documentation link passed.
- `xcrun swift test --package-path app/macos --skip-build --no-parallel --filter
  settlingScopedContentPreservesTheMountedReplyAndSelection`: one Swift Testing
  test passed in 1.421 seconds, with no skips (the XCTest inventory is empty).
- Isolated AppKit replay of the same final regression and the existing receipt
  ordering method: two methods, including both receipt-order arguments, passed
  in 2.161 seconds, with no skips. The regression took 2.100 seconds.

Expanded validation did **not** pass. The existing
`completionHandoffRetainsIdentityUntilTravelAndDestinationAreReady` method has
five assertions expecting the handoff execution to remain excluded, while the
production snapshot immediately admits the hidden destination. The existing
`mountedProductionReadersHandOffAfterContentAdmission` method has eight cases
where the `conversation-sidecard` accessibility frame is absent during travel.
Both unchanged methods were also run against an independently rebuilt archive
of the original HEAD, with the original test fixtures: the same 13 assertions
failed. No assertion, intermediate frame or skip was changed to hide these
baseline failures; repairing that separate handoff-test contract is outside
this message-settlement change. Retained logs and fixture frames are under
`.scratch/message-settlement/{expanded-failures,baseline-existing}`.

The final green regression, native receipt-order replay, build and lint logs
are under `.scratch/message-settlement`. The temporary native driver is retained
there as `run-regression.py`; it stages production objects/resources and a
separate AppKit app using the existing `NativeReplay` isolation utility. Run it
from the worktree root after building to reproduce the focused native check.
The baseline source archive is an ordinary temporary directory, not another Git
worktree; no branches or shared refs were modified. Relocated compiler/Metal
caches required clearing inside that temporary copy before its build passed.
The implementation's first closure form also hit a Swift compiler diagnostic;
a typed detail-view helper resolved it before the successful build.

The running user app was not patched or restarted, so this does not claim a
new recording from that live session. No full local `make check` or hosted CI
was run. Remote effective main rules require strict `Complete coverage` and a
PR; classic branch protection is absent. The requested local-only detached
commit cannot be certified by that remote gate without a later push.
