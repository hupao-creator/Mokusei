# Private thread voice discussions

[manager.go](manager.go) owns thread/device media sessions; [discussion.go](discussion.go) composes a private native discussion with voice. All four registered Harnesses implement `DiscussionPreparer`. A discussion's native voice capability takes precedence and a preparation failure is returned without fallback. Otherwise the configured Codex voice relay forwards questions to the source Harness's private branch.

Only the two project read/list tools in [tools.go](tools.go) are injected. Realpath checks prevent directory and symlink escapes. Questions never advance the source task or grant its pending approvals. [history.go](history.go) stores spoken transcripts separately from source conversation state.

File reads return at most 32 KiB and a byte `nextOffset` on a complete UTF-8
character boundary. Sequential pages preserve multibyte text; an explicitly
supplied offset inside a character is rejected. The command-boundaries replay
exercises this file-tool contract without starting a native discussion.

## Native history and isolation

OpenCode 2.0.25 uses `POST /api/session/:id/fork` in the source native database.
The response must identify a distinct session and its source lineage. Only the
private branch receives model/agent updates, questions, interrupts and deletion.
The independent process uses existing exclusive configuration isolation: ambient
plugins, MCP and project instructions cannot provide execution tools. Bridge
registration of the source is local ownership metadata, with source inference
explicitly denied; it is not a native source write. Injected Providers reopen the
source Thread's private database, rather than silently using a new empty database.

An ordinary OpenCode fork that has not yet materialized already holds a frozen
native export. Discussion imports that export into its own assigned identity;
it does not materialize or update the ordinary source Thread. This case preserves
the frozen conversation data, but does not claim native `/fork` lineage/cache
affinity. Missing materialized native history fails instead of importing a stale
snapshot or inventing a text summary.

OpenCode `/generate` is explicitly transient and does not mutate session history.
A continuous discussion therefore uses `/prompt`, native execution `/wait`, and
native export on its private branch. This keeps previous questions, answers and
read-only tool results available to later questions. The source's mutable runtime
and execution admission never participate.

Pi 1.3.0 uses `--session-dir <private> --fork <frozen JSONL>` with its native RPC
process. The CLI's `SessionManager.forkFrom` copies the native entry tree under a
new session identity; it is not an in-place `/tree` navigation or an RPC `/fork`
selector that edits the source. Pi reconstructs context from its active path and
native compaction, including summaries where Pi has compacted history. This does
not promise that every old turn bypasses the model's context/compaction limits.

The Pi source is its committed native JSONL, including an unmaterialized ordinary
fork's `ForkSource`. During execution the adapter clears that committed snapshot;
discussion can instead read and freeze the source's persisted session file without
opening or resuming its RPC process. Only persisted entries at preparation time
are included, not live text deltas still being generated. Incomplete/invalid JSONL
fails before media capture; retry after the native write completes. An empty
source is an explicit error. No truncated public-message snapshot is substituted.

Pi verifies the allocated file stays in the private directory, has a new native
session identity, and actually applied the source provider/model/thinking. Native
tools, ambient extensions, skills, prompt templates and context files are disabled.
Only the explicitly loaded existing Host extension receives the two Core-owned
project read tools. Both `--tools` and the FD3 bridge acknowledgement are necessary:
the installed loader can otherwise clear tools after extension initialization.

## Lifetime and failures

Both backends serialize questions on one private native session, reject empty or
cancelled inputs, and wait for the native terminal boundary. Pi uses
`agent_settled`, not `agent_end`. Native failure/empty output is an error. A failed
or cancelled dispatched question disposes its uncertain private conversation;
restart the call to create another discussion. The relay retains its existing
readable/spoken failure path and delivery/generation identities.

Stopping media, cancelling preparation, or failing media startup closes only the
owned discussion. OpenCode keeps its process alive for bounded interrupt/delete
cleanup after caller cancellation, then joins shutdown. Pi closes its owned
process/bridge before deleting its private files. Cleanup is idempotent and errors
are joined with the initiating failure. If the native process/protocol itself
fails so branch deletion cannot be confirmed, that cleanup error remains visible;
there is no assertion that an unreachable database was successfully cleaned.

These are tool-boundary read-only discussions, as with existing Harness adapters;
the trusted external Harness executable/extension loader is not an OS sandbox.
OpenCode's existing remote-configuration and native Provider exclusivity checks
still fail closed. Unsupported native account/model policies are not bypassed or
silently routed to a different account.

## Verification

The [OpenCode](../../../tools/verification/opencode/README.md), [Pi](../../../tools/verification/pi/README.md), [Codex](../../../tools/verification/codex/README.md) and [Claude](../../../tools/verification/claude/README.md) runners exercise their adapters. `./scripts/go.sh run -race ./tools/verification/runtime -swift-voice` includes actual Swift integer JSON and the Runtime thread-voice path on macOS. `tools/verification/thread-discussion-live` is an explicit real-account inference runner; its results are separate from synthetic protocol/media fixtures.
