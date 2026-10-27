#!/usr/bin/env python3
"""Measure production settings reads; optionally overlay a fixed Git revision.

Only selected Go sources are read from Git into a temporary directory. HEAD,
branches, worktrees, installed CLIs and native user profiles are never modified.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SOURCES = {
    "claude": ["harness.go", "settings.go"],
    "codex": ["adapter.go", "catalog.go", "executable.go", "transport.go"],
    "pi": ["adapter.go", "settings.go"],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", help="fixed baseline commit; omit to measure current sources")
    parser.add_argument("--harness", choices=["all", *SOURCES], default="all")
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.repeats <= 10:
        parser.error("--repeats must be between 1 and 10")
    revision = subprocess.check_output(
        ["git", "rev-parse", "--verify", args.ref + "^{commit}"], cwd=ROOT, text=True
    ).strip() if args.ref else None
    harnesses = list(SOURCES) if args.harness == "all" else [args.harness]
    with tempfile.TemporaryDirectory(prefix="mokusei-settings-baseline-") as directory:
        temporary = Path(directory)
        for harness in harnesses:
            command = [str(ROOT / "scripts/go.sh"), "run"]
            if revision:
                replacements = {}
                for name in SOURCES[harness]:
                    path = Path("internal/plugins/harness") / harness / name
                    destination = temporary / f"{harness}-{name}"
                    destination.write_bytes(subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=ROOT))
                    replacements[str(ROOT / path)] = str(destination)
                overlay = temporary / f"{harness}.json"
                overlay.write_text(json.dumps({"Replace": replacements}))
                command.append(f"-overlay={overlay}")
            command += [f"./tools/verification/{harness}", "-settings-performance"]
            for sample in range(1, args.repeats + 1):
                print(f"source={revision or 'working-tree'} harness={harness} sample={sample}", flush=True)
                subprocess.run(command, cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
