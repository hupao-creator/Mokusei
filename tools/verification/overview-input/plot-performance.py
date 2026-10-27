"""Standalone paired comparison charts; run analyze-performance.py first.

Requires matplotlib. No inference of GPU work or rendered FPS is made.
"""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    result = json.loads((args.directory / "summary.json").read_text())
    if not result["rows"]:
        raise SystemExit("No measured conditions to plot; inspect readiness and run-status.json")
    metrics = [("cpuPercentOneCore", "Process CPU (% of one core)"),
               ("footprintMiBMedian", "Physical footprint (MiB)"),
               ("wakeLatenessP95Ms", "Main-actor wake lateness p95 (ms) — NOT frame time"),
               ("hostBusyPercent", "Whole-host CPU busy (% of all cores)")]
    for key, title in metrics:
        upper = max(r[key] for r in result["rows"]) * 1.15 or 1
        fig, axes = plt.subplots(1, 4, figsize=(12, 4.0 if result["smoke"] else 3.6), layout="constrained", sharey=True)
        for ax, group in zip(axes, result["groups"]):
            subset = [r for r in result["rows"] if r["appearance"] == group["appearance"] and r["scenario"] == group["scenario"]]
            for repetition in sorted({r["repetition"] for r in subset}):
                pair = {r["material"]: r for r in subset if r["repetition"] == repetition}
                if set(pair) != {"on", "off"}:
                    continue
                valid = all(r["valid"] for r in pair.values())
                ax.plot([0, 1], [pair["on"][key], pair["off"][key]],
                        marker="o" if valid else "x", color="#267c9c" if valid else "#b64b43", alpha=.65,
                        linestyle="-" if valid else "--", linewidth=1)
            ax.set_xticks([0, 1], ["glass on", "glass off"])
            ax.set_xlim(-.25, 1.25); ax.set_ylim(0, upper)
            ax.set_title(f'{group["appearance"]} · {group["scenario"]}\n{group["validPairs"]} valid pairs', fontsize=10)
            ax.grid(axis="y", alpha=.2)
            ax.spines[["right", "top"]].set_visible(False)
        prefix = ""
        if result["smoke"] or not result.get("comparisonValid", False):
            prefix = "DIAGNOSTIC — trial not valid for a performance conclusion\n"
        fig.suptitle(prefix + title + "\nEach line = one adjacent pair; red dashed = excluded by prespecified checks", fontsize=12)
        fig.savefig(args.directory / (key + ".svg"))
        fig.savefig(args.directory / (key + ".png"), dpi=180)
        plt.close(fig)


if __name__ == "__main__":
    main()
