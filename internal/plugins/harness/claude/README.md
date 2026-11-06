# Claude Harness

Exact execution forks accept `{executionId}` beside the existing checkpoint
selector (mutually exclusive). The adapter retains the public prefix and
resolves the final assistant's API message ID to its native transcript UUID in
that source session, then uses the existing `--resume-session-at` fork path.
Unavailable native history/checkpoints fail without sending. See
[Report continuation](../../../../design/report-execution-continuation.md).

Shared [private tool diagnostics](../../../platform/diagnostics/README.md) identify
`CallID` as an MCP request ID, not a Claude tool-use ID, and expose the bridge's
existing 256-byte identifier truncation without changing receipt identities.

[harness.go](harness.go), [session.go](session.go) and [transport.go](transport.go) adapt the installed Claude CLI's stream-json protocol. Claude owns native account/model configuration and conversation history. Mokusei supplies admitted inputs, public observations and scoped tool injection.

[settings.go](settings.go) owns model, thinking/effort and permission-mode validation. An explicit thread effort takes precedence over inherited environment configuration; unsupported choices are rejected rather than silently omitted or replaced. Empty profiles are accepted for initialization, while execution still requires a resolved valid configuration.

[environment.go](environment.go) builds the selected execution environment. The native tool bridge preserves the supplied schemas and validates business arguments at the target boundary. Exclusive sessions restrict ambient tools/configuration. Permission guidance is supplied by the Harness that implements it, rather than asserted by generic Core prompts.

The MCP bridge associates cancellation and duplicate requests with decoded JSON
string identifiers, preserving the native identifier in responses. Closing the
bridge stops admission, cancels active calls and waits for their resource cleanup
before returning. Tool implementations must observe their cancellation context.
Native request cancellation and deadlines cover both waiting to write and blocked
stdin writes. Cancelling a queued frame leaves the active write intact; cancelling
an incomplete frame closes its pipe so later frames cannot reuse partial JSON.
Cancellation racing with a fully written frame preserves the pipe for later
commands; native pipes use write deadlines to distinguish those outcomes.

Private [discussions](session.go) fork native source history into an isolated continuous session with only project read/list tools. The original task's execution and approval authority are not used. Non-Codex discussion media is routed through the [thread-voice service](../../../services/threadvoice/README.md).

The shared [generated metadata policy](../../../core/plugin/README.md#generated-metadata) supplies durable title/emoji updates independently of execution state.

Verification: [Claude runner](../../../../tools/verification/claude/README.md) and `./scripts/go.sh test -race ./internal/plugins/harness/claude`. The runner uses an external stream-json fixture and real Go MCP subprocess, including conditional tool-schema acceptance/rejection checks.
Package fixtures also exercise escaped MCP identifiers, concurrent bridge close
and delayed tool cancellation cleanup without launching an installed CLI.

Moku target schemas use the configured executable and native catalog independently
of the selected default model. Catalog failures and empty catalogs block task preparation;
models with unknown thinking controls remain identified in the schema. Catalog snapshots remain subject to native admission and cache TTL.

## Native configuration controls

The [native Claude settings view](../../../../app/macos/Sources/Plugins/Harnesses/Claude/ClaudeSettings.swift)
reuses the settings page's group, defaults toggle, select, input and notice
components. Model, reasoning and permission choices use the same select surface.
An explicit custom-model choice reveals the shared text input; opening that
editor does not change the configured model. Saved models absent from the native
catalog remain visible and editable. Menu action tokens are separate from native
model identifiers, and catalog selections retain the exact identifier.

Thread thinking choices and execution-profile effort remain distinct contracts.
Changing a model still clears incompatible dependent choices, incomplete execution
profiles stay local until complete, fixed-capability models need no effort, and
unknown capabilities are not guessed. Permission values and inherited/default
configuration semantics stay owned by the Claude adapter.

Run `xcrun swift test --package-path app/macos --filter ClaudeSettingsControlReplayTests`
in a graphical macOS session for the mounted production settings controls with a
fixture catalog. It covers catalog/custom selection, invalid input, incomplete
snapshots, fixed effort, all permission modes, unavailable saved models and native
default clearing without launching a CLI. Set
`MOKUSEI_CLAUDE_SETTINGS_ARTIFACTS=/private/tmp/claude-settings-artifacts` to retain
wide dark and compact light captures. The protocol replay above covers the Go
adapter; neither fixture establishes compatibility with an installed CLI release.

## Initial response cards

The overview renderer supplies `initialResponseScope`, computed from the full
execution index and fork/history provenance before compaction. This fixed-size
fact is projection-only and never enters canonical session state. Native cards
use it for ordinary threads with zero or one execution; eligible agent content
retains its existing precedence. Other scopes omit the field.

The adapter replay also checks this boundary with shared production-renderer
fixtures in `tools/verification/firstresponse`. The native cross-language replay
is `python3 tools/verification/reading-presentation/run.py --initial-response`.

Settings catalog reads share a bounded 45-second native initialization per
executable/cwd/environment/configuration generation. Successful catalogs retain
five-minute freshness; cancellation belongs to each reader, and the final reader
cancels an unfinished process. Closing the Harness joins these probes. A refresh
supersedes only its own key and failed/empty catalogs cannot replace a success.
Native config/credential file metadata and the environment partition the cache;
no credential or account snapshot is persisted. Execution capture continues to
confirm effective settings through its own native session.

`./scripts/go.sh run ./tools/verification/claude -settings-performance` measures
cold and warm concurrent production reads with an isolated stream-json fixture.
See [measurement scope](../../../../tools/verification/settings-performance/README.md).

Turn-scoped reader projections omit plan steps, explanations and timeline markers,
including inherited history, before native transport encoding. Canonical state,
overview, context and full/execution projections retain those facts. Required
empty plan arrays keep the native state contract valid. The
deferred turn projection retains failed activity labels and details, including
inherited history, so error visibility does not require loading ordinary work. The
[reader projection replay](../../../../tools/verification/thread-detail-performance/README.md)
checks this boundary for active and terminal turns and inherited history.

Lightweight deferred execution projections record nonempty activity `detail` by
native activity ID before stripping its body. The native Agent reader uses that
presence to distinguish completed no-output Hook bookkeeping from actual output;
canonical activity state and full execution content remain unchanged.

Inherited activities have no embedded activity id; deferred output presence uses
the enclosing timeline item id so unrelated empty Hooks cannot share a marker.

This Harness does not advertise `ThreadCapabilities.FollowUpOnly`: its native
input protocol has no proven atomic active-only condition. Lazy Moku notices
therefore wait for the next independently triggered input and travel with its
system context, even while this Harness is running. An explicit follow-up-only
Send returns `ErrFollowUpUnavailable` before retaining or dispatching anything;
ordinary inputs keep their existing behavior.

`search.go` supplies completed-execution public passages with their execution IDs
for Moku grep. Existing index text joins the same passages, preserving its prior
exclusions. This extracts only retained Mokusei state, not complete native history;
see the [search contract](../../../services/threadsearch/README.md#moku-deterministic-grep).

Reasoning usage totals are recomputed from the parser's replacement map keyed by
native message ID, not added from cumulative turn snapshots. A reported usage
sample without reasoning usage suppresses the reasoning total; absent/null
thinking-token metrics do not become zero. The reader uses the persisted turn
aggregate for live and historical execution summaries. In-flight unreported
usage is not estimated.

Compact renderer directories retain up to 600 characters of `text` for each
execution, including historical executions, so Report can display a bounded
assistant excerpt without acquiring full conversation content. Native
`executionPreview` pairs that exact execution's text with its own timestamps.
Prompt, reasoning and tool-payload admission is unchanged; no latest-execution
fallback is used for historical references.

Discovery rejects results when tracked native configuration files change during
the probe, so an in-flight read cannot publish a known-obsolete snapshot.

Moku requires the full nonempty native model inventory before task admission.
Unknown thinking capabilities remain named in that inventory but cannot authorize
creation. Failed or empty reads block preparation, including after cache expiry.
