# Agent main execution heading regression

## Evidence and cause

Investigation baseline: local main and the detached worktree both at `a54aca2`.
The supplied screenshot shows an active execution filling the main Agent panel,
without its title or emoji. Read-only inspection of that Thread in the Native Dev
profile found one running execution and no inherited history. This particular
example has no older execution to display alongside it; no history was removed
by this repair and no user records were changed.

`9a06b0f` (Fix running execution presentation in native readers) changed both
the current document heading and history/result heading to hide whenever
`agentDetail && selectedIsActive`. That condition also matches the ordinary
main reader. It makes a first active execution look like an execution Sidecard,
even though it is still the main document.

The fix additionally requires the `.execution` presentation for suppression.
Main documents retain title and emoji regardless of activity; Report's existing
related-execution policy is unchanged. The current-document and history/result
paths receive the same boundary correction.

## Two-card ownership and navigation review

- The thread manifest retains the complete execution index. `ThreadConversation`
  publishes the index from all rows before presentation exclusions.
- `ConversationExecutionState` gives an active execution to the Sidecard only
  when another execution or inherited history exists. A first execution stays
  in main. `ConversationSidecardPresentation` opens an eligible entry once,
  respecting explicit historical targets and subsequent user selection.
- `NativeSidecardWorkspaceSnapshot.excludedExecutionIDs` excludes the owned
  active execution even when folded. Main then selects the last remaining
  execution. Completion handoff retains its existing ownership and readiness.
- `e00e49e` resolves Report-related navigation to the latest execution inside
  Report's existing reader; it does not rewrite history or Report references.
  `e38d386` scopes Report input suppression and does not replace Agent routing.
- The native handoff container and its input ownership changes were reviewed;
  this repair does not modify their lifetimes, navigation, drafts or subscriptions.

The supplied one-execution example proves the heading scope error, not a loss of
the two-execution index. No speculative data repair or eligibility change is
made. The multi-execution path is preserved by code review; rendered dual-card
behavior is not certified without a permitted runtime verification.

## Parallel work and validation

The parallel Report title/emoji task may touch the same two expressions in
`ThreadConversation.swift`. During integration, retain main-reader headings
while applying its Report-specific policy. This patch does not change Report
components, process summaries, title fallback, metadata or persistence.

Sprint scope: Swift frontend syntax parsing and `git diff --check`, plus source
and local documentation-link review. No new tests, regression runs, PR, hosted
CI or application restart. No full build or runtime visual verification. The
caller integrates the detached commit into local main.
