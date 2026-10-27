"""Run production Dock dismissal in an isolated temporary app/workspace."""
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
parser.add_argument("--evidence", type=Path, default=Path(".scratch/moku-talk-dismiss/evidence"))
options = parser.parse_args()
evidence = options.evidence.resolve()
if not options.skip_build:
    subprocess.run(["/usr/bin/xcrun", "swift", "build", "--package-path", str(repo / "app/macos")], cwd=repo, check=True)
replay = NativeReplay(repo, "MokuTalkDismissReplay", "com.mokusei.moku-talk-dismiss-replay")
try:
    replay.acquire()
    replay.compile([preview / "main.swift"])
    status = replay.run([replay.workspace / "evidence"], timeout=120, launch_services=False)
    report = replay.root / "result.json"
    if not report.is_file():
        raise RuntimeError("Replay exited without a result; inspect runtime-isolation.json before retrying")
    result = json.loads(report.read_text())
    passed = result["ok"] and status == 0
    print(("PASS: " if passed else "FAIL: ") + result["message"])
    raise SystemExit(0 if passed else 1)
finally:
    replay.export(evidence)
    replay.close()
