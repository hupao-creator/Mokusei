# OpenCode integration replay

Run from the repository root:

```sh
go run ./tools/verification/opencode
```

This builds a temporary stdlib-only fake OpenCode executable and runs credential,
settings/configuration, Console OAuth telemetry, stalled-refresh lifecycle and fixed renderer projection cases with the Go race detector.
No installed Harness or account is needed. The timeout case intentionally takes
about 20 seconds to prove that a stalled native refresh is terminated before the
credential database queue is released.

To include the actual external OpenCode 2.0.25+ process:

```sh
go run ./tools/verification/opencode -native-cli "$(command -v opencode)"
```

The explicit native path enables four additional cases. Each creates temporary
HOME/XDG/database directories, supplies a synthetic key, and sends every inference
request to an `httptest` loopback server. These are integration replays, not unit
tests or account-based model probes. The user's existing native profile is not used.

| Case | Evidence |
| --- | --- |
| `credentials` | Single native server, native DB/cache, exclusive configuration, ownership, nonblocking advisory reads during gated startup, cold/warm Target inventories and exact creation options with source completeness kept unknown, empty/duplicate catalog rejection, HTTP/SSE and termination, startup waiting for OpenCode 2.3 asynchronous plugin activation before its first RPC |
| `settings` | JSONC/YAML discovery and ordered permissions, credential-free catalog, concurrent reader cancellation, fixed build selection despite a native plan default and saved plan settings, exact thinking selection/update/snapshot, live variant change rejection, process cleanup |
| `timeout` | Cancelled startup joins its single server before returning; a server exiting after publishing its address fails startup immediately instead of spending the plugin-activation budget |
| `renderer` | Five shared state inputs × overview/thread/turn/execution/history = 25 fixed projections, including compact execution summaries, retained assistant replies, deferred privacy/presence, tool display, usage and Unicode boundaries |
| `telemetry` | Native Go OAuth account resolution and Console meter windows, official Go/generic routes, stable workspace window IDs and secret-free Moku output; synthetic RPC/HTTP only |
| `native` | Real native plugin loading against the installed OpenCode CLI (probed version printed in output; the 2.3 asynchronous activation window itself is modeled by the fixture in `credentials`), isolated native model configuration, strict response schema request overlay, SSE/durable export, build execution snapshot/save without `default_agent`, credential-free model/thinking catalog, cross-provider model/variant switch preserving native session/history and per-execution attribution, native synthetic OAuth refresh and persistence across restart |
| `thread` | Shared native database: per-input durable admission, follow-up, native fork read/cache affinity/provider prefix, concurrent source continuation and cancellation cleanup, restored read, fresh ordinary fork import, JSON completion, exclusive Go tool execution, manual native shell permission, typed conditional forms and invalid-answer rejection, idle SSE automatic admission, literal option-prefix text, radix-number conversion, hidden defaults and optional/conditional omission, steering, concurrent cancellation and forced SSE gap/durable reconciliation |
| `foreground` | Native reasoning streams, 32,768-point windows, UTF-16 offsets, semantic sequence transitions, no duplicate ended fragments and durable foreground state |

Use `-case thread` (with `-native-cli`) to run one case, `-race=false` to disable the
race detector, `-go /path/to/go` to select the toolchain, or `-root /path/to/repo` when
invoking from elsewhere. The default toolchain is the one running this command.

The credentials replay accepts successful native enumeration for routing while
requiring `source.complete=false`, its evidence basis and a matching configuration
identity in the schema. It checks exact supported model/thinking options and sends
empty and duplicate inventories through the real native discovery path to require
rejection without a published target. Run it with `-case credentials`; the
`settings` case separately verifies live model/variant admission.

The fixtures contain synthetic credentials only. They do not verify production
OAuth accounts, paid upstream models, remote billing responses, or the Swift UI.
The foreground provider waits for the production activity callback after each
live segment before sending the next, including the assistant transition before
the terminal marker. Native SSE may coalesce nearby
updates; a fixed delay cannot certify two observable stream windows. The replay
still requires both windows, the point limit, UTF-16 offset and exact sequence.

The compressed renderer fixture contains five shared persisted-state inputs, each
projected through overview, thread, turn, execution and history scopes: 25 fixed
projections, not 25 independent inputs. The states use persisted version 2.
Expectations follow the current contract: overview directories retain each
execution's bounded summary, deferred turns retain assistant text (including
child-session and inherited replies) while hiding child prompts, reasoning and
tool displays behind `nonempty` markers, assistant bodies exist once in ordered
parts, user input once in `text`, and tool payloads once in producer-rendered
display strings. A mismatch reports the first differing JSON path.

Inspect the fixture without a JavaScript toolchain:

```sh
gzip -dc tools/verification/opencode/cases/renderer/expected.json.gz |
  python3 -m json.tool > /tmp/opencode-renderer.json
```

Regenerate only the expectation side from the embedded states, then review the
decompressed semantic diff before replacing the fixture:

```sh
./scripts/go.sh run ./tools/verification/opencode/cases/renderer \
  -write /tmp/opencode-renderer-new.json.gz
gzip -dc /tmp/opencode-renderer-new.json.gz | python3 -m json.tool > /tmp/opencode-renderer-new.json
diff -u /tmp/opencode-renderer.json /tmp/opencode-renderer-new.json
```

`-write` never changes the input states. The replay's structured-display test uses
a hand-written raw state to assert JSON insertion order, while production
`State.Encode()` marshals Go maps with sorted keys; both orderings are asserted
separately (see `TestProjectionPreservesStructuredDisplayOrder` and
`TestProjectionKeepsOneVisibleToolBody`).

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

The `thread` case retains installed-native fork/read, cancellation and cleanup
that preserve completed or actively running source sessions.

Before asserting byte-for-byte source immutability during a completed-session
read, the replay waits for that execution's input and successful idle boundary
in the native transcript. Public SSE completion can precede this asynchronous
export; the replay must not mistake its later reconciliation for a read mutation.

The mounted Swift Harness regression launcher is
`python3 tools/verification/reading-presentation/run.py --harness-forms`.
It mounts the production Pi settings menu with colliding slash-containing model
identifiers and the production OpenCode Reader panel with public/native metadata.
Its fixture exporter uses the production native form event reducer and both
public and renderer projections, including public IDs containing escaped source
characters:

```sh
./scripts/go.sh run -race ./tools/verification/opencode/cases/renderer -forms-output /absolute/new/fixture.json
```

`MOKUSEI_HARNESS_FORM_FIXTURE` names that JSON file for
`NativeHarnessFormTests`. The suite covers native default adoption, optional
absence, hidden and conditional fields, public fallback, literal Go-produced
question/option IDs, submission and cancellation before a required answer.
Plain SwiftPM runs explicitly skip this suite without the fixture; use the
launcher for the mounted cross-language verification. The ordinary no-argument
renderer replay retains its existing parity and error cases.

The installed-native `thread` form replay includes an empty form title, emoji UTF-16 length, dotted email, nonfatal URI percent encoding (default and external URL), and expanded-year date-time defaults. It checks the final native answered values after production SSE admission and public preflight.

`-case forms -native-cli /absolute/path/to/opencode` runs a standalone native Form API/SSE contract matrix without prompts. It covers all form regressions above plus JavaScript date strings, unknown-zone rejection, and dot/Unicode line separators, comparing production public preflight with native HTTP status and pending/answered state. This case is also included in the full installed-native replay.
