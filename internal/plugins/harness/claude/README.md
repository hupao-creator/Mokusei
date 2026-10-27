# Claude Harness

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
