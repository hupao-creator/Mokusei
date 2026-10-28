"""Build the production-component Moku mention transition demo in isolated temporary storage."""
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
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--open", action="store_true")
options = parser.parse_args()
output = repo / ".build/moku-mention-transition"
output.mkdir(parents=True, exist_ok=True)
if not options.skip_build:
    subprocess.run(["xcrun", "swift", "build", "--package-path", str(repo / "app/macos")], cwd=repo, check=True)
replay = NativeReplay(repo, "MokuMentionDemo", "com.mokusei.moku-mention-transition-demo")
try:
    replay.compile([source / "main.swift"])
    # Keep only the standalone app and its private workspace for user review.
    # NativeReplay's sources/link objects remain temporary and are cleaned up.
    retained = Path(tempfile.mkdtemp(prefix="mokusei-native-replay-moku-mention-transition-", dir="/private/tmp"))
    (retained / "workspace").mkdir()
    application = retained / replay.application.name
    shutil.copytree(replay.application, application, symlinks=True)
    (output / "app-path.txt").write_text(str(application))
    print(application, flush=True)
except subprocess.CalledProcessError as error:
    raise SystemExit(error.returncode)
finally:
    replay.close()
if options.open:
    subprocess.run(["open", "-n", str(application)], check=True)
