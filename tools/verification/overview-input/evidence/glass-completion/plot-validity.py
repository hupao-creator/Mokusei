"""Plot retained trial validity, not an on/off performance comparison."""
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch, Rectangle


def main():
    directory = Path(__file__).resolve().parent
    status = json.loads((directory / "status.json").read_text())
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11, "svg.hashsalt": "glass-validity-20261025"})
    colors = {"valid": "#368276", "invalid": "#bf4b45", "missing": "#e2e5e8"}
    figure, (matrix, host) = plt.subplots(2, 1, figsize=(12, 6.5), gridspec_kw={"height_ratios": [1, 1.6]})
    figure.suptitle("Glass World trial validity — comparison remains incomplete", x=.06, ha="left", weight="bold", fontsize=15)
    for index, (name, run) in enumerate(status["runs"].items()):
        rows = {r["name"]: r for r in json.loads((directory / name / "summary.json").read_text())["rows"]}
        for column in range(32):
            condition = run["conditionOrder"][column] if column < len(run["conditionOrder"]) else None
            category = "missing" if condition is None else "valid" if rows[condition]["valid"] else "invalid"
            matrix.add_patch(Rectangle((column + .07, index + .08), .86, .84, color=colors[category], linewidth=0))
    matrix.set(xlim=(0, 32), ylim=(3, 0), yticks=[.5, 1.5, 2.5], yticklabels=["run-3 · old base", "run-4 · no focus", "run-5 · host load"], xticks=[.5, 7.5, 15.5, 23.5, 31.5], xticklabels=[1, 8, 16, 24, 32], xlabel="Planned condition order within each trial (4 alternating repetitions)")
    matrix.legend(handles=[Patch(color=colors[key], label=label) for key, label in [("valid", "Valid condition"), ("invalid", "Invalid condition"), ("missing", "Not measured")]], loc="lower left", bbox_to_anchor=(0, 1.01), ncol=3, frameon=False)
    summary = json.loads((directory / "run-5/summary.json").read_text())
    indexed = {r["name"]: r for r in summary["rows"]}
    rows = [indexed[name] for name in status["runs"]["run-5"]["conditionOrder"]]
    host.bar(range(len(rows)), [row["hostBusyPercent"] for row in rows], color=[colors["valid" if row["valid"] else "invalid"] for row in rows], width=.6)
    host.axhline(40, color=colors["invalid"], linestyle="--", linewidth=1.2, label="Original rejection gate: 40%")
    for index, row in enumerate(rows):
        host.text(index, row["hostBusyPercent"] + 1, f'{row["hostBusyPercent"]:.2f}%', ha="center", fontsize=10)
    host.set(ylim=(0, 50), ylabel="Whole-host CPU busy (%)", xticks=range(len(rows)), xticklabels=[f'{r["appearance"]}\n{r["scenario"]} {r["material"]}' for r in rows], title="run-5: sixth condition stopped collection; later conditions were not attempted")
    host.legend(loc="upper left", frameon=False)
    for axis in [matrix, host]:
        for spine in axis.spines.values():
            spine.set_visible(False)
        axis.tick_params(length=0)
    host.grid(axis="y", alpha=.18); host.set_axisbelow(True)
    figure.text(.06, .015, "Host busy is across all CPU cores. The rejected static fixture used 0.49% of one core.\nNo GPU time, rendered frame time or on/off advantage is established by this figure.", fontsize=10, color="#4e555d")
    figure.subplots_adjust(left=.16, right=.97, bottom=.19, top=.86, hspace=.8)
    for extension in ["svg", "png"]:
        path = directory / ("validity." + extension)
        figure.savefig(path, dpi=160, metadata={"Date": None} if extension == "svg" else None)
        if extension == "svg":
            path.write_text("\n".join(line.rstrip() for line in path.read_text().splitlines()) + "\n")


if __name__ == "__main__":
    main()
