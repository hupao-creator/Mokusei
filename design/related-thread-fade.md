# Related Thread entrance

## Recording and production path

The supplied 7.367s recording (`录屏2026-11-06 11.49.33.mov`, attachment
`9ff3d25d-93d0-4c41-a565-16215be21b5a`) shows a Report and its related-execution
list. Extracted samples change from the list to a fully painted execution heading
and reply while the Report's width is still moving.
This is an execution-sidecard selection, not a separate native window opening.
The source recording predates this revision; it cannot by itself prove which
source revision generated the frames.

The production path is `NativeReportExecutionRow` → `NativeReportDetail.selected`
→ `ApplicationExecutionReferencesUI.execution` →
`NativeApplicationReferencedExecution` → `NativeHarnessThreadView` →
`NativeHarnessContentView` → the Harness's `ThreadConversation` execution reader.
The Report keeps its existing `NativeSidecardFold`, interpolated WebKit viewport,
floating list-return button and auxiliary Back action. No workspace route or
NSWindow is created by this click.

Previously `NativeHarnessContentView` started the 200ms SwiftUI opacity entrance
on the manifest-ready branch's `onAppear`. A manifest only supplies the execution
index: its scoped row can still be loading, and Markdown parses asynchronously.
The entrance could therefore finish before readable content arrived. It also
excluded loading/read-error branches and belonged to a content surface rather
than the selected visit. The recording's abrupt appearance is consistent with
this timing defect; the source recording has no resource-timing trace.

## Behavior

`NativeRelatedExecutionEntrance` now wraps the capability's entire referenced
reader, including unavailable/error output. It keeps the production reader
mounted at its destination geometry with native opacity zero and shows a loading
indicator immediately. The existing reader content preference and
`NativeReadingContentPreparation` jointly wait for a real row/error and registered
Markdown parsing. Admission crossfades the indicator and fades the retained native
host from 0 to 1 over 200ms, using Core Animation ease-out. Only paint animates;
text geometry does not inherit the entrance transaction.

Hidden preparation excludes reader pointer, keyboard and accessibility activity;
the Report-owned return button remains outside this gate. Identity is scoped to
the selected execution visit, not content revisions. Replacements dispose pending
preparation and native animation. Later streaming updates, resource refreshes and
retry recovery stay in the admitted host and do not repeat the entrance. Folding
retains that host under the existing sidecard interaction gate. A missing execution
in a loaded related manifest now reports unavailability rather than indefinitely
loading. Other execution-card empty-state policies remain unchanged.

Reduce Motion keeps data/parse readiness but skips the fade. Enabling it during
travel removes the native opacity animation and exposes the model's final opacity;
disabling it later does not replay entrance or remount the reader. Reduced
Transparency continues to use the existing opaque reading shell.

## Validation and sprint handoff

Before the sprint preference arrived, the affected Swift application built
successfully. A temporary extension of the existing execution-link replay passed
15 tests in two suites (43.125s, no skips), including the four production Harness
readers, delayed scoped rows, intermediate native presentation opacity,
pointer/AX exclusion, one-shot updates, error recovery, rapid replacement,
missing execution and Reduce Motion before/during admission. Final AppKit
screenshots were saved and the Codex frame was inspected. These are diagnostic
AppKit snapshots, not intermediate WindowServer pixel evidence.

Earlier replay attempts exposed fixture issues: a read-only SwiftUI environment
property could not be assigned in the fixture, and screenshot export initially
omitted directory creation. Both were corrected before the 15-test pass. A later
attempt to mount the real Report row/capability path failed its readiness wait:
it incorrectly assumed a disconnected Runtime immediately produces a read error;
the production client correctly retains its loading subscription until content
arrives. This attempt is not a passing integration result. The next queued
fixture correction/replay was rejected by automatic approval after the sprint
instruction arrived and was not executed.

Per the session's sprint preference, all added tests and replay-script changes
were removed, no further regressions/CI were launched, and AGENTS.md was left
unchanged. The final cleanup also removed the temporary motion-policy injection
parameter used by those tests; production reads the system Reduce Motion
preference directly. Final review includes syntax parsing, diff/whitespace and
local documentation-link checks. The prior build/replay describes the earlier
revision's evidence, not a completed final-revision regression run.

Retained local evidence (ignored by Git):

- `.scratch/reading-presentation/NativeMokuExecutionLinkTests-attempt4`: failed
  screenshot-directory attempt and complete logs.
- `.scratch/reading-presentation/NativeMokuExecutionLinkTests-attempt5`: successful
  15-test run and `related-{codex,claude,pi,opencode}.png`.
- `.scratch/reading-presentation/NativeMokuExecutionLinkTests`: later real-Report
  fixture failure, not an acceptance result.

Remaining limits: the production navigation path was traced in source, but a
successful full Report → live Runtime → ready reader open/return was not verified.
No final-revision regression, VoiceOver end-to-end pass or WindowServer recording
of the fix was completed. Native presentation-layer opacity was observed in the
earlier component replay; this does not certify optical frame cadence.

The remote `main-pr-gates` ruleset requires current-revision `Complete coverage`
with strict freshness; `main-pr-requirement` requires a PR. This detached local
change is intentionally neither pushed nor merged and has no hosted CI result.
The commit is handed to the caller's unified local-main integration process.
