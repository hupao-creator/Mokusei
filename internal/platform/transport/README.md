# Runtime transport

[protocol.go](protocol.go) defines protocol version **11**, public result envelopes and content scopes. Both peers require the exact version. The host owns business state; transport owns authentication, client leases, bounded delivery, command receipts and content streams.

Local clients discover the selected profile's private connection metadata and authenticate requests against its token and service epoch. The server listens only on loopback.

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

Verification from the repository root:

```sh
./scripts/go.sh run -race ./tools/verification/transport
```

`transport -swift-deltas` and `runtime -swift-voice` additionally use the actual Swift codecs and client.
