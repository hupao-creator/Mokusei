# Thread detail projection and publication

Run from the repository root with the pinned Go toolchain:

```sh
./scripts/go.sh run -race ./tools/verification/thread-detail-performance
./scripts/go.sh test ./internal/platform/transport -run '^$' -bench 'Benchmark(Unchanged|Changed)Content' -benchmem -count 3 -benchtime 300ms
./scripts/go.sh run -race ./tools/verification/transport
```

The projection replay calls production Codex/Claude adapters with synthetic
100-step plans (1,024 characters per step), prompts and answers. It checks active,
completed, failed, interrupted and inherited turns; reader plan omission; retained
message fields and timeline identities; deferred reasoning presence; and source,
overview, context and full-execution isolation. A fixture cannot put a running
Codex turn in fork history: that would violate canonical admission.

The benchmarks call the actual transport `publishOne` implementation with a
prebuilt 2 KiB or 256 KiB projection and an advancing source revision. They cover
identical bytes, alternating equivalent whitespace encodings, and real alternating
message edits. Assertions check source/wire revision behavior, event presence and the first
visible patch after no-ops. Hosted runtime replays run three iterations under
the race detector as a correctness smoke check; timing is not a CI threshold.
Hosted adapter replays include the projection command.
The transport replay additionally exercises real HTTP/NDJSON, multi-client
UTF-16 patches, replacement/cancellation, worker bounds and shutdown. No paid model,
installed native CLI or user profile is involved.

These are projection/publication measurements, not end-to-end thread detail CPU,
frame rate, memory residency or energy measurements. Parsing canonical state and
projecting each new source revision remain outside the publication benchmark.
Plan fixture byte counts represent deliberately large plans, not a typical user
conversation. See [the integration record](integration.md) for measured evidence,
remaining hot paths and parallel-change intersections.
