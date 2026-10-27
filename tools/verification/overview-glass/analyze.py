"""Analyze retained three-condition trials without selecting away self-induced overload."""
import argparse
import json
from pathlib import Path
import statistics
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "overview-input"))
from performance_support import interfering_process as inherited_interference

CONDITIONS = [
    ["all-on", "shell-off", "all-off"], ["all-off", "shell-off", "all-on"],
    ["shell-off", "all-on", "all-off"], ["all-off", "all-on", "shell-off"],
    ["shell-off", "all-off", "all-on"], ["all-on", "all-off", "shell-off"],
]
METRICS = ["cpuPercentOneCore", "footprintMiB", "rssMiB", "wakeLatenessP95MsNotFrameTime"]


def interfering_process(process, own_pid):
    return process["name"].strip().lower() != "replayd" and inherited_interference(process, own_pid)


def percentile(values, fraction):
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    return ordered[lower] + (ordered[min(lower + 1, len(ordered) - 1)] - ordered[lower]) * (position - lower)


def analyze(directory):
    errors, rows, samples = [], [], {}
    metadata_path = directory / "metadata.json"
    if not metadata_path.exists():
        return {"comparisonValid": False, "errors": ["no-mounted-fixture-metadata"], "rows": [], "pairs": []}
    metadata = json.loads(metadata_path.read_text())
    stage = metadata.get("stage")
    if stage not in ["baseline", "extended"]:
        errors.append("unknown-stage")
    scenarios = ["idle", "pan"] if stage == "baseline" else ["zoom", "refresh"]
    if (metadata.get("schema") != 2 or metadata.get("repetitions") != 6 or
            metadata.get("sampleSeconds") != 12 or metadata.get("reduceTransparency") or
            metadata.get("count") not in [1, 5, 12, 30]):
        errors.append("protocol-metadata-mismatch")
    expected = [f"r{r + 1}-{s}-{c}" for r in range(6)
                for s in (scenarios if r % 2 == 0 else list(reversed(scenarios)))
                for c in CONDITIONS[r]]
    monitor_path = directory / "host-processes.jsonl"
    monitor = [json.loads(line) for line in monitor_path.read_text().splitlines()] if monitor_path.exists() else []
    if not monitor or any(s.get("error") for s in monitor):
        errors.append("missing-or-failed-host-monitor")
    for path in directory.glob("r[0-9]*-*.json"):
        sample = json.loads(path.read_text())
        name = sample.get("name")
        if (name not in expected or path.stem != name or name in samples or
                name != f'r{sample.get("repetition")}-{sample.get("scenario")}-{sample.get("condition")}'):
            errors.append("condition-identity-mismatch:" + path.name)
            continue
        resources, wake = sample["resources"], sample["wakeLatenessMs"]
        if len(resources) < 2:
            errors.append("missing-resource-samples:" + name)
            continue
        samples[name] = sample
        a, b = resources[0], resources[-1]
        seconds = (int(b["uptimeNs"]) - int(a["uptimeNs"])) / 1e9
        frequency = 60 if sample["scenario"] in ["pan", "zoom"] else 20
        actions = 720 if frequency == 60 else 0
        refreshes = 120 if sample["scenario"] == "refresh" else 0
        invalid = list(sample["invalidReasons"])
        if (not 12 <= seconds <= 12.5 or len(resources) != 49 or len(wake) != 12 * frequency or
                sample.get("heartbeatHz") != frequency or sample.get("deliveredActions") != actions or
                sample.get("expectedActions") != actions or sample.get("refreshActions") != refreshes or
                not 0 <= sample.get("catchUpSteps", -1) <= len(wake) or
                len(sample.get("mounted", [])) != metadata["count"] or
                len(sample.get("sampledCameras", [])) != 48):
            invalid.append("workload-or-interval-mismatch")
        ticks = [(y - x) % 2**32 for x, y in zip(a["hostCPUTicks"], b["hostCPUTicks"])]
        tick_total = sum(ticks)
        host_busy = 100 * (tick_total - ticks[2]) / tick_total if tick_total else None
        if host_busy is None:
            invalid.append("missing-host-cpu-ticks")
        relevant = [s for s in monitor if a["unix"] <= s["unix"] <= b["unix"]]
        known_external = any(interfering_process(p, metadata["pid"]) for s in relevant for p in s["processes"])
        if not relevant:
            invalid.append("missing-host-monitor-interval")
        if known_external:
            invalid.append("known-external-process")
        cpu = b["userSeconds"] + b["systemSeconds"] - a["userSeconds"] - a["systemSeconds"]
        if cpu < 0 or seconds <= 0:
            raise ValueError("Invalid CPU interval: " + name)
        cpu_percent = 100 * cpu / seconds
        late = sum(v > 1000 / frequency for v in wake)
        overload = (host_busy is not None and host_busy > 40) or max(wake, default=0) > 250 or late > len(wake) * .05
        # Own process CPU can account for whole-host load only above the threshold
        # after division by logical CPU count. GPU/WindowServer attribution remains unknown.
        own_cpu_sufficient = cpu_percent / metadata.get("cpuCount", 1) > 40
        overload_origin = ("known-external" if known_external else
                           "self-cpu-sufficient" if own_cpu_sufficient else "unattributed") if overload else "none"
        rows.append({"name": name, "scenario": sample["scenario"], "condition": sample["condition"],
            "repetition": sample["repetition"], "invalidReasons": invalid,
            "cpuPercentOneCore": cpu_percent,
            "footprintMiB": statistics.median(r["physicalFootprintBytes"] for r in resources) / 2**20,
            "footprintPeakMiB": max(r["physicalFootprintBytes"] for r in resources) / 2**20,
            "rssMiB": statistics.median(r["residentBytes"] for r in resources) / 2**20,
            "wakeLatenessP95MsNotFrameTime": percentile(wake, .95) if wake else 0,
            "wakeLatenessMaxMsNotFrameTime": max(wake, default=None),
            "catchUpSteps": sample.get("catchUpSteps"),
            "actionCallsPerSecondNotFPS": sample["deliveredActions"] / seconds,
            "refreshCallsPerSecondNotDisplayedFrames": sample["refreshActions"] / seconds,
            "finalRefreshRevisionObserved": sample.get("observedRefreshTick") == refreshes if refreshes else None,
            "hostBusyPercent": host_busy, "seriousThermalPressure": sample.get("seriousThermalPressure"),
            "overloadObserved": overload, "overloadOrigin": overload_origin})
    chronological = sorted(samples, key=lambda n: samples[n]["resources"][0]["unix"])
    if chronological != expected:
        errors.append("missing-or-out-of-order-conditions")
    for x, y in zip(chronological, chronological[1:]):
        if samples[x]["resources"][-1]["unix"] >= samples[y]["resources"][0]["unix"]:
            errors.append("overlapping-conditions")
    warmups = directory / "warmups"
    if {p.stem for p in warmups.glob("*.json")} != set(expected):
        errors.append("warmup-coverage-mismatch")
    for path in warmups.glob("*.json"):
        if json.loads(path.read_text())["invalidReasons"]:
            errors.append("invalid-warmup:" + path.stem)
    status = directory / "run-status.json"
    if not status.exists() or json.loads(status.read_text()).get("phase") != "collected":
        errors.append("driver-incomplete")
    result = directory / "result.txt"
    if not result.exists() or not result.read_text().startswith("PASS "):
        errors.append("native-incomplete")
    if (directory / "external-interference.json").exists():
        errors.append("external-interference")
    power = [directory / "power-start.txt", directory / "power-end.txt"]
    if not all(p.exists() for p in power) or power[0].read_text().splitlines()[0] != power[1].read_text().splitlines()[0]:
        errors.append("missing-or-changed-power-source")
    ends = [json.loads(line) for p in (directory / "native").glob("*.jsonl") for line in p.read_text().splitlines()
            if json.loads(line).get("kind") == "sessionEnd"]
    if not ends or any(e["dropped"] or e["truncated"] or e["writeFailed"] for e in ends):
        errors.append("native-recorder-unhealthy")
    pairs = []
    for scenario in scenarios:
        for repetition in range(1, 7):
            group = {r["condition"]: r for r in rows if r["scenario"] == scenario and r["repetition"] == repetition}
            if set(group) != set(CONDITIONS[0]):
                continue
            reference = samples[group["all-on"]["name"]]
            for condition in ["shell-off", "all-off"]:
                candidate = samples[group[condition]["name"]]
                for key in ["cameraStart", "cameraEnd", "sampledCameras", "mounted", "appearances",
                            "sceneSnapshotCount", "windowFrame", "pointerStart", "pointerEnd", "refreshActions"]:
                    if reference.get(key) != candidate.get(key):
                        group["all-on"]["invalidReasons"].append("pair-oracle:" + key)
                        group[condition]["invalidReasons"].append("pair-oracle:" + key)
            for left, right in [("all-on", "shell-off"), ("shell-off", "all-off"), ("all-on", "all-off")]:
                a, b = group[left], group[right]
                pairs.append({"scenario": scenario, "repetition": repetition, "left": left, "right": right,
                    "valid": not a["invalidReasons"] and not b["invalidReasons"],
                    "rightMinusLeft": {key: b[key] - a[key] for key in METRICS},
                    "overloadObserved": a["overloadObserved"] or b["overloadObserved"]})
    spread = {}
    for scenario in scenarios:
        for left, right in [("all-on", "shell-off"), ("shell-off", "all-off"), ("all-on", "all-off")]:
            group = [p for p in pairs if p["scenario"] == scenario and p["left"] == left and p["right"] == right and p["valid"]]
            if group:
                spread[f"{scenario}:{left}->{right}"] = {key: {"median": statistics.median(p["rightMinusLeft"][key] for p in group),
                    "min": min(p["rightMinusLeft"][key] for p in group),
                    "max": max(p["rightMinusLeft"][key] for p in group)} for key in METRICS}
    valid = not errors and len(pairs) == 18 * len(scenarios) and all(p["valid"] for p in pairs)
    return {"comparisonValid": valid, "count": metadata.get("count"), "stage": stage,
            "errors": sorted(set(errors)), "rows": rows, "pairs": pairs, "pairedSpread": spread}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    summary = analyze(args.directory)
    (args.directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k not in ["rows", "pairs"]}, indent=2))
    sys.exit(0 if summary["comparisonValid"] else 1)
