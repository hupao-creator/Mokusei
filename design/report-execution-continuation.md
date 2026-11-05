# Report execution continuation

## Scope

Opening a Report's referenced execution moves the resident Moku capsule beneath
that execution's column and opens its ordinary Agent editor. The Report list
keeps the 3:7 sidecard-to-Report layout from `89bbbe54`; execution detail keeps
5:5 and the floating glass Back control. Browser sizing is independent.

The application publishes only the exact reference and destination geometry.
The Host reuses native Dock placement, Harness identity, composer, attachment
import, directory mentions, draft admission and Runtime commands. No second
composer or HTML execution bridge is introduced.

## Input and navigation

- Report drafts belong to exact Thread/execution pairs. Ordinary Thread and
  Moku drafts remain independently persisted. Input opens after the native
  horizontal travel settles; resize and stacked layouts reuse that same marker.
- Returning to references, folding, Browser replacement, covering or closing
  removes the target and restores ordinary Moku input. Editor Escape uses the
  current auxiliary Back action. The existing reader/HTML Escape ordering and
  IME, completion and transient-control priorities remain authoritative.
- Sending from the latest execution follows up on its original Thread. The
  optional expected-execution fence is checked after native recovery at Runtime
  admission. A stale catalog cannot silently route input to a successor: the
  draft remains available for a fresh send from its original execution.
- Historical input first uses `thread:fork` with the exact execution selector,
  then uses ordinary `thread:follow-up` on the admitted fork. If the second step
  fails, the window retains the fork identity for retry and the draft stays
  intact. There is no automatic retry of uncertain native input.
- An accepted send opens its exact Agent execution through the existing result
  reading route. Catalog events can lag the receipt. Pending navigation waits
  for the destination Thread and is fenced by route, reference and composer
  generation; closing/switching cannot be undone by a late receipt.
- Stop is available only when the viewed execution is the current active one.
  It uses the existing observed cancellation identity. A historical reader never
  offers Stop for the newer source execution. Pending interactions retain the
  Runtime's existing respond-before-send rule.

## Native fork boundaries

All forks retain the existing Runtime archive, Moku/private-history, workspace,
pending native work and source revision checks. A running source must settle
before historical fork; failure is visible and keeps the draft. A native
checkpoint that cannot be proven to match is an error, never a full-current
session fallback.

- Codex resolves the execution through the native user-message client identity,
  passes `lastTurnId` to native `thread/fork`, and checks the fork's last turn.
  Its projected inherited history stops at the same execution. Unsupported or
  missing native checkpoint identity fails before follow-up.
- Claude resolves the final assistant API message ID to its persisted transcript
  UUID in that exact native session, then reuses `--fork-session` with
  `--resume-session-at`. The API message ID is not used as a transcript UUID.
  Missing/invalid native history, including executions without an assistant
  checkpoint, reports an unavailable checkpoint.
- OpenCode resolves the completed execution's last root native message in native
  transcript order and uses its existing message checkpoint/import path. Later
  context entries are not copied into an exact historical fork.
- Pi checks the complete ordered native/public assistant sequence and the linear
  JSONL parent chain before taking the selected execution's native prefix. It
  uses the existing independent `--fork` snapshot path. Missing, branched or
  nonmatching history, and executions without an assistant checkpoint, fail
  closed rather than using a timestamp or matching a repeated reply alone.

Forking conversation history does not rewind files or the source worktree.
The existing Runtime workspace admission determines the new Thread's workspace.

## Sprint verification

This change uses code review, Go builds/vet/architecture checks, the native Swift
application build and diff/document-link checks. Per the user's sprint mode,
there are no new test cases, test runs, regression replays, PRs or hosted CI.
Compilation does not certify rendered movement, keyboard focus, native CLI
fork behavior or real model execution. Those paths have been reviewed against
the existing implementation and native protocol contracts, not exercised live.
Local main integration preserves other tasks' commits and does not publish.
