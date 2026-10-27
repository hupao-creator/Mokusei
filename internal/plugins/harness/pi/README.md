# Pi adapter

`pi.New(plugin.HostContext)` is the Go implementation of the Pi Agent Harness.
It uses the external `pi --mode rpc` process and requires a stable Pi release
at least 0.83.0. Mokusei does not launch a Node renderer, bridge server, or
separate JavaScript build for this adapter.

The adapter implements `plugin.Harness`, `Forker`, `PromptCompleter`,
`AvailabilityProbe`, `WorkspaceDiscoverer`, `ModelCatalogSource`,
and `DiscussionPreparer`. Installation of the external
Pi CLI belongs to the application's Harness installation flow.

## Native ownership

- RPC framing and native event decoding remain ordered, with an 8 MiB record
  bound, correlated command responses, bounded startup and request deadlines,
  cancellation, and process-group cleanup.
- Cancelling a command still waiting to write removes only that command. A
  cancelled partial write closes the connection to prevent a truncated JSON
  frame from corrupting later commands; cancelling only the response wait keeps
  an already written command's native execution intact. The write queue is
  cancellable without leaving a background waiter. Native pipe deadlines preserve
  complete frames even when cancellation races with the write returning.
- Disposal first closes stdin so Pi can finish asynchronous native shutdown
  hooks. Only a child that fails to exit is escalated to SIGTERM, then SIGKILL,
  with one-second bounds at each stage. Sending EOF and SIGTERM together can
  make Pi force an early exit before its cleanup releases native resources.
- A prompt response accepts input; only `agent_settled` completes its run.
  `agent_end` can precede queued work. A consumed input fails its submission;
  a consumed steering input leaves the admitted native run intact.
- Thread inputs and execution state commit before `SendRequest.Admitted` and
  before native dispatch. A rejected admission never dispatches native work.
- Streaming state commits are coalesced at 50 ms. Native boundaries commit
  immediately. Reopening a persisted live execution interrupts it without
  starting the CLI; the next send can resume its native session.
- `message_end.usage` describes one model call, not an execution/session total.
  Durable messages retain those native counts; compact renderer scopes carry
  derived `executionUsage` totals keyed by execution ID without rewriting the
  last message's usage. The native card, execution-usage API and turn footer
  display reported input + output + cache read/write across that execution.
  Streaming calls contribute nothing until `message_end`; failed calls with
  zero or missing usage do not erase prior calls. No reported usage stays
  unknown, distinct from an explicitly reported zero. Reopen retains old
  execution totals; a resumed send starts its own execution total. Reasoning
  is a subset of output and is never added to the token total.
- Native state, model selection, thinking validation,
  prompt construction, interaction mapping, tool admission, state projection,
  and settings validation execute in Go. Pi owns its account and model configuration.
- Forks clone a frozen native JSONL snapshot into an independent session. Reads
  use a temporary native fork and verify a fail-closed tool guard before asking
  a question. Injected Threads cannot be used as read sources.

## Two static JavaScript resources

`resources/host-extension.mjs` is loaded only by the external Pi extension host.
Go writes its temporary JSON configuration and supplies a private inherited
socket at file descriptor 3. The resource registers tools and forwards calls
and cancellation; Go checks the active execution, exclusive tool set, duplicate
request IDs, native call IDs, and returned JSON. The resource applies the
system-prompt string chosen by Go at Pi's native hook boundary.

Bridge shutdown stops new calls and cancels existing callbacks; Close waits for
their cleanup before returning. Tool implementations must observe cancellation.
A callback panic becomes a tool error without exposing its panic payload or
terminating the runtime. Local package fixtures cover cleanup barriers, panic
recovery and cancellation before native command dispatch.

`resources/read-guard.mjs` blocks all native tool calls during a history read.
Its command registration lets Go verify the exact guard file loaded. Both
resources are embedded by `go:embed`; neither requires Node or npm to build.

## Preserved native limits

Pi Threads do not accept slash commands or historical fork selectors. Ordinary
Threads require exact provider/model settings and an explicit thinking choice
whose actual native application is checked before execution. Host tools support
exclusive injection only. Native Responses thinking uses only explicit supported `thinkingLevelMap` values;
missing mappings, disabled levels and request overrides remain unavailable.
Unsupported or unconfirmed thinking dialects stay
unavailable instead of silently selecting a different setting.

Voice discussions use a private native JSONL fork with the exclusive Host extension
and Core project read tools. Persisted source history and execution remain owned
by the source Thread. See [discussion semantics](../../../services/threadvoice/README.md).

## Initial response cards

The overview renderer supplies `initialResponseScope`, computed from the full
execution index and fork/history provenance before compaction. This fixed-size
fact is projection-only and never enters canonical session state. Native cards
use it for ordinary threads with zero or one execution; eligible agent content
retains its existing precedence. Other scopes omit the field.

The adapter replay also checks this boundary with shared production-renderer
fixtures in `tools/verification/firstresponse`. The native cross-language replay
is `python3 tools/verification/reading-presentation/run.py --initial-response`.

Settings state and full-catalog readers share a native observation flight. A full
reader upgrades an in-flight state request before catalog acquisition; a reader
arriving after that decision retries after the state-only process drains. Model
and thinking-level RPCs run concurrently. State-only results cannot overwrite a
successful full catalog. Refresh is scoped to the native source key, and an
abandoned or superseded probe cannot publish. Keys include settings/cwd, native
environment, executable and config/auth/model file metadata. Successful full
observations retain five-minute freshness; incomplete observations keep the
existing short retry interval. Native execution confirmation remains unchanged.

The deterministic replay includes mixed state/catalog sharing. Add
`-settings-performance` for isolated cold/warm measurements; see the
[measurement scope](../../../../tools/verification/settings-performance/README.md).
Closing the adapter cancels and joins all discovery flights, including those
superseded by refresh. A failed native process cleanup remains observable and
fences replacement discovery until a new adapter is constructed.
