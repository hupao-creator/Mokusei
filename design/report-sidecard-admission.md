# Report reading admission and referenced executions

## Problem and scope

The supplied 2026-11-05 13:44:13 recording shows the related-execution card
expanding during Report entry, including repeated visits. The old admission
only waited for primary panel travel and a folded layout commit; HTML query
completion and WebKit loading were independent. A second, outer Browser
selection could expand alongside the Report's related-execution selection.
The supplied related-execution screenshot also shows a missing title/emoji and
an unwanted execution-process summary.

## Behavior

- Report first commits a full-width, folded layout. Its current HTML query must
  return the requested content revision, and the owning WebKit main-frame
  navigation must finish. Primary travel and the folded layout commit must also
  finish. Only then does a cancellable 200ms admission interval begin.
- This interval is a minimum after readiness, including with Reduced Motion;
  it is not a timeout measured from the initial click. The main actor can deliver
  its completion later under load. WebKit `didFinish` is the document boundary;
  indefinitely running scripts, subsequent DOM changes, and future lazy assets
  are not a second application loading contract.
- Related references, a selected referenced execution, and the linked Browser
  share one active Report sidecard selection. Before admission, the latest
  request is pending. A pending launcher's second click cancels it. After
  admission, toggles and replacements use the existing motion immediately.
- Closing clears the pending choice. The timer admits the latest choice rather
  than capturing an earlier card, so replacement or closure cannot revive the
  default related list. Loading a new revision/navigation revokes admission;
  failures remain folded until a successful retry. Covering or leaving the
  route cancels pending presentation. A new route visit owns fresh state.
- Document/view and navigation identities reject stale WebKit completions.
  Selection identities reject old auxiliary Back and Browser close callbacks;
  a newer URL request also retires the old Browser callback. Folded documents
  retain their readers but cannot receive input or accessibility focus.
- Referenced executions retain the existing host-owned `.execution` data scope.
  Their heading uses the exact execution's stored title (timestamp fallback)
  and the Harness's existing thread emoji. They hide execution work and its
  summary while preserving the final reply, independent errors, interactions,
  author, status, timestamps and usage. The live Agent execution Sidecard keeps
  its existing heading/work policy.

## Ownership and validation

The isolated HTML surface publishes typed, revision- and view-scoped readiness
through a SwiftUI preference. Report consumes that observation and its native
layout gate. The outer Report workspace and plugin share one presentation owner
through the environment; standalone Report fixtures use the same owner's local
fallback. No Runtime schema, Harness data decoder or Agent sidecard selection
contract changes.

Sprint mode explicitly excludes new tests and regression execution. Validation
is source/lifecycle review, application compilation and static/diff/link checks;
no automated interaction, animation capture, CI, push or PR is triggered for this
change. Recording/screenshot inspection diagnoses the original behavior and
does not certify the modified application's rendered behavior. The managed
detached worktree delivers a commit to its caller for local main integration.

The application product build, `make lint` (architecture/static registration,
formatting and `go vet`), diff review and documentation link checks passed.
Initial sandbox-only attempts could not start SwiftPM's nested sandbox or write
the Go compiler cache; rerunning these same build/static commands with the
required environment access succeeded. Effective remote main rules require
strict `Complete coverage` and a pull request; those remote gates were only
inspected, not executed or bypassed for this local Sprint delivery.
