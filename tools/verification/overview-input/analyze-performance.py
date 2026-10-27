"""Summarize raw glass samples without treating scheduling probes as frames."""
import argparse
import csv
import json
from pathlib import Path
import statistics

from performance_support import interfering_process


def percentile(values, fraction):
    values = sorted(values)
    position = (len(values) - 1) * fraction
    low = int(position)
    return values[low] + (values[min(low + 1, len(values) - 1)] - values[low]) * (position - low)


def analyze(directory):
    metadata = json.loads((directory / "metadata.json").read_text())
    monitor = [json.loads(line) for line in (directory / "host-processes.jsonl").read_text().splitlines()]
    rows = []
    raw_samples = {}
    protocol_errors = []
    expected_names = []
    for repetition in range(metadata["repetitions"]):
        for dark in ([False, True] if repetition % 2 == 0 else [True, False]):
            for dynamic in ([False, True] if repetition % 2 == 0 else [True, False]):
                for glass in ([True, False] if repetition % 2 == 0 else [False, True]):
                    expected_names.append(f'r{repetition + 1}-{"dark" if dark else "light"}-{"pan-zoom" if dynamic else "static"}-{"on" if glass else "off"}')
    if metadata["repetitions"] != (1 if metadata["smoke"] else 4) or metadata["sampleSeconds"] != (2 if metadata["smoke"] else 12):
        protocol_errors.append("unexpected-repetition-or-sample-length")
    for path in sorted(directory.glob("r[0-9]*-*.json")):
        sample = json.loads(path.read_text())
        expected_name = f'r{sample["repetition"]}-{"dark" if sample["dark"] else "light"}-{"pan-zoom" if sample["dynamic"] else "static"}-{"on" if sample["glassWorld"] else "off"}'
        if sample["name"] != expected_name or path.stem != expected_name or expected_name not in expected_names or expected_name in raw_samples:
            raise ValueError(f"Invalid or duplicate condition identity: {path.name}")
        raw_samples[sample["name"]] = sample
        resources = sample["resources"]
        first, last = resources[0], resources[-1]
        seconds = (int(last["uptimeNs"]) - int(first["uptimeNs"])) / 1e9
        cpu_seconds = last["userSeconds"] + last["systemSeconds"] - first["userSeconds"] - first["systemSeconds"]
        ticks = [(b - a) % 2**32 for a, b in zip(first["hostCPUTicks"], last["hostCPUTicks"])]
        if seconds <= 0 or cpu_seconds < 0 or sum(ticks) == 0:
            raise ValueError(f"Invalid resource interval: {path.name}")
        host_busy = 100 * (sum(ticks) - ticks[2]) / sum(ticks)
        wake = sample["wakeLatenessMs"]
        period = 1000 / sample["heartbeatHz"]
        invalid = list(sample["invalidReasons"])
        frequency = 60 if sample["dynamic"] else 20
        steps = metadata["sampleSeconds"] * frequency
        actions = steps if sample["dynamic"] else 0
        if (sample["heartbeatHz"] != frequency or len(wake) != steps or
                sample["expectedActions"] != actions or sample["deliveredActions"] != actions or
                len(resources) != 1 + metadata["sampleSeconds"] * 4 or
                len(sample["sampledCameras"]) != metadata["sampleSeconds"] * 4 or
                seconds < metadata["sampleSeconds"]):
            invalid.append("incomplete-or-different-workload")
        # Prespecified before collection: reject serious thermal pressure, heavily
        # loaded host, competing native replay/build, and disrupted action timing.
        if max(r["thermalState"] for r in resources) >= 2:
            invalid.append("serious-thermal-pressure")
        if host_busy > 40:
            invalid.append("host-busy-over-40-percent")
        late = sum(value > period for value in wake)
        if max(wake) > 250 or late / len(wake) > 0.05:
            invalid.append("disrupted-scheduling")
        competing = set()
        for snapshot in monitor:
            if not first["unix"] <= snapshot["unix"] <= last["unix"]:
                continue
            for process in snapshot["processes"]:
                if interfering_process(process, metadata["pid"]):
                    competing.add(process["name"])
        if competing:
            invalid.append("competing-build-or-native-replay:" + ",".join(sorted(competing)))
        rows.append({
            "name": sample["name"], "appearance": "dark" if sample["dark"] else "light",
            "scenario": "pan-zoom" if sample["dynamic"] else "static", "material": "on" if sample["glassWorld"] else "off",
            "repetition": sample["repetition"], "valid": not invalid, "invalidReasons": ";".join(dict.fromkeys(invalid)),
            "cpuPercentOneCore": 100 * cpu_seconds / seconds,
            "footprintMiBMedian": statistics.median(r["physicalFootprintBytes"] for r in resources) / 2**20,
            "footprintMiBPeak": max(r["physicalFootprintBytes"] for r in resources) / 2**20,
            "rssMiBMedian": statistics.median(r["residentBytes"] for r in resources) / 2**20,
            "wakeLatenessP95Ms": percentile(wake, .95), "wakeLatenessMaxMs": max(wake),
            "wakeLatenessOverPeriodCount": late, "wakeLatenessOver50msCount": sum(v > 50 for v in wake),
            "hostBusyPercent": host_busy, "seconds": seconds,
            "deliveredActions": sample["deliveredActions"], "expectedActions": sample["expectedActions"],
        })
    chronological = sorted(raw_samples.values(), key=lambda s: s["resources"][0]["unix"])
    if [s["name"] for s in chronological] != expected_names[:len(chronological)]:
        protocol_errors.append("condition-order-mismatch")
    for before, after in zip(chronological, chronological[1:]):
        if before["resources"][-1]["unix"] >= after["resources"][0]["unix"]:
            protocol_errors.append("overlapping-condition-intervals")
    missing = sorted(set(expected_names) - raw_samples.keys())
    if (directory / "external-interference.json").exists():
        protocol_errors.append("external-interference-detected")
    if metadata.get("schema", 1) >= 2:
        status_file, result_file = directory / "run-status.json", directory / "result.txt"
        status = json.loads(status_file.read_text()) if status_file.exists() else {}
        if status.get("phase") != "collected" or status.get("error"):
            protocol_errors.append("driver-did-not-complete")
        if not result_file.exists() or not result_file.read_text().startswith("PASS "):
            protocol_errors.append("native-replay-did-not-pass")
        warmups = directory / "warmups"
        expected_warmups = {name + ".json" for name in expected_names} | {"initial-on.json", "initial-off.json"}
        if {p.name for p in warmups.glob("*.json")} != expected_warmups:
            protocol_errors.append("warmup-coverage-mismatch")
        for path in warmups.glob("*.json"):
            if json.loads(path.read_text())["invalidReasons"]:
                protocol_errors.append("invalid-warmup:" + path.name)
        powers = [directory / "power-start.txt", directory / "power-end.txt"]
        if not all(p.exists() for p in powers):
            protocol_errors.append("power-observations-missing")
        elif powers[0].read_text().splitlines()[0] != powers[1].read_text().splitlines()[0]:
            protocol_errors.append("power-source-changed")
    groups = []
    for appearance in ["light", "dark"]:
        for scenario in ["static", "pan-zoom"]:
            subset = [r for r in rows if r["appearance"] == appearance and r["scenario"] == scenario]
            pairs = []
            for repetition in range(1, metadata["repetitions"] + 1):
                pair = {r["material"]: r for r in subset if r["repetition"] == repetition}
                if set(pair) != {"on", "off"}:
                    for row in pair.values():
                        row["includedInPair"] = False
                    continue
                on, off = pair["on"], pair["off"]
                a, b = raw_samples[on["name"]], raw_samples[off["name"]]
                # The camera path is independent of time/CPU: equal logical inputs
                # and sampled transforms must reach equal production constraints.
                for key in ["cameraStart", "cameraEnd", "sampledCameras", "mounted", "appearances", "sceneSnapshotCount", "windowFrame", "pointerStart", "pointerEnd"]:
                    if key not in a or key not in b or a[key] != b[key]:
                        for row in [on, off]:
                            row["valid"] = False
                            row["invalidReasons"] += f";pair-oracle-mismatch:{key}"
                included = on["valid"] and off["valid"]
                on["includedInPair"] = included; off["includedInPair"] = included
                if included:
                    pairs.append(pair)
            metrics = {}
            for metric in ["cpuPercentOneCore", "footprintMiBMedian", "rssMiBMedian", "wakeLatenessP95Ms", "hostBusyPercent"]:
                if not pairs:
                    metrics[metric] = None
                    continue
                on = [pair["on"][metric] for pair in pairs]
                off = [pair["off"][metric] for pair in pairs]
                delta = [b - a for a, b in zip(on, off)]
                metrics[metric] = {"onMedian": statistics.median(on), "offMedian": statistics.median(off),
                    "onRange": [min(on), max(on)], "offRange": [min(off), max(off)],
                    "pairedOffMinusOnMedian": statistics.median(delta), "pairedDeltaRange": [min(delta), max(delta)],
                    "pairedDeltaPercentMedian": statistics.median([(b - a) / a * 100 for a, b in zip(on, off)]) if all(on) else None}
            groups.append({"appearance": appearance, "scenario": scenario, "validPairs": len(pairs), "metrics": metrics})
    native_files = sorted((directory / "native").glob("*.jsonl"))
    native_end = []
    for path in native_files:
        native_end += [r for r in (json.loads(line) for line in path.read_text().splitlines()) if r["kind"] == "sessionEnd"]
    native_healthy = bool(native_end) and all(not r["dropped"] and not r["truncated"] and not r["writeFailed"] for r in native_end)
    host_errors = sorted({r["error"] for r in monitor if r["error"]})
    valid = not missing and not protocol_errors and native_healthy and not host_errors and all(r["valid"] for r in rows)
    return {"schema": 2, "smoke": metadata["smoke"], "nativeRecorderHealthy": native_healthy,
        "complete": not missing, "missingConditions": missing, "protocolErrors": sorted(set(protocol_errors)),
        "validTrial": valid, "comparisonValid": valid and not metadata["smoke"], "hostMonitorErrors": host_errors,
        "missingMetrics": metadata["missingMetrics"], "rows": rows, "groups": groups}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    result = analyze(args.directory)
    (args.directory / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    if result["rows"]:
        with (args.directory / "samples.csv").open("w") as handle:
            writer = csv.DictWriter(handle, fieldnames=result["rows"][0].keys())
            writer.writeheader(); writer.writerows(result["rows"])
    lines = [f'Comparison valid: **{result["comparisonValid"]}**; complete: {result["complete"]}; smoke: {result["smoke"]}.', "",
             "| Appearance / scenario | Valid pairs | CPU on → off (% one core) | Footprint on → off (MiB) | Wake lateness p95 on → off (ms; NOT frame time) |", "| --- | ---: | ---: | ---: | ---: |"]
    for group in result["groups"]:
        cells = []
        for key in ["cpuPercentOneCore", "footprintMiBMedian", "wakeLatenessP95Ms"]:
            metric = group["metrics"][key]
            cells.append(f'{metric["onMedian"]:.2f} → {metric["offMedian"]:.2f}' if metric else "missing")
        lines.append(f'| {group["appearance"]} / {group["scenario"]} | {group["validPairs"]} | ' + " | ".join(cells) + " |")
    (args.directory / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    invalid = [r for r in result["rows"] if not r["valid"]]
    print(f'{len(invalid)} invalid samples; native recorder healthy={result["nativeRecorderHealthy"]}')
    for row in invalid:
        print(row["name"], row["invalidReasons"])
    if not result["validTrial"]:
        print("Missing conditions:", result["missingConditions"], "Protocol errors:", result["protocolErrors"])
        raise SystemExit("Trial invalid/incomplete; retained summaries are diagnostic, not a valid comparison")


if __name__ == "__main__":
    main()
