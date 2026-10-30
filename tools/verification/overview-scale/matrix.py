"""Run the Overview scale matrix serially and retain every command/result."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[2]
RUN = SOURCE / "run.py"


def execute(command, timeout=None):
    started = time.time()
    print("$", " ".join(str(part) for part in command), flush=True)
    subprocess.run([str(part) for part in command], check=True, cwd=REPO, timeout=timeout)
    print(f"  {time.time() - started:.1f}s", flush=True)


def direct(label, mode, output, extra=(), timeout=1800):
    execute([sys.executable, RUN, "run", "--label", label, "--mode", mode, "--output", output,
             "--", *extra], timeout=timeout)


def gui(label, mode, output, extra=(), timeout=900):
    execute([sys.executable, RUN, "gui", "--label", label, "--mode", mode, "--output", output,
             "--timeout", str(int(timeout)), "--", *extra], timeout=timeout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--label", default="formal")
    parser.add_argument("--phase", required=True)
    parser.add_argument("--reps", type=int, default=3)
    args = parser.parse_args()
    root = args.root.resolve()
    if not root.exists():
        raise SystemExit("Evidence root must exist: " + str(root))
    label = args.label
    phase = args.phase

    if phase in ("layout", "all"):
        direct(label, "layout", root / "raw/layout/layout.json")

    if phase in ("model", "all"):
        for n in [0, 5, 10, 40, 100, 500]:
            for rep in range(args.reps):
                direct(label, "model", root / f"raw/model/model-{n}-r{rep}.json",
                       ["--n", str(n), "--label", f"model-{n}-r{rep}"])
            if n == 500:
                break

    if phase in ("runtime", "all"):
        for n in [10, 40, 100, 500]:
            for rep in range(args.reps):
                direct(label, "runtime", root / f"raw/runtime/runtime-{n}-r{rep}.json",
                       ["--n", str(n), "--label", f"runtime-{n}-r{rep}"])

    if phase in ("gui-first", "all"):
        for n in [10, 40, 100, 500]:
            for rep in range(2):
                gui(label, "gui-first-load", root / f"raw/gui/first-load-{n}-r{rep}.json",
                    ["--n", str(n), "--scenario", "capture"], timeout=300)

    if phase in ("gui-idle", "all"):
        for n in [10, 40, 100, 500]:
            gui(label, "gui-idle", root / f"raw/gui/idle-a0-{n}.json",
                ["--n", str(n), "--seconds", "60", "--running", "none"], timeout=300)
        for n in [40, 500]:
            for running in ["visible", "offscreen"]:
                gui(label, "gui-idle", root / f"raw/gui/idle-a1-{running}-{n}.json",
                    ["--n", str(n), "--seconds", "60", "--running", running], timeout=300)

    if phase in ("gui-update", "all"):
        for n in [10, 40, 100, 500]:
            for target in ["visible", "offscreen"]:
                for rep in range(args.reps):
                    gui(label, "gui-update", root / f"raw/gui/update-{target}-{n}-r{rep}.json",
                        ["--n", str(n), "--hz", "10", "--seconds", "20", "--warmup", "5",
                         "--target", target, "--running", "none"], timeout=300)
        for n in [40, 500]:
            for rep in range(2):
                gui(label, "gui-update", root / f"raw/gui/update-20hz-visible-{n}-r{rep}.json",
                    ["--n", str(n), "--hz", "20", "--seconds", "20", "--warmup", "5",
                     "--target", "visible", "--running", "none"], timeout=300)
        for n in [40, 500]:
            for running, target in [("visible", "running"), ("offscreen", "running")]:
                for rep in range(2):
                    gui(label, "gui-update",
                        root / f"raw/gui/update-a1-{running}-{n}-r{rep}.json",
                        ["--n", str(n), "--hz", "10", "--seconds", "20", "--warmup", "5",
                         "--target", target, "--running", running], timeout=300)

    if phase in ("gui-motion", "all"):
        for n in [10, 20, 40]:
            gui(label, "gui-motion", root / f"raw/gui/motion-remove-all-{n}.json",
                ["--n", str(n), "--scenario", "remove-all"], timeout=180)
        for scenario, n in [("remove-to-one", 40), ("insert-one", 40), ("pan", 500)]:
            gui(label, "gui-motion", root / f"raw/gui/motion-{scenario}-{n}.json",
                ["--n", str(n), "--scenario", scenario], timeout=180)
        for n in [10, 40, 100, 500]:
            gui(label, "gui-motion", root / f"raw/gui/motion-filter-clear-{n}.json",
                ["--n", str(n), "--scenario", "filter-clear"], timeout=180)

    if phase in ("gui-k0", "all"):
        for n in [10, 40, 100, 500]:
            gui(label, "gui-update", root / f"raw/gui/update-k0-{n}.json",
                ["--n", str(n), "--hz", "10", "--seconds", "20", "--warmup", "5",
                 "--target", "visible", "--running", "none", "--sequence", "no-change"], timeout=300)
        for n in [40, 500]:
            gui("diag", "gui-update", root / f"raw/gui/diag-update-k0-{n}.json",
                ["--n", str(n), "--hz", "10", "--seconds", "5", "--warmup", "2",
                 "--target", "visible", "--running", "none", "--sequence", "no-change"], timeout=180)

    if phase in ("gui-motion-hidden", "all"):
        for scenario, n in [("remove-all", 40), ("remove-to-one", 40), ("filter-clear", 40)]:
            gui(label, "gui-motion", root / f"raw/gui/motion-hidden-{scenario}-{n}.json",
                ["--n", str(n), "--scenario", scenario, "--overview-visible", "0"], timeout=180)

    if phase in ("diag", "all"):
        direct("diag", "layout", root / "raw/layout/layout-diag.json")
        for n in [10, 40, 100, 500]:
            gui("diag", "gui-update", root / f"raw/gui/diag-update-offscreen-{n}.json",
                ["--n", str(n), "--hz", "10", "--seconds", "5", "--warmup", "2",
                 "--target", "offscreen", "--running", "offscreen"], timeout=180)
        gui("diag", "gui-motion", root / "raw/gui/diag-motion-remove-all-40.json",
            ["--n", "40", "--scenario", "remove-all"], timeout=180)
        for n in [40, 500]:
            gui("diag", "gui-motion", root / f"raw/gui/diag-motion-filter-clear-{n}.json",
                ["--n", str(n), "--scenario", "filter-clear"], timeout=180)

    if phase in ("gui-glass", "all"):
        for n in [40, 500]:
            gui(label, "gui-idle", root / f"raw/gui/idle-glass-off-{n}.json",
                ["--n", str(n), "--seconds", "30", "--running", "none", "--glass", "0"], timeout=240)
            gui(label, "gui-idle", root / f"raw/gui/idle-glass-off-visible-{n}.json",
                ["--n", str(n), "--seconds", "30", "--running", "visible", "--glass", "0"], timeout=240)
            gui(label, "gui-update", root / f"raw/gui/update-glass-off-visible-{n}.json",
                ["--n", str(n), "--hz", "10", "--seconds", "10", "--warmup", "3",
                 "--target", "visible", "--running", "none", "--glass", "0"], timeout=240)

    (root / f"matrix-{phase}.json").write_text(json.dumps({"phase": phase, "label": label,
        "finishedAt": time.time()}, indent=2))


if __name__ == "__main__":
    main()
