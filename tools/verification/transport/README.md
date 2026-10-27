# Local transport replay

Run from the repository root with the Go version declared by `go.mod`:

```sh
go run -race ./tools/verification/transport
go build -o /dev/null ./tools/verification/transport
go vet ./tools/verification/transport
```

To verify Go-generated deltas with the actual Swift JSON decoder and delta
applier, run this additional mode on the project's macOS/Swift toolchain:

```sh
./scripts/go.sh run -race ./tools/verification/transport -swift-deltas
```

The native file-transfer boundary has a separate macOS replay:

```sh
./scripts/go.sh run -race ./tools/verification/transport -swift-files
```

It starts an authenticated Go file host and the production Swift client through
private profile discovery and its real HTTP/NDJSON connection. Regular files and
symlinks to regular files upload with checked bytes, lengths and SHA-256 digests.
FIFOs and symlinks to FIFOs must fail before a writer opens them and leave no
transfer directory behind. Ordinary downloads and a file named `.partial` retain
their checked bytes and basename. A delayed FIFO writer releases a regressed
blocking open so the assertion fails without hanging the native process. This
mode needs the macOS/Swift toolchain but no graphical application or provider.

Cold native settings admission has its own macOS replay:

```sh
./scripts/go.sh run -race ./tools/verification/transport -swift-settings-capacity
```

It submits four configuration scopes and installation detection for each of four
Harnesses, holds native discovery for six seconds, and reads ordinary state at
five seconds. All 20 reads must finish without capacity errors under the unchanged
Go request limit; discovery must stay at four active calls and one per Harness.
It also cancels a queued obsolete source and four active installation probes,
checks server-side cancellation and confirms subsequent acquisition without
uncertain receipts. Closing the client must wake pending reads as well.
The native discovery result is a fixture; initialization, cache and UI behavior
are covered by the separate settings and runtime-concurrency replays.

Five fixed content transitions cover UTF-16 offsets around astral characters,
nested array edits and insertions, deletion to an empty array, exact Unicode and
prototype-like keys, absent versus null fields, and replacement of the root by
null. The expected content is literal fixture data. The native consumer must
reconstruct it from the current Go producer's serialized deltas; operation count,
order and diff strategy are unconstrained. This closes a cross-language gap left
by Go's HTTP replay and Swift's hand-authored invalid-patch tests. It adds no
production API or dependency and reuses the Core test target. The private fixture
file is removed after the run, which fails if the Swift check is skipped. Cold
Swift compilation may dominate execution time; no app or provider is launched.

The runner uses exported Go APIs, a fixed mock `transport.Host`, real loopback HTTP/NDJSON connections, and a temporary private profile. It needs no Node installation, Harness executable, provider account, or paid network request. Fixtures are in the Go source; only temporary paths, ownership/session identities, loopback ports, and command freshness timestamps vary. Assertions fail with a nonzero exit status. Profiles, sockets, streams, and worker goroutines are cleaned up on success or failure.

The replay verifies:

- Profile exclusivity, canonical identity through a symlink alias, live ownership, private metadata permissions, discovery round-trip, rejection of readable-by-others or symlinked discovery files, epoch-checked removal, and reacquisition after release.
- Missing/wrong authorization, present Origin (including an empty header), stale epoch, protocol mismatch, unknown channels/query paths, malformed command identity, and health responses without bearer credentials.
- The 2 MiB overview body limit; declared bodies above the 144 MiB request limit; the 192 MiB aggregate body reservation; and independent 16-request command/file and session-control limits. Content release cancels a blocked worker and re-subscription succeeds while all command slots are occupied. Filling session slots still permits a command and rejects a seventeenth session request. Body/slot reservation cases exchange headers only, using `100 Continue` as the admission barrier, so they do not allocate or upload hundreds of MiB.
- Two independent NDJSON clients, hello identities, scoped content snapshots, mutation delivery, local revision chains, UTF-16 text deltas across emoji, cancellation of an obsolete read, replacement snapshots, resource-local projection-panic errors, and continued delivery afterward.
- Overview selection through real HTTP context/claim/ack endpoints and the NDJSON delivery stream. Additional public-broker replays cover detached reads, strict JSON validation, claim-once acknowledgement, stale/superseded requests, cancellation, timeout, disconnect, retired renderer contexts, the 128-context retirement bound, and shutdown rejection.
- Concurrent duplicate command receipts, argument reuse rejection, a client disconnect after durable admission, unchanged replayed outcomes after reopening the receipt store, indeterminate recovery of a pending receipt, expired command rejection, and malformed persisted-outcome rejection. Both read and write handlers receive their exact command ID through `transport.CommandID(ctx)`.
- `/stop` retaining its HTTP response while closing other connections. `Server.Finish` runs outside the stop handler, after the response, to join response writers without a shutdown deadlock.
- Actual daemon shutdown with admitted read and write handlers waiting for cancellation. Revocation cancels both before drain; health and the profile lease remain available until the handlers return. Separate fixtures return cancellation or an already-committed success after observing cancellation. Stop then finishes, releases ownership and retains each exact receipt outcome across reopen without re-execution.

This is a protocol/lifecycle replay, not evidence for real Harness integration, macOS UI behavior, microphone/WebRTC audio, performance on particular hardware, or provider latency. It does not exercise full-size 144 MiB uploads, the 32 MiB response/content-backpressure boundary, all 32-client/64-socket limits, 5,000-receipt/32 MiB receipt saturation, slow-header timeouts, cross-account filesystem ownership, process-kill recovery, or injected fsync/disk-full failures. The pending-receipt recovery case uses a fixed on-disk admission record rather than killing a real writer.
