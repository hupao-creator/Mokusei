# Codex integration replay

Run from the repository root with the project's Go toolchain:

```sh
go run -race ./tools/verification/codex
```

The executable reuses itself as a scripted external Codex CLI. It creates an isolated temporary HOME, native data directory and workspace, and removes them when the run finishes. No installed Codex, credentials, Node, Python, model service or external network is needed. A failed assertion exits nonzero. This is an integration command, not a unit-test suite.

The synthetic replay checks:

- Isolated native homes preserve configured system-proxy feature booleans,
  including false, without inheriting unrelated tool features. Reusing the home
  must also remove settings that are absent from the next native configuration.

- Connection recovery stops after five consecutive native retry errors or a
  real 60-second window without model/tool progress. Status and acknowledged
  follow-ups do not extend it; a healthy 63-second tool survives reconnection.
  Retired-turn late events cannot complete or corrupt the successor during
  admission, and each original/successor input is dispatched exactly once.
- Native `model/list` controls remain usable without an account probe. A failed
  account RPC does not block ordinary execution, while model provenance still
  reports that failure and external accounts cannot acquire native ChatGPT voice. A voice owner
  can execute text, admit a new native voice execution, fail its connection,
  release voice, complete new text and prepare voice again.
- Notifications arriving before the `turn/start` response, streaming text, approvals, public interaction IDs and final durable projection.
- Moku-composed Codex creation requires an explicit model-supported service tier:
  omission, null, boolean, inherit, and unknown tiers are rejected even when
  configured defaults contain a tier.
- Explicit standard and priority choices survive start, follow-up, resume, fork,
  and state persistence against native priority defaults. Missing or mismatched
  native confirmation rejects the task before any `turn/start`.
- Ordinary-thread thinking and tier conversion must not cause a second validation
  as an internal execution profile.
- A separate history-read process and an independent native fork.
- Follow-up steering with the original execution identity and exactly one durable admission callback per input.
- Follow-ups racing native completion wait for durable settlement and receive a
  fresh host identity before dispatch. Native rejection never fails the original
  execution, acknowledges rejected input, or prevents the next send. Cancelled
  and uncertain sends are not replayed.
- Interrupt settlement and session resume after process shutdown.
- Native voice context injection, SDP response, polling and explicit stop acknowledgement.
- Native voice configuration rejection before Core/tool admission, exact
  handoff recovery only after process and bridge cleanup, generic/uncertain
  rejection without automatic recovery, and concurrent configuration closure.
  Use `-voice-configuration-only` for these external-process protocol fixtures.
- Voice relay, direct owner and private discussion startup with a newer CLI.
  The focused `-voice-only` replay also accepts future, unversioned and empty
  user-agent strings when V3 works, and preserves native method/parameter
  rejections with a Chinese compatibility diagnostic, one start attempt and no
  reuse of the failed media session.
  The peer requires V3 WebRTC with client-managed handoffs.
- An authenticated private MCP tool call with native thread, turn and call identities.
- Process crashes with a descendant holding inherited pipes, malformed JSON, bounded failure propagation and process-group cleanup.
- Real Runtime/SQLite history reset with screenshot-shaped stale Hooks, lost
  private sessions, live background child processes, natural continuation,
  stop/completion races, failed and timed-out cancellation, unavailable terminal
  lists, process-exit uncertainty, unknown owners and settings retention. See
  [the lifecycle contract](../../../internal/core/runtime/README.md).

The synthetic replay also sends a multi-file native activity through production
event decoding, durable settlement and renderer projection, asserting that unique
paths survive even when one activity contains several changes.

## Installed native CLI against a local Provider

On macOS, provide the path to an installed **native Codex executable**, rather than an npm JavaScript launcher:

```sh
go run -race ./tools/verification/codex -real-codex /absolute/path/to/native/codex
```

This first runs the synthetic replay, then starts the real app-server with an empty temporary HOME and Codex profile. A local Go HTTP server supplies scripted Responses API SSE messages; the literal fixture API key has no external authority. The child runs under `sandbox-exec` with outbound network access restricted to localhost. Proxy requests are routed to the same local server, which rejects and records every non-Provider request; the loopback Provider is explicitly exempted from proxying. The command refuses to run this mode when it cannot establish the OS network boundary.

The installed-CLI replay verifies real protocol admission with workspace-write and no additional writable roots, final projection, native fork and history read, persisted session resume, and a namespaced model function call routed through the actual native MCP client to the Go tool callback. The empty writable-roots list must be encoded as `[]`, not `null`. It also rejects a first turn before any rollout exists, exits the native process, records a failed resume, then verifies a new-input retry with both failed audits retained. Completed, inherited and uncertain histories are never automatically reset when their rollout is missing. This phase audits exactly six requests to the local Provider, preserving the requested model and streaming mode. A subsequent fault phase closes HTTP SSE before completion, verifies actual native `error` / `willRetry` recovery over five attempts, then resumes the durable session with exactly one new Provider request for a deliberate successor input. No paid model request is made, and user configuration or credentials are not read into the child environment.

Verified with **Codex CLI 0.163.0**, including Go's race detector. A different CLI version may expose protocol changes and legitimately fail the replay.

The voice check uses synthetic SDP only. These commands do not establish real WebRTC audio, microphone permissions, spoken transcripts, remote subscription quota, or model quality. Installed-CLI approvals, cancellation, and steering are not claimed by the real-CLI pass; those branches are covered by the scripted peer.

Both modes build as part of `go build ./...`. Temporary peers never become a runtime fallback for Mokusei.

For just the native voice event/feedback correlation replay (no audio devices), run
`./scripts/go.sh run -race ./tools/verification/codex -voice-only`.
Set `MOKUSEI_VOICE_EVENT_EXPORT=/tmp/mokusei-moku-voice-events.json` to export
the production adapter's events for the Swift `NativeVoiceInputTranscriptTests`
cross-language replay. This covers accumulated partial/final ASR, direct feedback,
handoff generation identity, interleaved new input and late feedback for an older
ASR item. It does not launch the installed app or an existing runtime.

The synthetic replay also settles a running execution through the host before
closing its native handle. Late native callbacks must not rewrite that durable
terminal execution or produce rejected commits during shutdown.

`make pbt` additionally generates Codex event/rejection/settlement orderings and
checks schema validity and immutable terminal projections after every step.
Runtime/SQLite properties cover admission counts, identities, cancellation and
credential-expiry precedence. Failures shrink automatically and are replayable.

The installed-CLI replay uses an isolated native Fast default and explicitly
requests standard service. Native thread replies and all six local Provider
requests must retain standard service, including fork and resume. Its injected
tools include the real Moku-composed Codex creation schema; the captured
model-facing declaration must expose `options.serviceTier` as required. The
scripted Provider never calls that creation tool.

`-voice-only` additionally checks launch-catalog reuse and account/configuration
invalidation, idle fresh-process prewarming, repeated direct calls, consuming a
warm candidate before work, active-owner protection, shutdown during prewarm,
unrelated-thread late events, and discussion preparation with exactly one
app-server instead of an unused configuration-reader process.

To run the installed-CLI loopback checks independently of the synthetic
background/process-group scenarios, use `-real-only -real-codex /path/to/codex`.
The native replay now prepares and closes three private read-only discussion
forks without inference; the original phase's network audit still requires
exactly six scripted Provider requests before the separate recovery fault phase.
This is preparation evidence, not a remote microphone call.

The full replay has a bounded five-minute lifetime to include the production
60-second retry window and the concurrent healthy 63-second tool scenario.

`-stream-only` runs the focused native JSONL streaming replay. A protocol barrier
after the first reasoning chunk checks that the running analysis status is
already durable. Subsequent chunks must not repeat status-only commits. Both
reasoning and assistant text are checked after ordinary completion and interrupt;
a rejected stream commit must remain an observable `Close` error. The full
synthetic replay includes these checks. A native planning status between reasoning
chunks must yield back to analysis. The file barriers order native processing;
they do not freeze the 50 ms timer, so interruption proves retained content rather
than guaranteeing that every cancelled delta was still awaiting a timer flush.

For comparable streaming measurements, build this runner once and run:

```sh
./scripts/go.sh build -o /private/tmp/mokusei-codex-stream ./tools/verification/codex
/private/tmp/mokusei-codex-stream -stream-performance -stream-chunks 512 -stream-repeats 3
```

This mode emits one JSON object per reasoning/text sample and intentionally has
no optimization threshold, so the same fixture can run against baseline source
through Go's `-overlay`. Every sample starts its own scripted external app-server
and exercises production JSONL parsing, native mapping, Handle batching and
SessionState projection. The in-memory store excludes SQLite and subscriptions.
Startup and the first 32-byte chunk finish before measurement; `measuredChunks`
counts the remaining chunks. Wall time includes native transport and terminal
publication. CPU, allocation bytes and allocation counts cover only the parent
runner process, including its store; they exclude the external fixture process.
Status-only inspection runs only in the correctness replay, so it does not add
JSON decoding to measured commits. Compare repeated samples with the same chunk
count and toolchain, without the race detector for performance conclusions.

Each sample verifies complete final text, reasoning and terminal status, then
prints a SHA-256 of the full final state after removing timestamps and normalizing
generated timeline IDs. All content, ordering, model settings and status fields
remain in that digest, allowing baseline/after equality checks. These fixtures
use no installed native CLI, account, model endpoint or network service.

`-settlement-only` runs the focused native/durable completion race replay. An
explicit `-32600 / no active turn to steer` rejection can reserve a successor
only after native terminal publication is durably complete. Generic rejection,
transport uncertainty and cancelled sends are not replayed. The replay blocks
terminal publication to assert that acknowledgement cannot precede it, then
checks a single fresh execution and exactly one accepted input for the successor.

The settlement replay also holds the native completion notification behind an
explicit barrier for longer than the former five-steer retry window. It covers
ordinary follow-ups, cancellation during that wait, and real Runtime/SQLite Moku
delivery admission after a child completion. The delivery must leave the outbox
only after a single successor admission; the original execution stays completed.
