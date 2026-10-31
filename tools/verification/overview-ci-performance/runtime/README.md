# Independent Overview CI source

This executable seeds an exclusively owned SQLite profile, constructs the
production Codex state adapter and `core.Runtime`, and serves the unchanged
authenticated production HTTP/NDJSON transport. The Swift replay starts it;
the Python A/B runner must not start a second Core process.

```sh
go build -o /absolute/overview-runtime ./tools/verification/overview-ci-performance/runtime
/absolute/overview-runtime \
  --ready-file /absolute/evidence/core-ready.json \
  --output /absolute/evidence/core-result.json \
  --condition A4 --warmup 5 --seconds 20 --seed 198 --parent-pid <swift-pid>
```

The parent directory of `--output` holds the temporary, exclusively created
profile. Cleanup removes only that owned profile. The ready/result files remain
with mode 0600. A one-second parent watchdog, signal handling, and a two-minute
lifetime bound prevent an orphan source from contaminating a later trial.
Thread working directories share the stable `overview-workspace` basename
inside that owned profile, so random profile names do not change visible labels
between A/B processes.

## Load and production boundary

There are exactly 40 `card-N` thread records. Cards 0–3 retain running executions
and one running derived subagent activity each; the other 36 have completed
executions. Ascending creation timestamps place those four cards first. All data
originates as valid Codex state
via `StageExecutionChecked`, `ReduceEvent`, and `SettleExecution`. No Swift card
snapshots are supplied. The consumer must verify the four running cards have the
intended production 2×1 footprint and are fully visible.

| Condition | Source input |
| --- | --- |
| R0 | No content mutations; all four running cards stay mounted. |
| S4 | Four cards receive 240-byte sliding windows from the public synthetic text, one card every 25 ms. |
| A4 | Four cards receive strictly cumulative message text, adding four ASCII source bytes per card event, one card every 25 ms. |

S4/A4 each schedule 1,000 independent events: 200 during the nominal five-second
warmup and 800 during the nominal twenty-second formal window. Each card receives
250 events. Source protocol 2 uses an independent producer on absolute Go
monotonic deadlines and a separate serial mutation worker. The producer enqueues
identity/sequence metadata into a preallocated 256-entry FIFO; it never performs
session reduction or `Store.Update`, and never waits for the worker. Actual
enqueue lateness beyond 50ms or queue overflow invalidates the run. The queue is
bounded even when production work stalls; it does not drop inputs silently or
reshape four events into one transaction. The worker always starts from the
latest accepted record for that card, not a snapshot captured at enqueue time.

Protocol 1 performed preparation and the store call in its producer. Its
sent-minus-planned deadline failures remain failures in those archived reports.
Protocol 2 retains that same sent timing and the old gate's late count, maximum
and would-fail result in `source.legacySentDeadline`; its new enqueue gate has an
explicit version. Do not mix the two protocols or retroactively reclassify an old
experiment. Go and host scheduling can still delay the independent producer, and
those actual enqueue misses remain invalid.

Both changing loads use the production Codex `text-final` event on a stable
assistant item while the execution remains running. A4 is **cumulative message
replacement**, not a provider `text-delta` replay. This distinction is necessary:
the current production Overview selects complete assistant messages or reasoning
for its excerpt, not a streaming assistant item. The publication and UI paths
are real; the provider source is synthetic.

Each event independently calls `Store.Update`. The production 50 ms publisher
owns coalescing, projection, and mutation delivery. Thread recency and execution
start time stay fixed to isolate content updates from ordering/structural work.
`ThreadRecord.revision - 1` is the sequence side channel; a changing sequence is
never appended to message text. A4 remains a strict prefix extension after the
normal production whitespace trimming. Its final projected message is below the
production 1,200-character Overview projection cap.

The production Codex adapter has an explicitly unavailable external environment.
Consequently normal installation/settings requests retain their Runtime/HTTP
routes but cannot discover or start an installed provider or read user accounts.
This is an intentionally controlled availability condition, not a real-provider
throughput claim. Global and Moku settings have a pre-existing fixture profile.

## Control contract

`core-ready.json` includes:

- `schemaVersion`, `pid`, absolute `executable`, `parentPID`,
  `sourceProtocolVersion=2`, `sourceQueueCapacity=256`;
- standard production `connection` (`port`, `token`, `epoch`, `protocolVersion`,
  `pid`, `dataDir`), which the real Swift `RuntimeClient` consumes;
- `controlURL` and `controlToken`, plus `condition`, `n`, `k`, `seed`;
- `expectedCards`, the four expected final public projections.

Control requests use `Authorization: Bearer <controlToken>` on a separate
loopback-only HTTP server. This server does not replace any production route.

| Request | Response / action |
| --- | --- |
| `POST /start` | Starts once, returning protocol/capacity and future `warmupStartUnixNano`, `formalStartUnixNano`, `formalEndUnixNano`, `warmupSeconds`, `formalSeconds`, and `sourceIntervalNanoseconds`. The first boundary is one second ahead. |
| `GET /status` | Protocol/capacity, `state`, `sourceComplete`, `enqueueComplete`, `producerFinished`, `formalComplete`, `currentSeqs`, `errors` and a bounded input-FIFO snapshot. Do not poll it per source event. |
| `GET /result` | Complete versioned evidence snapshot; HTTP 409 until the actual formal-end sample exists. |
| `POST /finish` | Acknowledges `{ "ok": true }`, stops the owned runtime, writes the final result, and exits. Wait for exit, then read the final output file. |

UTC nanoseconds are JSON integer tokens. They let Swift schedule against a
single Date→uptime anchor. Each process reports its actual sampling timestamp
and lateness; planned timestamps are not substituted for actual CPU intervals.
The Core sampler opens the initial warmup interval before source event zero.
Subsequent event deadlines remain independent of the UI and of the sampler.

`enqueueComplete` means every planned event was admitted to the FIFO;
`producerFinished` also records abnormal producer termination. Neither substitutes
for `sourceComplete`, which still requires acceptance of all planned mutations.
The worker can finish queued work within the original five-second observation
budget. Backlog does not move the five-second warmup/twenty-second supply or
formal CPU boundaries, and does not increase the tail budget. The additional
tail/full UI CPU windows still end at actual model stability within that budget;
their duration can therefore increase when more pending work remains.
Cancellation retains queued identities and any dequeued-but-unsent terminal
failure. A production transaction that returns success is still accepted even
if cancellation was requested while its outcome was being determined.

Each expected/final card is:

```text
{ id, seq, revision, messageID, itemID, textSHA256, textLength }
```

`messageID` is the production Overview projection's assistant `timeline.id`;
`itemID` is `ci-message-card-N`. Hashes are SHA-256 of the projected content's exact
UTF-8 bytes. The source's initial revision is zero (`seq = -1`); S4/A4 finish at
revision 250 (`seq = 249`). References are generated through the real projection,
including its trimming, rather than duplicating projection rules in the harness.

## Measurements and limits

The top-level `cpu` is only the formal Core interval:
`{ cpuSeconds, wallSeconds, cpuPercent }`, with user+system `getrusage` seconds
divided by actual monotonic wall seconds and multiplied by 100. It is a
single-core percentage. Capture, profiling, result encoding, and final text
hashing do not belong in the formal Swift measurement.

`boundaries` retains actual/planned boundary times, cumulative user/system CPU,
and maximum RSS. `windows.warmup`, `windows.formal`, and `windows.tail` classify
each actual enqueue, dequeue, send, acceptance and publication by half-open actual sampling
intervals. They are recomputed from retained event timestamps; warmup cannot
silently enter the formal count. A source event at a boundary can belong to a
different actual window than its nominal deadline. `source.nominalWarmupEvents`
and `source.nominalFormalEvents` preserve the intended 200/800 split separately.

Top-level `source.planned/enqueued/dequeued/sent/accepted` are whole-run totals,
never formal-only numbers. `sourceEvents` preserves every planned event, including
unsupplied entries after cancellation, with actual enqueue, dequeue, preparation
start (`sent`), store-call start and accepted/completed timestamps and errors.
Their monotonic elapsed values separate enqueue lateness, queue waiting,
preparation, store-call time and overall acceptance latency. Missing actual
boundaries stay missing; they are not filled with planned times.

`queue` identifies the harness input FIFO, with pending identities, in-flight
identity/age, high water, oldest waiting age and overflow receipts. Successful
final evidence requires all planned inputs accepted and no pending/in-flight
work. The top-level queue snapshot carries its own `observedAt`. Its `boundaries`
reconstructs historical occupancy from the retained monotonic event-stage
timestamps at actual Core CPU sample boundaries; it is not a synchronized
queue-lock snapshot at each boundary. Swift's first-observed completion timestamps
are tail polling observations, not actual Core completion instants. This is not
a measurement of production Store, publisher, socket or UI queue depth.
`publications` records real Runtime
publication callbacks, revisions, dirty-card identities/sequences, and byte
counts. The callback decodes only identity/revision fields; it does not retain
or re-encode the full native state.

An exact published `(cardID, seq)` can be linked to that source event. Source
events merged by the production publisher remain coalesced, without fabricated
individual install times. Accepted-to-publish differences can be negative:
the store commits and notifies subscribers before the calling worker resumes
and records the successful return. Keep the signed difference; it does not mean
the publication preceded the commit.

`publish.wireBytes` is the **encoded production mutation NDJSON payload size**:
the actual mutation bytes plus the exact fixed envelope/newline overhead. It is
not a socket-byte or consumer-delivery measurement. Network queue length,
overflow, and bytes actually received remain unobserved without a separate
production-client seam. Swift independently validates installed final sequences
and hashes.

The tail is the interval from the actual formal-end sample until observation
ends. `tail.observationSeconds` is not queue-drain latency. Last accepted and
publication timestamps and tail publication counts are retained without adding
a fabricated 500 ms drain estimate.

This harness supplies a repeatable hosted-runner comparison. Its absolute CPU,
display cadence, and graphics behavior are not interchangeable with a local
M1 Pro or a 120 Hz physical display.
