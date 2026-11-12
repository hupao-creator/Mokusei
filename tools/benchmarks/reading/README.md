# External Agent Thread reading benchmark

This extension uses the [external benchmark framework](../README.md): a built,
signed production Release app, its bundled Runtime, the actually discovered
native Codex CLI, a deterministic loopback provider, and independent macOS
collectors. No product modules, private reader objects, database writes or native
session edits are used. Copy the entire `tools/benchmarks` directory to run it
outside the source checkout.

```sh
python3 tools/benchmarks/reading_benchmark.py conformance
python3 tools/benchmarks/reading_benchmark.py build --tools /private/tmp/reading-tools
python3 tools/benchmarks/reading_benchmark.py calibrate \
  --tools /private/tmp/reading-tools --output /private/tmp/reading-controls
python3 tools/benchmarks/reading_benchmark.py run \
  --app /absolute/path/Mokusei.app --tools /private/tmp/reading-tools \
  --capabilities /private/tmp/reading-controls --output /private/tmp/reading-run
python3 tools/benchmarks/reading_benchmark.py analyze \
  /private/tmp/reading-run/body-8-history-1/00-reading.first-open
```

Output directories must be new. Live work requires an unlocked foreground Mac,
Screen Recording, Accessibility and event-posting permission in the invoking
context. Run GUI experiments serially, including Overview experiments. Fixture
preparation and heavy compilation should finish before formal collection.
Keep profile and Runtime connection files private. Exit 2 describes unavailable,
incomplete or unsuccessful observation, not a statistical regression gate.

## Workloads and scenarios

The independent axes are a **single final reply** targeting 8 / 32 / 128 KiB and
**1 / 16 / 64 completed executions** at a fixed 8 KiB per reply. The overlapping
8 KiB / one-execution case is shared, yielding five fixture groups. Complete
Markdown blocks can exceed the target slightly; every plan records actual UTF-8
bytes, section count and SHA-256. The fixed block mix contains paragraphs,
Chinese/English text, headings, inline styles, lists, Swift code, tables and a
blockquote. Business checkpoints are part of the declared document.
The shared scenario requests a fixed 1280 × 820-point window. One execution is
the baseline, 16 directory marks fit the viewport, and 64 require scrolling and
cross the directory's mounted window; these are not invented pagination sizes.

The Agent reader mounts the current or selected execution, rather than all
stored history. History count exercises the directory and navigation; its total
stored bytes are never reported as visible body bytes. The directory virtualizes
its marks and currently does not page the manifest. The ordinary Agent document
does not load preceding executions when its body reaches the top.

| Scenario | Timed work |
| --- | --- |
| `reading.first-open` | After a fresh process reaches Overview, click the existing card; observe recognizable body checkpoints and a later scheduled scroll probe. Fixture creation and application startup are outside this timer. |
| `reading.reopen` | Return to Overview and click the same existing card in the retained application process. |
| `reading.scroll` | Fixed-clock pixel-wheel input alternates down/up, with explicit pauses between gestures. |
| `reading.history` | Supply five fixed directory scroll gestures (1800 points), click its oldest execution, then probe that document with system scrolling. One-execution groups have no older history and omit this case. The formal interval is 17 seconds; other scenarios use 10 seconds. |
| `reading.output-scroll` | Read and scroll the existing completed document while a subsequent real execution emits complete, meaningful progress replies, then a final document. This case runs last because it changes execution history. |

Preparation may read public semantic state, locate actual accessibility controls
and reset a starting scroll position. Formal intervals do not poll complete
semantic snapshots or invoke internal scroll setters. The scheduled wheel
events use [Core Graphics pixel scrolling](https://developer.apple.com/documentation/coregraphics/cgeventfield/scrollwheeleventiscontinuous),
with explicit began/changed/ended phases and no synthetic momentum. This is not
a claim about physical trackpad fidelity.

History preparation scrolls the public directory to its beginning to observe the
oldest mark's Accessibility hit point, then restores its end with system input.
The selected document remains the latest execution; the oldest document is not
opened during preparation. Both positions and preparatory input receipts are
retained. Timed navigation uses only wheel input and a click, so it does not
depend on keyboard focus restoration in the production window.

Assistant fragments are intentionally hidden by the ordinary Agent reader until
their message settles. The source therefore records fragments and completed
message boundaries separately. A fragment is not a rendered frame. The default
output describes eight review stages over ten seconds, followed by the complete
final reply. These are declared experimental workloads, not average user rates.
Full final replies are verified through the public scoped content subscription;
the bounded Overview summary cannot establish full-document delivery.
Before dynamic timing, preparation re-enters the running thread through its
normal entry behavior and confirms both the completed document and active
execution are mounted. A background follow-up alone does not reveal a folded
execution sidecard in an already mounted reader.

## Measurements and evidence

The report retains entry-to-recognizable-content intervals, a scheduled usability
upper bound, each scroll segment's first visible-response interval, direction,
observed displacement, frame correspondence and longest observed no-progress
interval. History navigation measures the selected old document's appearance;
unlabelled directory marks do not establish optical frame rate. Dynamic cases
also report source completion to observed checkpoint latency where the checkpoint
is visible. Offscreen updates are not silently credited as rendered work.

Shared collectors record App/Runtime/helper CPU deltas and **sampled** physical
footprint with separate collector/source roles. PNG request/return intervals and
OCR coordinates provide sampled pixel evidence, not physical display FPS.
First-content and input-response timing cannot be more precise than capture
coverage. Incomplete correspondence is unavailable, not a zero-millisecond
response. A quiet interval with no planned scrolling is not a freeze.
No-progress durations also retain lower/upper bounds. An upper bound crossing
the progress oracle's budget is not enough to establish a stall; the lower bound
must cross it. The sampling interval is never silently treated as product delay.
A wholly inert product probe cannot distinguish a blocked input target from a
frozen reader; it reports unknown input acceptance/responsiveness. The independent
frozen control still verifies that the optical scorer detects absent progress.

The shared native hitch collector must pass its own positive/negative/ownership
controls before a zero value can support a no-hitch conclusion. The separate
reading controls establish scrolling input and pixel analysis only; they do not
certify hitch capability. Missing short-lived descendant/exit CPU accounting
prevents a complete application-task resource claim. These limitations remain
visible independently of business correctness.

Every trial retains the source plan, content manifest, public preparation and
outcome, input/source ledgers, process identities, raw captures/OCR, collector
result, cleanup and evidence manifest. Measurement state, product outcome and
comparison remain separate. There is no total score or statistical performance
regression gate. The older backend detail probe has a different boundary and
must not be pooled with these measurements.

The suite's `summary.md` puts body appearance and scroll response bounds first,
then observed App CPU and sampled memory. JSON retains every segment and raw
evidence reference. A single trial is not a confidence interval or an estimate
of typical user latency; repeat separate runs before comparing versions.

## Verification

Portable conformance sends real HTTP/SSE requests to the production benchmark
provider and invokes the shared offline scorer. Controls include frozen pixels,
wrong scroll direction, a different execution, missing business text/input,
altered content hashes, malformed gesture phases and changed input volume.
These establish framework behavior; they do not establish macOS rendering.

Live calibration builds an independent AppKit scroll window with normal, frozen,
reversed, delayed and real main-thread-stall behaviors. It uses the same system
input, capture and analysis path as the product. Keep failed controls and product
trials; inspect the raw frames before changing an oracle. The signed production
experiment is a distinct verification step from portable CI conformance.

The native control also retains the pixel deltas actually received by AppKit
and its own settled document offset. Calibration requires these input totals to
match the plan and the independent offsets to agree with optical displacement.
AppKit can add settling travel after a complete gesture, so input pixels are a
declared minimum travel workload, not an exact endpoint. Reports retain actual
travel; insufficient travel still fails with the same 24-point optical budget.
Only the independent control exposes this receiver geometry; the product's
timed measurements continue to use external pixels.
