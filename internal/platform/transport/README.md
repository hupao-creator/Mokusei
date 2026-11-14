# Runtime transport

[protocol.go](protocol.go) defines protocol version **11**, public result envelopes and content scopes. Both peers require the exact version. The host owns business state; transport owns authentication, client leases, bounded delivery, command receipts and content streams.

Local clients discover the selected profile's private connection metadata and authenticate requests against its token and service epoch. The server listens only on loopback.

Native imports also carry `X-Mokusei-Attachment-Lease`, a canonical UUID naming
the importing process's private lock inside that same profile. Authentication
precedes header validation; accepted command contexts preserve this owner after
HTTP disconnection, and streaming file calls carry it through their normal
request context. The attachment service verifies the actual kernel lock before
staging. This is a local filesystem lifetime, not a reconnect or remote-device
lease; native staging rejects a client storage directory outside the host profile.

[receipts.go](receipts.go) and [receipt_query.go](receipt_query.go) retain command identity and results. A lost mutation response is resolved by querying its original command ID. Reconnecting does not blindly resend uncertain work. Disconnecting a presentation lease does not cancel work that the service has already accepted.

Service revocation cancels every admitted Host call before drain, including reads
whose HTTP clients remain connected. Reads also follow their request cancellation;
writes follow only the service lifetime. Drain waits for those calls and their
durable receipts while the health endpoint and stop response remain available. Cleanup errors are returned in the stop response before exit; they do not create a permanently failed health endpoint.

`Finish` joins HTTP shutdown after `Close` has retired the listener. If Serve
has not yet removed its listener wrapper, Shutdown can report `net.ErrClosed`
after all connections drain; this expected repeated close is success. Deadlines
and other shutdown errors remain failures.

[stream.go](stream.go), [content.go](content.go) and [delta.go](delta.go) carry snapshots and revisioned updates over HTTP/NDJSON. Clients reject stale epochs and recover gaps from authoritative snapshots. Catalogs carry bounded overview data; conversation/turn/execution scopes fetch the owned Harness projection on demand. JSON null, missing fields and integer values remain distinct. Swift encodes integer cursors and revisions as integer JSON tokens.

Requests, in-flight bytes, responses, clients and content-worker queues have explicit limits in the transport implementation. Slow or cancelled content readers release their leases; close joins workers and prevents late writes. [files.go](files.go) authorizes host files and attachment transfers without treating an arbitrary client path as an attachment capability.

Overview and thread-content session controls have their own 16-request admission
pool, separate from the 16 command/file request slots. Slow native queries cannot
block ordinary content release or re-subscription. Both pools retain the shared
192 MiB in-flight body budget, authenticated endpoints and 64-socket limit.

[overview.go](overview.go) brokers host-to-client overview control with device/lease ownership and bounded waits. It does not give background plugins direct access to native views.
The plugin Overview capability exposes only read-only client context; the Tag
Agent has no filter-selection tool or write adapter. The broker and native client
selection protocol remain available independently of background classification.

Verification from the repository root:

```sh
./scripts/go.sh run -race ./tools/verification/transport
```

`transport -swift-deltas` and `runtime -swift-voice` additionally use the actual Swift codecs and client.

After a semantic no-op, content subscriptions retain a fixed-size digest of
the accepted encoded projection; visible changes disarm it so continuously
changing streams do not pay for hashing. An identical projection at a new source revision advances freshness
without another decode, delta or event encoding. Equivalent re-encodings retain
the semantic comparison; empty patches never advance the wire revision. Changed
content and cancellation/replacement keep the existing ordered publication path.

Visible updates build a delta under an encoded-byte budget plus a high
operation-count safety valve. Reaching either budget stops refinement
immediately; the transport then encodes a complete snapshot instead of salvaging
a partial patch. A clearly smaller patch skips re-encoding the whole snapshot by
comparing against a conservative lower bound for the decoded value. That trades
a structural pass (no encoded snapshot allocation) for avoiding the full
snapshot encoding; once the patch reaches that bound, both complete wire events
are compared exactly. When
both representations fit, the smaller event wins; when only one fits, the
fitting representation is used. When neither fits, the update fails with
`CONTENT_TOO_LARGE`.

A raw projection (`snapshot.Value`) larger than the content frame remains a hard
failure before diffing, even if a theoretical patch could be smaller. This is
the separate oversized-authoritative-snapshot boundary, not an incremental
encoding fallback. Replacing an existing value with a newer
snapshot is authoritative on the same resource; the next patch uses that
snapshot's revision as its base. Frame selection does not weaken queue
backpressure: a representation that fits the frame can still fail with
`CONTENT_BACKPRESSURE` for its client's bounded queue.
The [reader projection replay and publication benchmark](../../../tools/verification/thread-detail-performance/README.md)
measure this boundary independently of Harness projection and native rendering.
