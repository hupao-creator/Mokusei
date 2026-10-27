# OpenCode integration replay

Run from the repository root:

```sh
go run ./tools/verification/opencode
```

This builds a temporary stdlib-only fake OpenCode executable and runs credential,
settings/configuration, Console OAuth telemetry, stalled-refresh lifecycle and frozen renderer parity cases with the Go race detector.
No installed Harness or account is needed. The timeout case intentionally takes
about 20 seconds to prove that a stalled native refresh is terminated before the
credential database queue is released.

To include the actual external OpenCode 2.0.25+ process:

```sh
go run ./tools/verification/opencode -native-cli "$(command -v opencode)"
```

The explicit native path enables three additional cases. Each creates temporary
HOME/XDG/database directories, supplies a synthetic key, and sends every inference
request to an `httptest` loopback server. These are integration replays, not unit
tests or account-based model probes. The user's existing native profile is not used.

| Case | Evidence |
| --- | --- |
| `credentials` | Single native server, native DB/cache, exclusive configuration, ownership, nonblocking advisory reads during gated startup, stable cold/warm deferred Target with exact on-demand options, HTTP/SSE and termination |
| `settings` | JSONC/YAML discovery and ordered permissions, credential-free catalog, concurrent reader cancellation, native default agent without `default_agent` (a non-`build` first agent), exact thinking selection/update/snapshot, live variant change rejection, process cleanup |
| `timeout` | Cancelled startup joins its single server before returning |
| `renderer` | 25 fixed projections from the pre-migration renderer across overview/thread/turn/execution/history scopes, including deferred content, tool display, usage and Unicode boundaries |
| `telemetry` | Native Go OAuth account resolution and Console meter windows, official Go/generic routes, stable workspace window IDs and secret-free Moku output; synthetic RPC/HTTP only |
| `native` | Real native plugin loading and configuration acknowledgement, isolated native model configuration, strict response schema request overlay, SSE/durable export, default-agent execution snapshot/save without `default_agent`, credential-free model/thinking catalog, cross-provider model/variant switch preserving native session/history and per-execution attribution, native synthetic OAuth refresh and persistence across restart |
| `thread` | Shared native database: per-input durable admission, follow-up, native fork read/cache affinity/provider prefix, concurrent source continuation and cancellation cleanup, restored read, fresh ordinary fork import, JSON completion, exclusive Go tool execution, manual native shell permission, typed conditional forms and invalid-answer rejection, steering, concurrent cancellation and forced SSE gap/durable reconciliation |
| `foreground` | Native reasoning streams, 32,768-point windows, UTF-16 offsets, semantic sequence transitions, no duplicate ended fragments and durable foreground state |

Use `-case thread` (with `-native-cli`) to run one case, `-race=false` to disable the
race detector, `-go /path/to/go` to select the toolchain, or `-root /path/to/repo` when
invoking from elsewhere. The default toolchain is the one running this command.

The fixtures contain synthetic credentials only. They do not verify production
OAuth accounts, paid upstream models, remote billing responses, or the Swift UI.

The compressed renderer fixture records the previous implementation’s public output,
not runtime migration data. Replaying it requires only Go; no Node generator or
JavaScript toolchain is retained.

Runtime shutdown also drains the owned native process group after its leader exits
before removing plugin/temporary cache directories. The runtime-helpers replay
includes a descendant that closes inherited pipes and outlives the leader; native
OpenCode cases exercise the same shutdown path.

Late temporary cache writes can still race directory removal. Environment cleanup
retries only `ENOTEMPTY` within a two-second window; other errors and exhausted
retries retain their cause and the existing shutdown-failure behavior. This is
not a guarantee that native descendants in separate process groups have exited.
Run `./scripts/go.sh test -race ./internal/plugins/harness/opencode` for deterministic
transient/persistent cleanup failures and real temporary-directory removal,
including preservation of external persistent data and symlink targets.
The same local fixtures cover callback draining, atomic bridge configuration,
configuration HOME selection, version-wrapper descendants, SSE shutdown,
completion cleanup errors and rejected steering/interruptible interaction replies.
The native `thread` case checks both ordinary injected tool names and `__proto__`
through actual plugin loading, provider advertisement, execution and projection.

The `thread` case also verifies installed-native private voice discussion through
the production relay (synthetic media), continuous history, Core reads, malicious
write rejection, concurrency, native failure reason propagation, lazy forks, and
cleanup that preserves completed or actively running source sessions.

Before asserting byte-for-byte source immutability during a completed-session
read, the replay waits for that execution's input and successful idle boundary
in the native transcript. Public SSE completion can precede this asynchronous
export; the replay must not mistake its later reconciliation for a read mutation.
