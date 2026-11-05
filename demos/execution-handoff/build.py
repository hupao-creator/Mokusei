"""Build an isolated native execution-handoff proposal. Never runs tests."""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys
import tempfile

source = Path(__file__).resolve().parent
repo = source.parents[1]
sys.path.insert(0, str(repo / "tools/verification"))
from native_replay import NativeReplay

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-build", action="store_true", help="Reuse this worktree's current Swift build")
parser.add_argument("--open", action="store_true")
parser.add_argument("--capture", action="store_true", help="Record a presentation reel; no assertions or tests")
parser.add_argument("--disable-sandbox", action="store_true", help="Disable SwiftPM's nested build sandbox")
options = parser.parse_args()
output = repo / ".build/execution-handoff"
output.mkdir(parents=True, exist_ok=True)
if not options.skip_build:
    subprocess.run(["xcrun", "swift", "build", "--package-path", str(repo / "app/macos"),
                    "--product", "Mokusei"] + (["--disable-sandbox"] if options.disable_sandbox else []),
                   cwd=repo, check=True)
replay = NativeReplay(repo, "ExecutionHandoffDemo", "com.mokusei.execution-handoff-demo")
try:
    replay.compile([source / "Fixture.swift", source / "HandoffStage.swift", source / "main.swift"])
    if options.capture:
        replay.acquire()
        status = replay.run(["--capture"], timeout=60)
        replay.export(output / "evidence")
        if (replay.root / "evidence").is_dir():
            shutil.copytree(replay.root / "evidence", output / "evidence", dirs_exist_ok=True)
        error = replay.root / "capture-error.txt"
        if error.is_file():
            raise RuntimeError("Presentation capture failed: " + error.read_text())
        if status:
            raise RuntimeError(f"Demo exited with status {status}")
    retained = Path(tempfile.mkdtemp(prefix="mokusei-native-replay-execution-", dir="/private/tmp"))
    (retained / "workspace").mkdir()
    application = retained / replay.application.name
    shutil.copytree(replay.application, application, symlinks=True)
    (output / "app-path.txt").write_text(str(application) + "\n")
    print(application, flush=True)
except subprocess.CalledProcessError as error:
    raise SystemExit(error.returncode)
finally:
    replay.close()
if options.open:
    subprocess.run(["open", "-n", str(application)], check=True)
