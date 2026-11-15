# Harness reader projection reuse

Run from the repository root with the pinned Go toolchain:

```sh
./scripts/go.sh run -race ./tools/verification/projection-reuse
./scripts/go.sh test ./tools/verification/projection-reuse -run '^$' \
  -bench 'BenchmarkReaderNarrowScopes' -benchmem -benchtime 300ms -count 5
./scripts/go.sh run ./tools/verification/projection-reuse -large-entry
```

The replay uses the production Runtime and the production Claude, Codex, Pi and
OpenCode `ReaderProjectionAdapter` implementations. For every Harness it builds
a state with one fixed target execution and configurable unrelated executions or
native transcript bytes, then verifies:

- a cold narrow read builds one index and one target projection;
- the same content version and an existing source revision rebuild neither;
- changing only host metadata or an unrelated execution keeps the target
  revision and emits no content snapshot;
- a visible target change is delivered with a new revision;
- the catalog overview uses the same reader adapter as content subscriptions;
- concurrent overview, turn and execution reads produce the same bytes as
  sequential reads, and a narrow projection equals the production full-scope
  projection for the same state (Codex normalizes its Thread-level timestamp);
- interleaved old/new content versions do not cross values, deleting a Thread
  evicts its generation, history reset drops old generations, a canceled read
  does not poison later reads, and 96 scopes plus 300 Threads stay inside the
  per-entry/Thread/budget limits;
- fork-history narrow projections remain equivalent for Claude, Codex and
  OpenCode.

`-large-entry` builds a real Pi state with a 70 MiB native transcript and
asserts that the reader retains an entry above the old 64 MiB cap under the
128 MiB adapter budget. It is optional because the default CI fixture stays
small; the sessioncache unit tests also cover the synthetic per-entry,
per-session and Thread-limit boundaries.

The benchmark reports `ns/op`, `B/op` and `allocs/op` for cold, same-version and
unrelated-execution reads at 256 KiB and 8 MiB unrelated transcript sizes. Use
`-count 5` and report the median; use Go's `-cpuprofile`/`-memprofile` flags for
CPU and heap profiles. The replay also prints actual `HeapInuse`, `HeapAlloc`
and `Sys` after a forced GC for each adapter. These are local diagnostic values,
not an end-to-end frame, energy or UI claim. Wire totals are the actual projected
JSON sizes for the narrow execution scope.
