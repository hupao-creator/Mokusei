# Super Thread associated-execution opening failure

## Evidence from the reported visit

The 9.453s recording `录屏2026-11-06 17.37.58.mov` was read from the development
profile attachment `ba022891-2c73-49ea-9e57-dfd2905afcb8`. At 2.5s the Report
HTML and two associated executions are visible. At 3.0s, after selecting an
execution, the right card is folding and the HTML expands. At 4.0s it is fully
folded. Subsequent launcher clicks leave it folded through 9.0s. The document
itself loaded successfully, unlike the first-navigation failure fixed by
`fbf0e50` (Fix Super Thread document suppression by its persistent composer).

Read-only inspection used the existing development profile logs:

- `diagnostics/layout/layout-46679-FE742985-6002-4C9F-9E48-526F7E6EFF3E/events-0.jsonl`
  and `events-1.jsonl`: sequences 15657–15664 discover the selected production
  `ReportExecutionScrollView`, seat and `RelatedExecutionFadeView` at
  2026-11-06 09:38:02.471 UTC, with nonzero 1002×1033 bounds. Sequences
  15738/15743 mount the timeline reading column at 09:38:02.500 UTC. Its removal
  occurs after the recorded failure, at 09:38:15.902 UTC (sequence 19711).
- `diagnostics/performance/native-1793957855454-46679-24A24475-0B16-4FA5-9C54-B680B1ABF8D6.jsonl`:
  execution surface context 213 records completed content readiness and
  acknowledgement for rows 0 and 1 at session offsets 27019.716ms and
  27090.232ms. Harness rendering also completes. This is a mounted reader whose
  sidecard disappears, rather than evidence that the click or row load failed.

Frames and focused log excerpts are retained locally under
`/tmp/super-thread-open-evidence/`: `recording-2.5s.png`, `recording-3.0s.png`,
`recording-4.0s.png`, `recording-6.0s.png`, `recording-9.0s.png`,
`layout-events.jsonl` and `performance-events.jsonl`. The logs record geometry
and content facts, not suppression booleans; the causal chain below is
reconstructed from the production source at base revision `fbf0e50`.

## Trigger and repair

`NativeReportExecutionRow` calls `selectExecution`. That immediately revokes
`mokuSuperThreadID`, because an associated execution has been selected.
`dockThreadID` remains absent until `NativeReportExecutionInputKey` crosses the
view preference boundary and `updateReportExecution` configures Agent input.
The pinned composer still has `inputOpen == true` during this gap.

Both shell suppression expressions previously required an absent Agent target
and absent Moku send context. During this handoff they become true.
`NativeReportLinkWorkspace`/`NativeReportDetail` forward suppression to
`NativeReportSidecardPresentation.updateLayout`, which clears both `active`
and `pending`. Losing the visible execution preference also revokes the
composer's execution target. Reopening the retained selection repeats the gap.

The shell now exempts the stable `report.document` route from input-overlay
suppression throughout the handoff, even before an execution becomes ready or
when a linked source is unavailable. Moku send-context revocation, exact Agent
input admission, content readiness, Settings/camera/Moku-history/interaction
covering gates and sidecard motion gates retain their existing owners. The
Report plugin and its unlink control are untouched.

## Sprint validation limits

Source/lifecycle review, Swift syntax parsing and `git diff --check` passed.
The Debug `Mokusei` product build passed (76.02s); its complete output is in
the local `build.log`. Initial dependency preparation failed before compilation,
and an uncached fetch was interrupted; the successful build used private copies
of the existing SwiftPM repository/artifact caches under the evidence directory.
The compiler reported only the deprecated `--skip-update` option warning.
No tests were added or run; no regression, replay, PR or CI was started. No
application was launched/restarted and no running profile data was changed.
Original recording/log inspection diagnoses the trigger; it does not certify
the modified application's rendered behavior. The detached worktree delivers
a commit for the coordinator to integrate into local main.
