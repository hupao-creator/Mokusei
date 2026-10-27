"""Plot the three independent paired CPU experiments (requires matplotlib)."""
import json
from pathlib import Path
import statistics

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def main():
    evidence = Path(__file__).resolve().parent / "evidence"
    panels = [
        ("round1", "status-update", "Content-only update", "c17a3fcb", "88e580f2"),
        ("round2", "fresh-model", "Fresh model: scope partition", "88e580f2", "eb7478cb"),
        ("round3", "fresh-model", "Fresh model: tag normalization", "eb7478cb", "0025ff09"),
    ]
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10, "svg.fonttype": "none",
                         "svg.hashsalt": "overview-cpu-rounds-v1"})
    figure, axes = plt.subplots(1, 3, figsize=(11.8, 5.1))
    for axis, (directory, scenario, title, before_sha, after_sha) in zip(axes, panels):
        result = json.loads((evidence / directory / "summary.json").read_text())
        row = next(row for row in result["rows"] if row["scenario"] == scenario and row["count"] == 500)
        before, after = result["labels"]
        left = {sample["repetition"]: sample for sample in row["samples"][before]}
        pairs = [(left[sample["repetition"]]["medianMs"], sample["medianMs"])
                 for sample in row["samples"][after]
                 if sample["valid"] and left[sample["repetition"]]["valid"]]
        if len(pairs) != 5:
            raise ValueError("This report figure requires all five prespecified pairs")
        for pair in pairs:
            axis.plot([0, 1], pair, color="#97a6b3", linewidth=1, alpha=.65, marker="o", markersize=3)
        medians = [statistics.median(pair[index] for pair in pairs) for index in [0, 1]]
        axis.scatter([0, 1], medians, c=["#566574", "#147969"], s=65, zorder=5)
        for index, median in enumerate(medians):
            axis.annotate(f"{median:.2f} ms", (index, median), xytext=(0, 15),
                          textcoords="offset points", ha="center", fontsize=13, weight="bold")
        change = statistics.median(row["pairedPercentChanges"])
        axis.set_title(f"{title}\n{change:.1f}% paired median", fontsize=11, pad=14)
        axis.set_xticks([0, 1], [f"Before\n{before_sha}", f"After\n{after_sha}"])
        axis.set_xlim(-.35, 1.35)
        axis.set_ylim(0, max(max(pair) for pair in pairs) * 1.3)
        axis.set_ylabel("Elapsed time in CPU path (ms)")
        axis.grid(axis="y", color="#e7eaed", linewidth=.8)
        axis.spines[["top", "right"]].set_visible(False)
    figure.suptitle("Overview: three measured optimization rounds", fontsize=18, weight="bold", y=.98)
    figure.text(.5, .9, "500-card synthetic catalog · Release production components · five alternating process pairs per panel", ha="center", fontsize=10)
    figure.text(.5, .04, "Each line is one paired process median. Panels are separate experiments. These are not GPU times or rendered frame times.", ha="center", fontsize=9, color="#52606b")
    figure.subplots_adjust(left=.065, right=.98, bottom=.19, top=.77, wspace=.4)
    for suffix in ["svg", "png"]:
        path = evidence / f"cpu-rounds.{suffix}"
        figure.savefig(path, dpi=180, facecolor="white", metadata={"Date": None} if suffix == "svg" else None)
        if suffix == "svg":
            path.write_text("\n".join(line.rstrip() for line in path.read_text().splitlines()) + "\n")
    plt.close(figure)


if __name__ == "__main__":
    main()
