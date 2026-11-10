"""Build (never launch) the isolated native Super Thread carousel proposal."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(__file__).resolve().parent
repo = source.parents[1]
sys.path.insert(0, str(repo / "tools/verification"))
from native_replay import NativeReplay

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-build", action="store_true", help="Reuse current-worktree Debug production objects")
parser.add_argument("--headless", action="store_true", help="Export data scenarios without creating NSApplication or a window")
options = parser.parse_args()
output = repo / ".build/super-thread-carousel"
output.mkdir(parents=True, exist_ok=True)
if not options.skip_build:
    subprocess.run(["xcrun", "swift", "build", "--package-path", str(repo / "app/macos"),
                    "--product", "Mokusei", "--disable-sandbox", "--disable-automatic-resolution", "-j", "4"],
                   cwd=repo, check=True)
replay = NativeReplay(repo, "SuperThreadProductionDemo", "com.mokusei.super-thread-production-demo")
try:
    replay.compile([source / name for name in ["Collection.swift", "ReportFixture.swift", "ProductionProjection.swift", "main.swift"]],
                   extra_args=["-disable-sandbox"])
    retained = Path(tempfile.mkdtemp(prefix="mokusei-native-replay-carousel-", dir="/private/tmp"))
    (retained / "workspace").mkdir()
    application = retained / replay.application.name
    shutil.copytree(replay.application, application, symlinks=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(application)], check=True)
    if options.headless:
        result = subprocess.run([str(application / "Contents/MacOS/SuperThreadProductionDemo"), "--headless"],
                                check=True, capture_output=True, text=True, timeout=30)
        (output / "headless.json").write_text(result.stdout)
        shutil.copy2(retained / "workspace/production-projection.json", output / "production-projection.json")
        (output / "headless.stderr.log").write_text(result.stderr)
    (output / "app-path.txt").write_text(str(application) + "\n")
    print(application, flush=True)
except subprocess.CalledProcessError as error:
    raise SystemExit(error.returncode)
finally:
    # Compile-only staging owns no running process; do not scan or stop apps.
    replay.temporary.cleanup()
