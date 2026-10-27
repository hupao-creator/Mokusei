"""Run the production Note replay with staged inputs/resources in a temporary workspace.

Usage: python3 tools/verification/moku-note/run.py --skip-build --records <json>
   or: python3 tools/verification/moku-note/run.py --skip-build --exposure-connection <temporary-profile>
SwiftPM builds and native replays must run serially.
"""
from pathlib import Path
import argparse
import json
import subprocess
import sys
import tempfile

preview = Path(__file__).resolve().parent
repo = preview.parents[2]
sys.path.insert(0, str(preview.parent))
from native_replay import NativeReplay

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--voice-only", action="store_true")
parser.add_argument("--isolation-only", action="store_true", help="Validate staged paths/resources and exit before mounting UI")
parser.add_argument("--timeout", type=int, default=180, help="Maximum app runtime in seconds; timeout terminates the owned app")
source = parser.add_mutually_exclusive_group(required=True)
source.add_argument("--records", type=Path)
source.add_argument("--exposure-connection", type=Path)
parser.add_argument("--evidence", type=Path, default=Path(".scratch/moku-note-production/evidence"))
options = parser.parse_args()
if options.timeout < 1:
    parser.error("--timeout must be positive")
evidence = options.evidence.resolve()
if not options.skip_build:
    subprocess.run(["/usr/bin/xcrun", "swift", "build", "--package-path", str(repo / "app/macos")], cwd=repo, check=True)
replay = NativeReplay(repo, "MokuNoteReplay", "com.mokusei.moku-note-replay")
try:
    replay.acquire()
    replay.compile([preview / "main.swift"])
    output = replay.workspace / "evidence"
    if options.records:
        arguments = [replay.copy_input(options.records.resolve(), "records.json"), output]
    else:
        profile = options.exposure_connection.resolve()
        allowed = [Path(tempfile.gettempdir()).resolve(), Path("/private/tmp")]
        if not any(profile.is_relative_to(root) for root in allowed):
            raise RuntimeError("Exposure replay only accepts an isolated temporary Runtime profile")
        arguments = ["--exposure-connection", profile, output]
    if options.voice_only:
        arguments.append("--voice-only")
    if options.isolation_only:
        arguments.append("--isolation-only")
    status = replay.run(arguments, timeout=options.timeout)
    report = replay.root / "result.json"
    if not report.is_file():
        raise RuntimeError("Replay exited without a result; inspect runtime-isolation.json before retrying")
    result = json.loads(report.read_text())
    passed = result["ok"] and status == 0
    print(("PASS: " if passed else "FAIL: ") + result["message"])
    raise SystemExit(0 if passed else 1)
except RuntimeError as error:
    print("FAIL: " + str(error) + "; evidence: " + str(evidence), file=sys.stderr)
    raise SystemExit(1)
finally:
    replay.export(evidence)
    replay.close()
