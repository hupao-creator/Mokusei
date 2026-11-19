# Overview internal CPU probe

This probe links optimized production objects and creates synthetic catalog data
in an isolated temporary profile. It launches no GUI, Runtime, provider or model.
The producer supplies fixed completed snapshots; no running/completed/title
oscillation is a rendering workload. The standalone [external benchmark](../../benchmarks/README.md)
measures complete-app fixed-count rendering instead.

```sh
python3 tools/verification/overview-performance/run.py build --label baseline
python3 tools/verification/overview-performance/run.py build --label candidate
python3 tools/verification/overview-performance/run.py measure --labels baseline,candidate --output /private/tmp/overview-cpu --repetitions 5
```

The builder links current Release objects with `-enable-testing` to expose
internal types; it does not create or run a Swift test target. The driver keeps
binary/source identity and rejects obsolete workload binaries. Finish both
builds before measurement. AB/BA repetitions use fresh processes, retaining raw
samples, environment and process-load observations. Preparation/output are
outside the timed operations; native scheduling and background work remain
measurement limitations.

The current workload covers fresh model admission, unchanged catalog admission,
projection/reconciliation, filters and the pure layout solver. It uses three
untimed warmups and repeated operations. Monotonic elapsed latency is not
rendered frame time; process CPU is recorded separately. No performance
regression threshold or visible-frame/correctness gate is configured here.

[Recorded results](RESULTS.md) and their source manifests describe only their
identified builds. Baseline revisions must exist locally and be compatible with
the same fixture. Do not pool them with external rendering/CI measurements.
