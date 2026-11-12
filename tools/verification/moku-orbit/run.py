"""Replay the existing production three-dot orbit and lifecycle checks."""
from pathlib import Path
import argparse
import json
import os
import subprocess
import sys

here = Path(__file__).resolve().parent
repo = here.parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-build", action="store_true")
options = parser.parse_args()
if not options.skip_build:
    subprocess.run(["xcrun", "swift", "build", "--package-path", str(repo / "app/macos")], check=True)
sys.path.insert(0, str(here.parent))
from native_replay import NativeReplay

replay = NativeReplay(repo, "MokuOrbitReplay", "com.mokusei.moku-orbit-replay")
evidence = Path(os.environ.get("MOKU_ORBIT_EVIDENCE", "/tmp/mokusei-moku-orbit-evidence"))
try:
    replay.compile([here / "main.swift"])
    replay.acquire()
    status = replay.run([replay.workspace / "evidence"], timeout=120)
    report = replay.root / "result.json"
    if not report.is_file():
        raise RuntimeError("Native orbit replay exited without a result")
    result = json.loads(report.read_text())
    replay.export(evidence)
    print(json.dumps(result, indent=2))
    print("Evidence: " + str(evidence))
    raise SystemExit(0 if result["ok"] and status == 0 else 1)
finally:
    replay.close()
