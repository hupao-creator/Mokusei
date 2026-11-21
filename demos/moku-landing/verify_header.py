"""Link and replay the current Debug workspace in its production nested reading host."""
from pathlib import Path
import argparse
import sys
from uuid import uuid4

source = Path(__file__).resolve().parent
repo = source.parents[1]
sys.path.insert(0, str(repo / "tools/verification"))
sys.path.insert(0, str(repo / "tools/benchmarks"))
from native_replay import NativeReplay
from gate.ux import native_lease

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--capture", action="store_true", help="capture the own window at menu and maximum zoom")
args = parser.parse_args()
with native_lease():
    args.output.mkdir(parents=True, exist_ok=False)
    # Keep AppKit's saved window state separate across consecutive replay runs.
    replay = NativeReplay(repo, "NestedHeaderReplay", f"com.chief.nested-header-replay.{uuid4().hex}")
    try:
        replay.compile([source / "NestedHeaderReplay.swift"])
        status = replay.run(["--capture"] if args.capture else [], timeout=60, launch_services=False)
    finally:
        try:
            replay.export(args.output)
        finally:
            replay.close()
sys.exit(status)
