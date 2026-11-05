# Private tool invocation journal

Production Moku, Tag Agent and Report Agent injected Go tool callbacks are
recorded locally at `<profile>/runtime/tool-calls/tools-YYYY-MM-DD-NNNN.jsonl`.
There is no upload, UI projection or report-generation context injection. Never
paste retained bodies into analysis reports. The daemon opens/closes this sink
under its existing exclusive profile lease, after native owners drain on close.
Direct Runtime embedders must supply `Config.ToolTrace`; a nil sink collects
nothing. There is no historical backfill.

## Existing chains and differences

| Evidence | Moku | Tag / Report |
| --- | --- | --- |
| Native history | Opaque Harness-owned session state in SQLite, plus native-engine history where applicable | Separate private session per scoped agent instance, lazy open and idle disposal |
| Host audit | `tool-operation` transcript rows with host-generated operation/call IDs, arguments and result/error under an execution | Durable lifecycle inbox, batch attempts and mutation receipts; these describe work/effects, not every tool call |
| Events | Transactional domain lifecycle facts; transient activity/subscriptions project committed state | Same; a receipt can return a previous effect without rerunning a mutation |
| Diagnostics | `runtime/debug-logs/service.jsonl`: 8 KiB/line, 8 MiB/file, four files, no guaranteed time window | Same, plus runner stage/attempt/duration summaries without bodies |

The new journal supplements these mechanisms. Existing native/SQLite/transcript
content is **not** sanitized by this policy, and retains its existing lifetime.
`runtime/process.log` is a separate process diagnostic stream. The journal has
its own byte/date budget so body traffic cannot evict service diagnostics.

All four Harnesses ultimately invoke `ToolBinding.Execute`. Runtime wraps a copy
of each relevant injection outside tool-specific lifetime/argument validation.
Codex passes a dynamic native call ID, Pi its native tool call ID, OpenCode its
bridge's native `callId`. Claude passes an MCP JSON-RPC request ID, **not** its
model tool-use ID. Its existing 256-byte bound is exposed as `callIdTruncated`.
Bridge admission, duplicate rejection, cancellation and result delivery remain
Harness-owned. No search behavior or registration changes here.

## Version 1 contract

Each actual callback has a fresh UUID `invocationId`, a `tool.started` row with
input and a `tool.finished` row with output/error. Rows may interleave; join by
invocation ID, never adjacency. `journalId` identifies one sink lifetime;
`sequence` orders attempted writes in it. Gaps may indicate retention or failed
writes, but cannot measure attempts rejected before the callback boundary.

- `agent` is `moku`, `tag` or `report`; `agentId` identifies the host-bound
  instance. Moku has explicit global scope. Background scope is its bound
  directory identity (private absolute path) or literal `inbox`; missing never
  means Inbox. Display names are not scope identity.
- `sessionId` is the host session/Thread ID. `executionId` is the host observation
  captured at entry. Native session IDs are opaque here and marked missing.
  `callIdKind` states the provenance of `callId`. Host invocation identity is
  distinct from both native call identity and mutation receipt identity.
- Background `consumerId`, `batchId`, and persisted one-based `attempt` are
  captured at entry, not settlement. A batch persists across retries; a refunded
  user-pause attempt can reuse a number. No receipt-hit status is exposed here.
  `retryOfInvocationId` is explicitly missing: argument equality and batch
  membership do not prove model retry intent. Moku has no background attempt.
  `batchExecutionId` and `retryContextStatus` expose whether that snapshot matches
  the captured execution, is unconfirmed, mismatched, missing or not applicable.
  `executionStatusAtEntry` retains the observed status, including stale callbacks.
- UTC RFC3339Nano `startedAt`/`finishedAt` describe wrapper boundaries.
  Monotonic `durationMs` includes metadata capture and the start journal write,
  queue wait and fsync; `handlerDurationMs` measures only the wrapped callback,
  including its existing audit/host operations. Finish serialization/write/fsync
  and native result delivery are excluded. Only finish rows have measured work;
  durations in start rows are zero.
- Outcomes carry evidence: `succeeded/callback-returned`,
  `business_rejected/caller-error`, `business_rejected/tool-ok-false`,
  `cancelled/context-cancelled`, or `failed` with deadline, panic, invalid-result
  or unclassified-error basis. `ok:false` can include partial effects, such as
  batch interrupts. Known background shape failures use `ToolCallError` like
  Moku validation. Existing untyped business errors remain unclassified, not
  proven infrastructure faults. Typed public `errorCode` is retained when available.
  Empty successful output is unknown because bridges normalize/reject it differently.
- Error data retains type and redacted message for wrapped/joined causes,
  at most 16 nodes, depth 8 and 16 KiB per message, with omission flags.
  Panic payloads are withheld. Existing inner recovery may already have turned
  a panic into a generic error. Callback success proves neither native result
  receipt nor durable business effects, execution completion or task success.

`coverage:injected-callback-only` excludes native built-ins/ambient tools,
unknown tools, malformed bridge frames, permission/duplicate rejections and
cancellations rejected before Execute. No rows does not prove no model attempt.
Normal exclusive tool restrictions continue to apply.

Start is appended/fsynced before handler entry. Finish runs on errors,
cancellation and panic unwinding without depending on the cancelled request
context. Only-start means **incomplete, outcome unknown**, not failed or still
running. Finish-without-start may mean eviction or failed start persistence.
`startRecorded:false` means a start write/retention error; true does not guarantee
the start remains retained. Death/disk/fsync failures can leave uncertain or
missing records. A partial last line is kept in its old segment; reopening uses
a new segment and the reader reports damaged lines. File fsync is not an atomic
transaction with SQLite or a power-loss-proof directory manifest. Logging failure
does not change a callback result or authorize retry of an effect: service events
`tool-audit.write-failed` / `tool-audit.identity-failed` report lost coverage without
bodies. Identity-generation failure still permits the callback.

Synchronous file writes/fsync avoid a lossy in-memory queue, but disk latency or
contention can delay callbacks and shutdown. The journal does not impose a
separate cancellable filesystem I/O deadline; latency is not benchmarked here.

Check retained service diagnostics for `tool-audit.write-failed` and
`tool-audit.identity-failed` as well as the journal when assessing coverage.

## Privacy and payload policy `private-redacted-v1`

Directories are `0700`, files `0600`; regular-file checks and profile ownership
are reused. Storage is plaintext private workspace data, not anonymous telemetry.
Ordinary prose, HTML, queries, IDs, paths, pagination and per-item results are
retained because analysis needs them; personal data and arbitrary prose can remain.

Object credential keys are case-insensitive, ignoring spaces/underscores/hyphens:
authorization/proxy authorization, cookie/set cookie, password/passwd/pwd,
secret/client secret, API key, access/refresh/ID token, token, credential(s),
private key, and names ending in password/secret/API key. Their values become
`[REDACTED]`. Text also redacts private-key PEM blocks (including unfinished ones),
Bearer/Basic values, common `sk-`, GitHub and AWS access-key forms, common credential
`key=value`/`key:value` patterns and HTTP(S) URL user:password authority. JSON inside
text, including paged evidence, gets the same structural policy and stays a string.
This is a concrete heuristic, not comprehensive secret/PII detection: unlabelled
secrets and other formats can remain. Review selected data before sharing it.

Payload envelopes expose `status`, `originalBytes`, `sanitizedBytes`, `storedBytes`,
`redactions`, `omissions`, and SHA-256 of the complete **sanitized** serialization,
never raw secrets. `json` holds complete sanitized data. Beyond a **256 KiB
input/output/error JSON budget**, `status:truncated` and `jsonPrefix` hold a UTF-8 prefix that
need not parse as JSON. Depth beyond 64 is omitted and counted. Invalid JSON or
values above the **8 MiB decode bound** retain byte counts and explicit omission
status, without unsafe raw prefixes. Empty bytes mean `missing`; JSON `null`
is a complete observed value. `complete` means complete sanitized data, not raw
byte fidelity: key order/whitespace can normalize; numbers use `json.Number`.
Metadata text is bounded to 1024 bytes (scope 4096); `metadataTruncated` names
affected fields. Do not join on redacted/truncated native IDs.

Truncated payloads additionally retain a sanitized `structure` sample (128 nodes,
depth 6, first 8 array items, 128-byte string/key previews, explicit omission
counts). This keeps later fields visible when an early HTML/text field exhausts
the JSON prefix. It is a structural sample, not the original payload. Default
query summaries exclude it alongside all other body fields. Metadata string
redactions are named separately in `metadataRedacted`.
`storedBytes` counts the JSON/prefix bytes; `structureBytes` counts this additional
sample. Envelope and JSON escaping overhead also consume the actual file budget.

## Actual retention and queries

Segments rotate at **16 MiB** and each UTC date. Startup and successful writes
prune oldest segments to **256 MiB total**, retaining only the current date and
preceding 13 dates. High traffic evicts earlier: **no minimum 14-day guarantee**.
At 512 KiB of retained input/output per call, the cap fits only about 512 calls
before metadata/JSON escaping overhead; small calls retain more. Whole-segment
eviction can split pairs; there are no per-agent quotas. Cleanup errors are
observable write failures and can temporarily exceed the budget. Idle/stopped
processes have no expiry timer; date cleanup resumes at next startup/write,
not an exact wall-clock deadline. Clock changes affect date retention, not
monotonic elapsed time.

The daily segment index is bounded to 10,000 segments; exhaustion reports a
write failure instead of creating files outside the retention/query namespace.

History clearing leaves diagnostics intact. For immediate removal, stop the
profile runtime, then delete its `runtime/tool-calls` directory. Export required
records privately before eviction; operator exports have independent lifetimes.
Queries are read-only and do not open native sessions:

```sh
python3 scripts/query-tool-calls.py /absolute/profile/runtime/tool-calls --agent tag
python3 scripts/query-tool-calls.py /absolute/profile/runtime/tool-calls --execution EXECUTION_ID
python3 scripts/query-tool-calls.py /absolute/profile/runtime/tool-calls --invocation UUID --details
```

Default output has metadata and payload size/completeness only. Bodies require
one invocation ID plus `--details`. `recordState` distinguishes finished,
finish-without-start and incomplete/unknown. Stderr counts malformed/vanished
segments. Active rotation is a best-effort snapshot; copy a stopped journal for
stable analysis. Moku transcript `invocationId`/`harnessCallId` correlate to this
journal; its older host-generated `callId`/operation `id` retain their UI meaning.

Synthetic abbreviated finish structure (bodies intentionally omitted):

```json
{"version":1,"event":"tool.finished","invocationId":"UUID","journalId":"LOGGER_ID","sequence":2,"agent":"tag","agentId":"tag.agent.INSTANCE","scope":{"kind":"directory","scope":"inbox"},"harnessId":"pi","sessionId":"HOST_SESSION","executionId":"HOST_EXECUTION","callId":"NATIVE_CALL","callIdKind":"native-tool-call","callIdTruncated":false,"consumerId":"INSTANCE.events","batchId":"BATCH","attempt":1,"startedAt":"2026-11-05T00:00:00Z","finishedAt":"2026-11-05T00:00:00.020Z","durationMs":20,"handlerDurationMs":12,"outcome":"succeeded","outcomeBasis":"callback-returned","coverage":"injected-callback-only","startRecorded":true,"missing":["nativeSessionId","retryOfInvocationId"],"payloadPolicy":"private-redacted-v1","output":{"status":"complete","originalBytes":11,"sanitizedBytes":11,"storedBytes":11,"redactions":0,"omissions":0}}
```

## Spring Mode verification and integration

No tests are added; no regression/replay, PR, push or merge is performed.
Permitted checks are production Go build, formatting, architecture, vet, Python
syntax and diff/link review. Crash/restart, retention load, concurrent cancellation,
real bridge delivery and redaction edge cases remain dynamically unverified.
The coordinator must arrange appropriate verification before safe integration.

Independent Moku `grep_threads` work may overlap `services/moku/tools.go` and tool
registration. This change only adds correlation fields to the existing transcript
append there; preserve both changes. New injected Moku tools automatically pass
through the shared Runtime wrapper, without search-specific instrumentation.
