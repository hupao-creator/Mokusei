# Thread detail projection and publication

Run from the repository root with the pinned Go toolchain:

```sh
./scripts/go.sh run -race ./tools/verification/thread-detail-performance
./scripts/go.sh test ./internal/platform/transport -run '^$' -bench 'Benchmark(Unchanged|Changed)Content' -benchmem -count 3 -benchtime 300ms
./scripts/go.sh run -race ./tools/verification/transport
```

The projection replay calls the production `ReaderProjectionAdapter` path for
Codex/Claude with synthetic 100-step plans (1,024 characters per step), prompts
and answers. It checks active,
completed, failed, interrupted and inherited turns; reader plan omission; retained
message fields and timeline identities; deferred reasoning presence; and source,
overview, context and full-execution isolation. A fixture cannot put a running
Codex turn in fork history: that would violate canonical admission.

All four production adapters also run a detail fixture with a short row and a
large sibling body. Selecting the short row must omit the sibling marker; its
directory entry carries length but no body text or hash; reading the large row
must reassemble its retained bytes from multiple bounded UTF-8 chunks; and
changing bytes must change the cursor version. Claude verifies duplicate
start/end timeline entries resolve once from the canonical activity; OpenCode
verifies the #318 parts/display schema, child sessions expanding at their Reader
position, a separate nested child body and deferred tool display lengths (the
directory reports zero, the first body page supplies the exact length); Codex
verifies duplicate activity references collapse to one row. Pi verifies the NUL thinking namespace, the
retired execution-error detail path, literal `foo:thinking` ids and the 256
UTF-16 identity boundary for overlong native ids.

The runtime replay additionally exercises the real `detail`/`body` scopes, a
24 MiB body across 385 bounded pages with one cached projection read, complete
chunk assembly, stale-cursor rejection and the explicit directory truncation
flag.

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


## SwiftUI / AppKit reading text comparison

This is a historical comparison. The SwiftUI migration has been reverted;
the measurements remain for reconsideration. The benchmark source and driver
are available in revision `39d0941`. To reproduce, use that revision in a
separately managed checkout
and rebuild its matching production modules before running:

```sh
swift build --package-path app/macos -c release -Xswiftc -enable-testing
python3 tools/verification/thread-detail-performance/swiftui-text.py
```

The second command owns the graphical replay lock and opens only isolated
fixture windows. It stages the current Release modules, so rebuild after product
changes. It runs 32 fresh foreground processes: four samples of each renderer,
fixture and scope, alternating A/B and B/A order. It does not send Harness tasks,
load user documents or fetch the fixture's inert example links.

The historical `SwiftUITextBenchmark.swift` uses that revision's production
parser and MarkdownContent/MarkdownReadingText, with the existing environment
switch selecting the original TextKit path or SwiftUI. Parsing precedes timing.
The Thread condition retains a finished content-reveal scope: it includes the
production row-host cost but no entrance animation or panel travel. This is a
renderer comparison, not an end-to-end Thread/FPS benchmark. CPU is process
user+system time; footprint is whole-process TASK_VM_INFO physical footprint.

Raw logs, launch receipts and executable/source identities are retained under
`.scratch/thread-swiftui-performance/<timestamp>`. A missing result, foreground
loss or timeout fails the sample rather than contributing a timing value.
[The measured results](swiftui-text-results.md) document the 2026-11-06 baseline,
including regressions and limits. These diagnostics are not a new CI threshold.
