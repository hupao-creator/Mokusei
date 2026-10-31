# Fixed S4 Core execution-trace diagnostic

This isolated diagnostic follows the completed single-build staged-path control.
That control retained five source-enqueue failures among eight cells, including
both same-path pairs. In several source peaks, production publication and source
enqueue resumed within microseconds of each other; some UI installations still
occurred during the gap. Existing receipts do not distinguish timer wakeup, Go
scheduling, GC, locks, Cgo or operating-system scheduling.

The diagnostic builds fixed product
`69c30b9a3356ca3a5c9a4de9ce78f1b683960125` once and runs one S4 process with N40,
four visible running cards, five seconds of warmup and twenty seconds of input at
40 events/s. The original thirteen Swift/Go/Python inputs must first match
`7da390645f45624de3f8e77da8472387bb292e9c92c5544de8c59812917e7254`.
An explicit, SHA-checked manifest then overlays three Go harness files and adds
the diagnostic helper plus its tests. The effective instrumented harness is
hashed separately. Product, Swift probe, publisher policy and all original
measurement validators remain unchanged. The trace workflow is on its own
diagnostic branch and does not modify PR #200's formal harness.

`MOKUSEI_OVERVIEW_CORE_TRACE_PATH` is forwarded as a named LaunchServices
environment override and inherited by the owned Go child. No whole environment
is included in the artifact. `core.trace.json` retains only the trace settings
and explicitly named Go runtime policy variables. No QoS, App Nap, GOGC,
GOMAXPROCS or memory-limit policy is set by the driver.

The Go trace covers goroutine states, synchronization, syscall/Cgo and GC/STW
events, with narrow source/worker/publication markers and raw-clock brackets.
After the original run and owned-process cleanup, the driver decodes it using
the same Go toolchain (`go tool trace -d=parsed`) and creates scheduler,
synchronization and syscall profiles. Their accumulated times are not process
CPU percentages. Trace, raw source/model receipts, package signatures and every
original measurement failure remain in one artifact.

## Reading the result

`captureComplete` and the original `run.valid` answer different questions.
A workflow can successfully collect a complete trace of an invalid source run;
it still reports that source failure and does not certify formal performance.
Trace overflow, writer errors, missing final receipts or failed decoding make
the diagnostic incomplete. There is no automatic retry or hidden second run.

Instrumentation and its bounded memory buffer have real overhead and can move
GC thresholds or scheduling. Its CPU results are diagnostic only and must not
be paired with uninstrumented baseline rows. If no source spike reproduces, this
run cannot rule out a cause in earlier runs.

For a reproduced spike:

- GC attribution requires actual stop-the-world time overlapping the source
  gap; a long concurrent GC cycle alone does not establish a global pause.
- Queue-lock attribution requires a timely wait return followed by a measured
  long lock wait and a corresponding trace path.
- Runtime scheduling attribution requires the producer to be runnable while
  other Go work progresses, with its eventual running transition retained.
- An interval without Core runtime progress cannot alone identify OS scheduling
  or effective QoS. That specific ambiguity may justify a separate System Trace
  capability check; it does not justify changing priority or disabling GC.

The same raw `CLOCK_UPTIME_RAW` receipts bind source and model events. Trace
markers have independent before/after brackets so they are not aligned using
UTC or an assumed process-start offset.

References: [Go execution tracer](https://pkg.go.dev/runtime/trace),
[Go trace tool](https://pkg.go.dev/cmd/trace).

## Invocation

```sh
python3 tools/verification/overview-ci-performance/core_trace.py \
  --output /tmp/overview-core-trace --configure-display \
  --time-budget-seconds 1200
```

Display configuration is permitted only on a disposable GitHub Actions runner,
using an existing supported mode and restoring it during cleanup. The single
run retains the original foreground, visibility, source-rate, 50ms enqueue,
raw-clock, CPU-boundary and five-second tail contracts. It is not an A/B matrix,
an optimization or a replacement for the required `Complete coverage` check.
