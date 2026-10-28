# Codex Harness

[adapter.go](adapter.go) constructs the adapter; [executable.go](executable.go) discovers the user's installed Codex. [native.go](native.go) and [transport.go](transport.go) own app-server sessions, JSON-RPC and process cleanup. Codex owns model/account configuration and native history; Mokusei owns admission, durable public state and injected application capabilities.

## Settings, tools and execution

[settings.go](settings.go) requires explicit model, thinking and service-tier choices for ordinary task creation. `default` is the standard tier; other tiers must be advertised by the selected model. A missing/null/boolean tier is not inheritance. Native replies confirm the effective tier; explicit null means known standard, while absence is unreported. [presentation.go](presentation.go) uses reported execution facts for Fast status before falling back to requested settings.

[tools.go](tools.go) exposes injected tools through an authenticated local MCP bridge with a schema budget sized for the supplied definitions. Tool execution is bound to the admitted native thread/turn and cancellation context. Exclusive injection disables unrelated native/MCP tools. Stock resource-helper names do not confer authority: the bridge returns no resources/templates and has no resource-read implementation.

The bridge preserves JSON number precision in arguments, request identities and
structured results. Retired turns cannot borrow a successor's admission window.
Terminal settlement cancels and drains the turn's injected tool callbacks before
publishing completion; bridge Close seals admission and joins HTTP handlers after
cancellation. Native JSONL writes observe request cancellation even when the
process stops reading; an incomplete write retires that uncertain channel.
Native pipe deadlines preserve fully written frames when cancellation races with
the write returning, so a response-wait cancellation does not kill the session.
Prepared launch resources are disposed even when cancellation prevents process
startup, so copied isolated credentials do not outlive a rejected launch.

Resume supplies tool definitions again while preserving native history in the same home. Tool schema changes do not themselves discard compacted context. Ordinary/extend modes share a home; exclusive mode uses isolated configuration. User-global Codex configuration is not rewritten.

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
config/auth file metadata; a source change during discovery rejects publication.
Per-key refresh, independent cancellation, success-only five-minute reuse and
shutdown joining use [discovery](../../../platform/discovery/README.md). A failed
partial observation can describe its own failure but earns no successful TTL.
No credential snapshot is written to disk.

`./scripts/go.sh run ./tools/verification/codex -settings-performance` measures
mixed catalog/defaults reads. See [measurement scope](../../../../tools/verification/settings-performance/README.md).
