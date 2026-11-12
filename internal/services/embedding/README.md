# Local embedding providers

The provider descriptor owns the exact vector space, model input protocol,
normalization, dimensions and document byte budget. Search consumes normalized
vectors without knowing a Gemma/Qwen task prefix. Equal dimensions alone never
establish compatibility. Providers validate external outputs at their boundary.

The native provider automatically prepares the model through the bundled Swift
helper. It uses bounded queues, one inference process and query-first admission
between short document batches. Failed preparation retries with bounded backoff;
explicit retry wakes that backoff. The entire helper retires after 90 seconds
without work. Downloaded verified weights survive this retirement and history
clearing. The process revalidates them when it next starts.

Cancelling a caller prevents its queued work or discards its eventual result;
it does not promise to interrupt synchronous LiteRT inference. Runtime shutdown
cancels and joins the process group. The helper also observes its parent process
exit independently of synchronous inference, preventing orphaned native work. Model texts and native logs are not retained
in application state. The private NDJSON pipe validates handshake identity,
response identity, dimensions, finite components and normalization.

The native and Runtime integration replays own verification, including a genuine
INT4 model run. A controlled provider can exercise stale/cancelled completion but
does not establish semantic quality or native compatibility.
