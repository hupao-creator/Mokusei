# History author and title ownership during vertical navigation

> 动效策略已更新：本文有关系统 Reduce Motion 的行为与验证描述仅记录历史。当前应用不再感知该偏好；见[移除清单与验证](remove-reduce-motion.md)。

Investigated on 2026-11-17 from the supplied `录屏2026-11-17 14.46.21.mov`,
on detached baseline `fb6edadc70c0ffc15dfeeafedc0fefebef5e9b46` with a clean
managed worktree. The recording was read only. No live application, user
conversation data or microphone was operated.

## Recording evidence

The movie is 4096×2554 and 10.045 seconds long. Key-frame times below are
approximate movie positions, not instrumented input or resource timings.

| Time | Visible observation |
| --- | --- |
| 0–1.5s | Current Agent document: 🔍, “复核卡片最小缩放并集成主分支”, resolved model/effort and its reply. The pointer approaches the left history rail; its preview identifies the earlier execution. |
| ~1.60–1.85s | The title changes in place to “复核线程搜索移除并集成主分支”; author becomes a skeleton. The 🔍 icon, current reply and current completion footer have not changed. |
| ~1.9–2.2s | The current document moves down as the historical document arrives from above, with 🎨, its own title, resolved author and older reply/footer. |
| ~3.9–4.3s | Return travel brings the current reply and 🔍 back with the historical title and author skeleton; the current title/author recover only near the end. |
| ~5.6–6.3s | Another historical visit repeats the in-place title/author mismatch before vertical travel. |

This is a shared native Agent reader and its TOC-driven vertical history stack,
not a Report WebView or an execution-completion Sidecard handoff. The recording
shows pointer/preview and document travel; it does not independently establish
a physical wheel event or the exact click timestamp. There was no missing
vertical animation: the wrong identity was painted on the retained document
before/during that animation.

## Two symptoms, shared ownership error

`ThreadConversation` keeps a current `HarnessMessageTimeline` mounted behind
`ThreadHistoryDocument`. `selectRow` changes the navigation destination before
`NativeReadingPageStack` travels. Its current body still comes from
`documentRows`, while `selectedRowID` now identifies the historical destination.

1. **Author clears first.** The current header looked up `authors` using
   `selectedRowID`'s execution. That dictionary contains preferences from turns
   mounted in the current timeline; the historical turn belongs to a different
   document with its own dictionary. The lookup therefore became unresolved,
   displaying the skeleton while the current turn and its resolved author
   were still present. This is not evidence that the recorded author was erased
   or that a subscription was lost.
2. **Title changes in place.** `documentTitle` also used `selectedRowID`.
   The exact historical-title branch immediately replaced the current heading,
   although its body and emoji still belonged to the retained current document.
   Returning retained this mismatch until `finishClosingHistory` reset the
   navigation destination.

Relevant prior changes: `7b5496dc` (*Add a sidebar TOC to agent thread history*)
introduced the selected-row author lookup; `3ebbf582` (*Preserve execution
titles in historical readers*) used selection to resolve historical main
headings; `032510e2` added exact-execution prompt fallback; `d7cf0f6c`
(*Avoid transient unknown-model text when opening a thread*) made unresolved
preferences display a skeleton. The skeleton is legitimate for an incoming
unloaded turn, but cannot repair a lookup against the wrong document.
The separate envelope/remount problem described in
[message settlement flicker](message-settlement-flicker.md) is not this path.

## Repair

The retained document now derives a `documentRow` from its inline/current rows.
Its author lookup, title resolution and running-work presentation use that row.
Navigation selection continues to identify the historical document for the TOC,
input routing and reading requests. The incoming history page still owns its
exact-execution title and mounted-turn author, with normal unresolved/error
behavior until its content arrives.

Both documents therefore carry their own heading/author with their body through
entry and return. Historical title/prompt/timestamp fallback, current catalog
title/emoji updates, scoped asynchronous row decoding, subscription release,
scroll retention, direction, cancellation and animation completion are unchanged.
There is no author cache, delayed metadata switch or new animation delay.

## Validation and limits

- Production `Mokusei` Debug build passed (121.18s), including all four Harness
  consumers. The first restricted build could not launch SwiftPM's nested
  sandbox; the authorized build completed. No product compiler failure occurred.
- Existing reading replay with `MOKUSEI_TEST_HEADLESS=1`: seven windowless
  methods passed; five graphical methods were explicitly skipped. The launcher
  rejected the incomplete suite, so this is not reported as an overall pass.
- Existing isolated AppKit reading replay: all 12 methods passed in 17.169s,
  no skips, including vertical entry/replacement/return and cancellation.
- Existing isolated `--thread-sidebar` replay: all six methods passed in
  18.147s, no skips. Coverage includes actual author selection, current scroll
  retention after Back, running/completed work controls, inherited/deleted and
  external targets, narrow/wide layouts and pointer/keyboard navigation.
- A temporary presentation-only driver reused the existing `SidebarFixture`,
  `SidebarSurface` and `NativeReplay` packaging with the candidate production
  modules. It recorded 31 WindowServer screenshots of its own fixture window
  through entry, return and history replacement. Inspected intermediate frames
  show the departing current title and `Astra turn-4` author remaining with
  `turn-4`'s body, and separate historical title/author/body entering together.
  This has no new test cases or assertions, is not an FPS measurement, and does
  not claim coverage between captured frames. During motion the existing
  interaction collector suppresses inactive author controls; a missing semantic
  registration at that point is not evidence of missing visible author ink.
- Local source review, diff whitespace and documentation links passed. No tests
  were added or modified. The commit hook's unrelated Go-wide lint/vet run is
  excluded by a per-command hooks-path override under this Sprint's scope.

Evidence is local at `/tmp/history-transition-evidence`: movie contact sheets,
`build.log`, `headless-replay.log`, `native-reading-replay.log`,
`sidebar-replay.log`, and `observation/frames/{*.png,samples.json}`. Raw recording
frames are not committed or uploaded. Replay receipts/logs are also retained in
the worktree's ignored `.scratch/reading-presentation` directory.

The presentation fixture uses immediate in-memory turn content. Real
Runtime/disk loading, all four Harnesses under delayed delivery, physical
trackpad input, reduced-motion optical behavior and the signed production app
were not replayed. Existing scope/decoder ownership was reviewed, not replaced
with a claim that those boundaries ran. No full regression or hosted CI ran.

Before validation, the remote classic main protection endpoint returned 404;
the effective branch rules contained a pull-request rule and no required status
checks. Existing main/PR runs were read only and cannot certify this candidate.
This work is a detached local candidate for independent review/integration;
there is no push, PR mutation, main-checkout edit or shared-ref update.
