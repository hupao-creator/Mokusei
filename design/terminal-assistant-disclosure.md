# Terminal assistant disclosure regression

Investigation date: 2026-11-03. Initial detached HEAD and local main were both
`a64a6ade12e9682b669ccd0cc2e20722d76f6cdb`; the worktree was clean.

## Cause and scope

`14f510c` (Show only execution summaries in Agent Thread detail) promoted all
settled Agent assistant replies to ordinary content in all four native readers.
It also retained interim reply bodies in Pi/OpenCode lightweight historical
projections. `a64a6ad` (Isolate thread panel motion from reader mounting) retained
that classification when moving Codex classification before hidden-row
construction. Thus the final local main still displayed terminal intermediate
replies with work hidden; this was not solely a panel animation issue.

The actual Go renderer paths were inspected: Codex `presentation.go`, Claude
`state.go`, Pi `state.go`, and OpenCode `renderer.go`. All retain assistant reply
text in terminal scoped rows. Deferred presence tracks omitted reasoning/work;
it does not require withholding assistant text at the data boundary. Canonical
content and these projections remain unchanged by this repair, allowing explicit
message visits without a full execution lease.

## Reader contract

| State | Ordinary assistant text | Errors and interactions |
| --- | --- | --- |
| Running / waiting | Keep settled replies; preserve the existing streaming gate | Independent errors and pending requests retain their existing admission |
| Terminal, work hidden | Last non-error reply and an explicitly targeted reply | Independent errors and pending requests remain readable |
| Terminal, work shown | Interim replies join execution membership and render only within shared summaries | Independent errors remain separate; failed tools remain work |

Native execution status owns settlement. Focus, the public observation's latest
execution identity, localized labels, and a missing completion timestamp do not
turn an older terminal execution into an active one. Pi retains its existing
exception that releases a still-streaming message once its execution terminates.
Codex/Claude/OpenCode continue withholding their streaming reply bodies.

Final reply selection excludes assistant errors so a later error cannot displace
the last normal answer. Codex's early hidden-work construction guard runs after
reply/attention/target classification. Claude inherited turns retain user-message
boundaries when selecting normal final replies; OpenCode keeps its corresponding
inherited turn/session boundaries. Pi inherited executions use the same native
execution reader. No generic ban on assistant messages is introduced.

Current and historical reading documents carry the accepted message anchor as
part of row visibility. Only that visit's target bypasses terminal work
membership. OpenCode passes the exception through child-session ownership and
mounts targeted child content directly, since a closed disclosure cannot resolve
an anchor inside its unmounted body. Other child work remains summarized/hidden.

## Sprint verification

No tests were added or run. No test hooks, CI, push, PR, branch switch, shared-ref
mutation, or main integration was performed. Review and integration belong to
the caller. Production source changes were reviewed locally, including native
status/streaming gates, attention precedence, source membership, deferred
presence, inherited boundaries, and asynchronous anchor delivery paths.

An isolated manual AppKit/SwiftUI preview linked the current Release production
modules and rendered synthetic data through the actual four Harness readers,
`ThreadDeferredExecutionContent`, and `ThreadConversation`. It used no Runtime,
account, network Harness call, assertion runner, or test target. Temporary files
and build logs live in `.scratch/hide-intermediate/` and are not shipped.

Observed manually:

- All four completed readers hide interim text with work hidden, preserve their
  final readable reply and independent errors, and show only summaries with work
  enabled. Both materialized and lightweight deferred payloads were viewed.
- Running snapshots for all four retain settled interim replies while withholding
  streaming tails. Pi's terminal streaming-tail release remains visible.
- All four waiting snapshots retain settled text. Pi/OpenCode permission and
  question forms remain visible; Codex/Claude fixtures had no native interactions,
  so their request admission was reviewed statically, not exercised dynamically.
- All four whole readers opened an older execution with a targeted interim reply
  visible and sibling work hidden. Codex used its actual `itemId` target contract;
  the other adapters used their native `messageId` contracts.
- A later assistant failure does not hide the preceding normal final answer in
  Codex, Claude or OpenCode. Pi independent assistant errors remain visible.
- Native completion paired with a stale public waiting observation retains the
  normal final reply in all four readers; still-pending public Pi/OpenCode forms
  remain visible. The final build was also revisited in all four running states.
- OpenCode child errors remain reachable with tools hidden. The explicit ordinary
  child-message route was additionally checked after direct target mounting.

Production builds: `go build -trimpath ./cmd/mokusei-runtime` and SwiftPM Release
`--product Mokusei --arch arm64`, without `--build-tests`. A copied old dependency
cache was incomplete and was replaced with a complete local cache. One early
Swift build rejected a source edited during compilation; a full successful
current-source build superseded it. The temporary preview's Observation macro
was unavailable in its standalone compiler environment, so only that preview
shell was changed to `ObservableObject`. Fixture identity mistakes were corrected
without weakening production validation. Go exited zero and emitted its binary,
with a nonfatal sandbox denial when trying to write VCS metadata into its global
module cache. Diff whitespace and changed-document local links were reviewed.

Limits: these are isolated component observations, not live Harness executions,
continuous transport/streaming-event replays, persisted-profile reloads, or signed
production-bundle acceptance. Inherited/fork paths and deferred asynchronous
resource loading/anchor arrival were traced in source, not dynamically replayed.
No real authorization/question response, display-animation performance, physical
input, or accessibility-device acceptance is claimed. Skipped tests/CI are not
reported as passes.

## Main integration review

Independent review found that an explicitly targeted OpenCode child reply with
multiple text parts lost all parts except its anchor while work was hidden.
The integrated reader admits the complete targeted reply by its production part
identities, while sibling replies/tools retain their existing visibility.
The shared reader guide also replaces its older unconditional settled-reply rule
with the running/waiting versus terminal distinction above.
