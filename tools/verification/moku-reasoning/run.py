"""Replay live public Moku reasoning through the production native Arc.

Builds current modules unless --skip-build follows a just-completed build/check.
Run SwiftPM builds and native GUI replays serially.
"""
from pathlib import Path
import argparse
import json
import subprocess
import sys

preview = Path(__file__).resolve().parent
repo = preview.parents[2]
sys.path.insert(0, str(preview.parent))
from native_replay import NativeReplay

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--negative-control", action="store_true")
parser.add_argument("--timeout", type=int, default=180)
parser.add_argument("--evidence", type=Path, default=Path(".build/moku-reasoning-evidence"))
options = parser.parse_args()
if options.timeout < 1:
    parser.error("--timeout must be positive")
evidence = options.evidence.resolve()
if not options.skip_build:
    subprocess.run(["xcrun", "swift", "build", "--package-path", str(repo / "app/macos")], cwd=repo, check=True)
replay = NativeReplay(repo, "MokuReasoningReplay", "com.mokusei.moku-reasoning-replay")
try:
    replay.acquire()
    replay.compile([preview / "main.swift"])
    arguments = [replay.workspace / "evidence"]
    if options.negative_control:
        arguments.append("--negative-control")
    status = replay.run(arguments, timeout=options.timeout)
    report = replay.root / "result.json"
    if not report.is_file():
        raise RuntimeError("Native reasoning replay exited without a result")
    result = json.loads(report.read_text())
    if options.negative_control:
        passed = not result["ok"] and "no naturally changing reasoning pixels" in result["message"]
    else:
        passed = result["ok"] and status == 0
    print(("PASS: " if passed else "FAIL: ") + result["message"])
    raise SystemExit(0 if passed else 1)
except (RuntimeError, subprocess.CalledProcessError) as error:
    print("FAIL: " + str(error) + "; evidence: " + str(evidence), file=sys.stderr)
    raise SystemExit(1)
finally:
    replay.export(evidence)
    replay.close()
