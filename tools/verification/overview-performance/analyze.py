"""Summarize repeated CPU-path samples; renderer/GPU metrics are intentionally absent."""
import argparse
import json
from pathlib import Path
import statistics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    root = args.directory
    observations = json.loads((root / "observations.json").read_text())
    rows = {}
    exclusions = []
    for observation in observations:
        data = json.loads((root / observation["file"]).read_text())
        reasons = set()
        if max(data["initialThermalState"], data["thermalState"]) >= 2:
            reasons.add("serious/critical thermal state")
        for activity in observation["activity"]:
            for line in activity["processes"].splitlines()[1:]:
                parts = line.split(maxsplit=2)
                if len(parts) != 3 or int(parts[0]) == data["pid"]:
                    continue
                cpu, name = float(parts[1]), parts[2].strip().lower()
                if cpu > 1 and any(token in name for token in (
                        "swift-frontend", "clang", "compile", "xctest", "replay", "probe")):
                    reasons.add("concurrent compiler/test/probe: " + name)
        if reasons:
            exclusions.append({"file": observation["file"], "reasons": sorted(reasons)})
        for record in data["records"]:
            if "elapsedMs" not in record:
                continue
            key = (record["scenario"], record["count"])
            rows.setdefault(key, {}).setdefault(observation["label"], []).append({
                "repetition": observation["repetition"], "medianMs": statistics.median(record["elapsedMs"]),
                "maxMs": max(record["elapsedMs"]), "valid": not reasons})
    labels = list(dict.fromkeys(item["label"] for item in observations))
    result = []
    lines = ["# Overview CPU-path measurements", "", "Milliseconds; median of process medians [range].",
             "Not frame latency, application FPS or GPU time.", "",
             "| Scenario / cards | " + " | ".join(labels) + " | Paired change |",
             "| --- | " + " | ".join("---:" for _ in labels) + " | ---: |"]
    for (scenario, count), values in rows.items():
        cells = []
        for label in labels:
            usable = [sample["medianMs"] for sample in values.get(label, []) if sample["valid"]]
            cells.append(f"{statistics.median(usable):.3f} [{min(usable):.3f}, {max(usable):.3f}]" if usable else "excluded")
        deltas = []
        if len(labels) == 2:
            left = {sample["repetition"]: sample for sample in values.get(labels[0], [])}
            for right in values.get(labels[1], []):
                before = left.get(right["repetition"])
                if before and before["valid"] and right["valid"] and before["medianMs"] > 0:
                    deltas.append(100 * (right["medianMs"] / before["medianMs"] - 1))
        change = f"{statistics.median(deltas):+.1f}% ({len(deltas)} pairs)" if deltas else "—"
        lines.append(f"| {scenario} / {count} | " + " | ".join(cells) + f" | {change} |")
        result.append({"scenario": scenario, "count": count, "samples": values, "pairedPercentChanges": deltas})
    lines += ["", "Exclusions (raw samples retained):", "", *[f"- {x['file']}: {', '.join(x['reasons'])}" for x in exclusions]]
    if not exclusions:
        lines.append("None detected by the sampled compiler/test and thermal gates. Other system activity remains uncontrolled.")
    (root / "summary.md").write_text("\n".join(lines) + "\n")
    (root / "summary.json").write_text(json.dumps({"labels": labels, "rows": result, "exclusions": exclusions}, indent=2))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
