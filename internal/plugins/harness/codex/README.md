# Codex Harness

Exact execution forks accept `{executionId}` through the existing Forker. The
adapter resolves the native user-message client identity, requests `lastTurnId`
on `thread/fork`, verifies the returned history boundary and trims public fork
history to that execution. Missing/unsupported checkpoints fail closed; the
source must satisfy the existing idle/native-work gates. See
[Report continuation](../../../../design/report-execution-continuation.md).

[adapter.go](adapter.go) constructs the adapter; [executable.go](executable.go) discovers the user's installed Codex. [native.go](native.go) and [transport.go](transport.go) own app-server sessions, JSON-RPC and process cleanup. Codex owns model/account configuration and native history; Mokusei owns admission, durable public state and injected application capabilities.

Installation owns the shell pipeline's process group and both output readers.
Cancellation and leader exit drain descendants with bounded TERM/KILL cleanup
before returning; uncertain cleanup remains an error. Combined captured output
is limited to 8 MiB, and cancellation, output-limit and nonzero-exit failures
remain observable. The [installer replay](../../../../tools/verification/harness-install/README.md)
checks the production installation path with local executable fixtures.

Moku rejects empty initial model catalogs and reports partial creation capabilities
when thinking controls are unknown. Target discovery reads the catalog independently of the default
execution profile; configuration-keyed cache snapshots never replace native
creation validation.

## Settings, tools and execution

[settings.go](settings.go) requires explicit model, thinking and service-tier choices for ordinary task creation. `default` is the standard tier; other tiers must be advertised by the selected model. A missing/null/boolean tier is not inheritance. Native replies confirm the effective tier; explicit null means known standard, while absence is unreported. [presentation.go](presentation.go) uses reported execution facts for Fast status before falling back to requested settings.

[tools.go](tools.go) exposes injected tools through an authenticated local MCP bridge with a schema budget sized for the supplied definitions. Tool execution is bound to the admitted native thread/turn and cancellation context. Exclusive injection disables unrelated native/MCP tools. Stock resource-helper names do not confer authority: the bridge returns no resources/templates and has no resource-read implementation.

Every injected tool's original input schema is also serialized into one
`developerInstructions` contract block on native start, resume and fork. Codex's
tool-parameter conversion can drop conditionals and obscure selector-only
unions; the instruction copy preserves the full declarative contract, including
references, exact numbers and nested native choices. This applies automatically
to new tools, without tool-name checks, schema simplification or producer flags.
MCP definitions and callback validation remain unchanged. The block is built
from the current preparation's bindings and does not accumulate on caller
instructions. Empty injections add nothing; output schemas are not duplicated.
Full input schemas add context proportional to their serialized size. Schema
descriptions and literals are explicitly framed as data, not new instructions.

The bridge preserves JSON number precision in arguments, request identities and
structured results. Retired turns cannot borrow a successor's admission window.
Terminal settlement cancels and drains the turn's injected tool callbacks before
publishing completion; bridge Close seals admission and joins HTTP handlers after
cancellation. Native JSONL writes observe request cancellation even when the
process stops reading; an incomplete write retires that uncertain channel.
Native pipe deadlines preserve fully written frames when cancellation races with
the write returning, so a response-wait cancellation does not kill the session.
Prepared launch resources are disposed even when cancellation prevents process
startup, so isolated configuration does not outlive a rejected launch.

Thread Read uses a separate ephemeral native fork when source history is
available. Missing history or a failed fork read uses a snapshot fallback in an
isolated read-only session and temporary workspace.
Each temporary session is registered with the Handle and releases its own exact
registration on return, even when a fallback replaces the current session.
Handle Close cancels and joins in-flight reads before returning. Read answers
are not projected into the source session; their native processes, temporary
workspace and one-shot configuration homes are drained on successful cleanup.
[adapter_read_test.go](adapter_read_test.go) exercises the real Open/Read/Close
path against external JSONL peers, including repeated reads, fork/fallback
success, launch/turn failure, cancellation and concurrent/repeated Close. It
checks ownership release, process exit, temporary-file cleanup and source-state
preservation without an installed Codex or model account.

Resume supplies tool definitions again while preserving native history in the same home. Tool schema changes do not themselves discard compacted context. Ordinary/extend modes share a home; exclusive mode uses isolated configuration. User-global Codex configuration is not rewritten.

Exclusive sessions do not copy `auth.json` or own refresh tokens.
[isolated_auth.go](isolated_auth.go) reads the source native account through
`getAuthStatus` in a fresh source app-server, preserving native file/keychain
selection. ChatGPT access credentials use `chatgptAuthTokens`; API keys use native
API-key login. The isolated server forces ephemeral credential storage. Reopening
a retained home removes any obsolete credential snapshot without removing history.
Native forced-login/workspace settings and the ChatGPT backend URL remain part
of the isolated configuration.

On `account/chatgptAuthTokens/refresh`, source reads and refreshes serialize per
canonical native home within this Runtime. A new source process observes external
rotation or login changes; an already replaced token is reused without another
refresh. Only a still-current rejected token triggers native refresh. Missing,
malformed, unchanged rejected tokens and account or user changes fail; the adapter
never replays user input. Native Codex owns coordination with other native clients;
this Runtime gate does not lock other apps or Runtime processes. Auth callbacks
have a nine-second deadline, run separately from session notifications, and are
cancelled and joined when their isolated owner closes. Credentials remain in
memory and are never projected or logged.

Isolated configuration preserves native `features.respect_system_proxy` and
`features.system_proxy_fallback` boolean settings, including explicit false.
Missing settings retain Codex defaults. Other native feature flags are not
copied into the isolated home; exclusive tool restrictions remain authoritative.

[interactions.go](interactions.go) owns approvals and forms. Automatic Computer Use grants require recognized server/app metadata, an empty confirmation schema and offered session scope. Grants are limited to the live native session and app, clear on policy/process retirement, and do not create an always-allow rule. Unrelated input and native script review retain their own rules.

Native nonblocking questions remain visible without pausing the execution.
Assistant and reasoning text remove NUL before entering durable projections,
whose text contract forbids NUL, so one native text fragment cannot prevent final
settlement. Streaming assistant text is retained only in the bounded projection,
without an unused unbounded native copy.

[connection_recovery.go](connection_recovery.go) begins recovery only for retryable native errors. Five consecutive retries or 60 seconds without execution progress retires the owner. Real assistant/reasoning/tool/actionable progress resets the window; heartbeats or accepted follow-ups do not. Healthy long tasks have no inherited recovery deadline. Already dispatched input is never automatically replayed.

Terminal publication completes before another input reuses a reservation. When `turn/steer` returns exactly `-32600 / no active turn to steer`, RPC rejection can arrive before queued terminal notifications. The adapter waits on that captured turn's completion within the request deadline, then checks durable settlement before Core reserves a successor. It does not reissue steering to poll for completion. An undispatched ended reservation may be replaced through Core admission once; a rejected dispatched steer remains a failed audited attempt without changing the original execution's outcome. [background.go](background.go) reconciles turn-scoped activities and native background terminals. Interrupt waits for authoritative cleanup; failed/unknown terminal listing cannot be treated as empty.

A positively unadmitted follow-up removes only its captured message ID and its
user-message timeline references from the old execution, in the same commit as
the audit error. Equal text in other messages is unaffected. This also applies
when an exact native rejection is known but waiting for settlement times out;
that timeout still does not authorize a successor. Generic transport failures
retain their input because native acceptance is unknown. Core can reserve a
successor only after the existing durable-settlement gate and successful commit.
No delivery status is added to the native text/time message UI. See the
[identity correction record](../../../../design/steer-message-identity.md).

Text and reasoning deltas commit in 50 ms batches, flushing earlier at 1,024
events or 256 KiB. The first native reasoning status publishes immediately; repeated
identical analysis statuses do not flush each chunk. Other native boundaries,
including completion and cancellation, flush pending deltas before settlement.
The native adapter retains reasoning prefixes for completion reconciliation;
assistant text comes from streamed deltas and authoritative completed items
without a second unused accumulated copy.

File-change activities retain their unique native paths through completion and
renderer projection. The native execution summary counts distinct paths across
activities, so one patch touching several files reports its actual file scope.
A source without path facts uses a neutral changed-files label.

## Voice

[voice.go](voice.go) uses the unmodified app-server's V3 WebRTC/sideband protocol. Voice is not gated by CLI version or user-agent format: all three paths share the real `thread/realtime/start` request and subsequent protocol events to determine compatibility. There is no separate capability probe before microphone permission and SDP creation. Unsupported startup methods or V3 parameters (`-32601` / `-32602`) add a Chinese compatibility diagnostic while retaining the native RPC error, and end that media attempt without automatic retries or protocol downgrade. Native provider/login checks still apply.

A Codex Moku attaches directly to its prepared native session. A Codex thread discussion attaches to a separate read-only ephemeral fork. Direct preparation failure is surfaced, never silently routed through another account. Non-Codex targets use a private relay fixed to `gpt-6-luna`, checked against catalog, prepared thread and model events; there is no fallback model. The relay's only application tool is `forward_to_target`, which forwards the captured handoff rather than model-written replacement text. It has no project execution tools or source-history writer.

`clientManagedHandoffs` disables automatic result speech, not native execution. Native starts are adopted through Core admission, with tools gated on that boundary; upstream inference may already have begun. Results use stock `thread/realtime/appendSpeech`, which may paraphrase. The relay's own final answer is not used as a target answer.

Owner, execution, delivery and accepted-input generation fence speech. Duplicate handoffs and unmappable native input fail rather than inventing ownership. VAD or caption fragments do not accept a task. A current append failure is a nonterminal `speech-error`; obsolete failures cannot terminate a newer media generation. Uncertain speech delivery is not retried. Closing Moku media does not cancel already admitted task work; closing a private discussion disposes its work.

The [native Swift media client](../../../../app/macos/Sources/Voice/README.md) owns microphone, WebRTC and playback. [voice_feedback_test.go](voice_feedback_test.go) covers exact ASR/handoff/answer identity association; source text/generation must match uniquely, and a late final may complete only the candidate captured at handoff.

Pending Moku settings reject a native start before Core/tool admission. Only
this exact rejection can return the captured handoff for configuration recovery,
after the old process, tool bridge and in-flight notification have drained.
Other native failures remain uncertain. Complete model/instruction/tool changes
rebuild the native owner; reconnect does not pretend an existing realtime peer
supports an in-place rebind or prewarm the configuration being retired.

Moku-native speech can request a playback-readiness receipt. The adapter emits
`speech-ready` with the exact delivery/generation and waits up to ten seconds
before appending audio. Input-generation changes, cancellation and Stop release
the wait; repeated acknowledgements cannot append speech again. Relay and
private-discussion speech do not require this receipt.

Stopping media also cancels native admission still waiting for the settings
gate. An exact cancellation before projection retires the unadmitted native
turn through its interrupt acknowledgement, allowing normal realtime shutdown
to finish. Failed interrupt acknowledgement remains a visible cleanup failure;
generic, joined and possibly projected errors keep the ordinary fault path.

When that fault has retired the app-server, stopping media joins the native
process and tool bridge instead of requiring an RPC acknowledgement from the
closed channel. A typed transport failure identifies this case without treating
native RPC rejections or cancellation failures as successful cleanup. Process or
bridge drain failures remain errors. Prewarming checks the native owner's and
transport's existing retirement state and must itself win retirement of a live
owner before launching its replacement; joining a concurrent fault's cleanup
grants no replacement authority. This cleanup does not recover input, and the
original voice error event is retained.

Verification: [Codex runner](../../../../tools/verification/codex/README.md), `./scripts/go.sh test -race ./internal/plugins/harness/codex`, and the runtime/Moku replays. Protocol fixtures establish adapter behavior, not live account entitlement or audible playback.

## Initial response cards

The overview renderer supplies `initialResponseScope`, computed from the full
execution index and fork/history provenance before compaction. This fixed-size
fact is projection-only and never enters canonical session state. Native cards
use it for ordinary threads with zero or one execution; eligible agent content
retains its existing precedence. Other scopes omit the field.

The adapter replay also checks this boundary with shared production-renderer
fixtures in `tools/verification/firstresponse`. The native cross-language replay
is `python3 tools/verification/reading-presentation/run.py --initial-response`.

Settings directory, execution-default capture and auto-review capability reads
share one bounded catalog acquisition. Configuration, model list, Computer Use
and version facts are read concurrently from the same native process; default
capture no longer starts a second server. Auto-review reuses that configuration,
while live admission still checks the owning execution session. The launch's
already observed version is reused. Standalone successful version probes cache
by binary metadata/environment for five minutes and drain their own subprocess.

Catalog keys include cwd, executable selection, native environment and selected
config/auth file metadata. Routing additionally observes ancestor `config.toml`
files and explicit file references, not the native home's desktop state, caches
or worktrees. The shared login keychain file is not a Codex account identity;
unobservable keychain/remote account changes still rely on TTL, refresh and live
native authentication. A probe validates files against its captured executable
and environment; a concurrent login-shell refresh cannot invalidate that launch
merely by changing a session variable. Later acquisitions capture the new launch
environment and cannot reuse the old key.

A source change during discovery rejects publication. After the native process
drains, one fresh acquisition can recover credential initialization or a settled
configuration edit. Persistent changes fail after two attempts. Cancellation,
native read errors and cleanup failures do not authorize a replacement. No task
input is dispatched or replayed by catalog recovery.
Per-key refresh, independent cancellation, success-only five-minute reuse and
shutdown joining use [discovery](../../../platform/discovery/README.md). A failed
partial observation can describe its own failure but earns no successful TTL.
No credential snapshot is written to disk.

`./scripts/go.sh run ./tools/verification/codex -settings-performance` measures
mixed catalog/defaults reads. See [measurement scope](../../../../tools/verification/settings-performance/README.md).

Turn-scoped reader projections omit plan steps, explanations and timeline markers
before encoding and copying them to native clients. Canonical, overview, context
and full/execution projections retain those facts. Empty required plan arrays
preserve native decoding, and surviving timeline identities/order remain intact.
Deferred turn projections retain failed activity labels and details so errors
remain readable without loading or showing ordinary execution work. Failed tools
retain bounded completion diagnostics as well as command output. Diagnostics
take priority over large partial results within the retained bound. Completion
classification uses explicit native failure/cancellation, command exit codes and
tool-result `isError`; output text is never a status heuristic. A completion-only
frame carries enough activity identity to survive recovery without a start frame,
and a repeated start cannot erase a completed diagnostic. Existing stored
diagnostics already discarded by earlier versions cannot be reconstructed by the
reader; no history rewrite is performed.
The [reader projection replay](../../../../tools/verification/thread-detail-performance/README.md)
checks active, terminal and inherited turns without a native CLI or model call.

Lightweight deferred execution projections record meaningful activity `detail` by
native activity ID before stripping its body. The native Agent reader uses that
presence to distinguish completed no-output Hook bookkeeping from actual output;
canonical activity state and full execution content remain unchanged.

Matching id/status/name-only successful Hook JSON is lifecycle metadata, not
summary output; unknown fields remain conservative and full detail is retained.

Lazy Moku delivery uses `SendRequest.FollowUpOnly`. The adapter checks its own
active execution before retaining input and returns `ErrFollowUpUnavailable`
when the target is gone; it must not create a replacement execution for this
request. Ordinary sends retain their existing admission behavior.

`search.go` supplies completed-execution public passages with their execution IDs
for Moku grep. Existing index text joins the same passages, preserving its prior
exclusions. This extracts only retained Mokusei state, not complete native history;
see the [search contract](../../../services/threadsearch/README.md#moku-deterministic-grep).

Execution reasoning summaries persist `reasoningTokensByGeneration` on newly
admitted turns. Final `rawResponse/completed` usage replaces the count for its
stable response ID; duplicate observations cannot add another call. Missing or
invalid reasoning counts remain null, suppressing the summary total. The map is
retained in full, compact, historical and fork projections. `usage` retains its
native last-call meaning for existing consumers; neither its snapshots nor the
session-wide token total is summed. Turns admitted without the map have no
certified execution total and do not acquire a misleading suffix-only total
when resumed. Unfinished calls contribute only after reporting usage.
Asynchronous telemetry receives an owned event snapshot before the notification
receiver adds projection metadata, so ledger reads cannot race those writes.

Compact renderer directories retain up to 600 characters of `answer` for each
execution, including historical executions, so Report can display a bounded
assistant excerpt without acquiring full conversation content. Native
`executionPreview` pairs that exact execution's text with its own timestamps.
Prompt, reasoning and tool-payload admission is unchanged; no latest-execution
fallback is used for historical references.


Only native voice handoff admission uses `plugin.WithVoiceAdmission` with its exact
VoiceSession ID. Background terminal follow-ups use their original, unmarked Core
admission path. This allows Moku to reject a retired microphone owner without
blocking non-voice continuation. Thread voice calling is disabled by Runtime;
Overview global Moku still uses the native/relay media implementation described here.

Moku requires the full nonempty native model inventory before task admission.
Unknown thinking capabilities remain named in that inventory but cannot authorize
creation. Moku routing returns complete same-configuration cached directories
immediately, even after expiry or during refresh. Expired entries start bounded
background refreshes; failures/empty replacements retain the last complete
snapshot, with a 30-second warm-retry cooldown. Only a cache miss waits and blocks
on failure. Configuration identities fence publication and native admission;
execution/default resolution retains strict reads. Caches are Harness-owned,
memory-only and drained on Close, not persisted across application restarts.
The native reader includes hidden models, follows every `model/list` cursor, and
rejects malformed pages, duplicate identities and cursor cycles instead of
reporting a truncated directory as complete.

App-server spawn fixes the originator to the same `mokusei_desktop` client used
by initialize, including pre-initialize model discovery. Full pagination still
cannot attest whether native discovery silently fell back to bundled metadata;
see [evidence limits](../../../services/moku/catalog-evidence.md).

Moku routing accepts a successful nonempty native inventory, including native
cache/bundled fallback, without requiring static configuration, a pinned version,
strict-config startup or source-completion attestation. Source completeness stays
false in the schema; it does not reject an otherwise usable directory. Config and
auto-review enrichment failures are not model-directory failures. Creation and
ordinary defaults still validate their required settings.

ChatGPT cold/background probes have a best-effort three-second window to observe
native cache refresh and enumerate again. Timeout, cache-stamp read failure or a
failed second enumeration retains the first complete result. A matching warm
snapshot returns immediately and failed refreshes preserve it with a failure
note. First-page/later-page errors and empty initial inventories still reject a
cold acquisition. No static candidate or failed page prefix is synthesized.
See the [T3 source comparison and differences](t3-discovery.md) and
[current admission contract](../../../services/moku/catalog-evidence.md).
