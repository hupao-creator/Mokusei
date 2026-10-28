"""Build the isolated native Moku thinking study against current production UI."""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys

demo = Path(__file__).resolve().parent
repo = demo.parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--output", type=Path, default=repo / ".build/moku-thinking-orbit/MokuThinkingDemo.app")
options = parser.parse_args()
output = options.output.resolve()
if output.name != "MokuThinkingDemo.app" or not output.is_relative_to((repo / ".build").resolve()):
    parser.error("--output must be a MokuThinkingDemo.app inside this checkout's .build directory")
running_executable = str(output / "Contents/MacOS/MokuThinkingDemo")
processes = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True).splitlines()
if running_executable in (value.strip() for value in processes):
    raise SystemExit("This demo is open. Close it or choose a different --output app path before rebuilding.")
if not options.skip_build:
    subprocess.run(["xcrun", "swift", "build", "--package-path", str(repo / "app/macos")], check=True)

sys.path.insert(0, str(repo / "tools/verification"))
from native_replay import NativeReplay

replay = NativeReplay(repo, "MokuThinkingDemo", "com.mokusei.thinking-history-demo")
try:
    replay.compile(sorted(demo.rglob("*.swift")))
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        shutil.rmtree(output)
    shutil.copytree(replay.application, output)
    print(output)
except subprocess.CalledProcessError as error:
    raise SystemExit(f"Native demo compilation failed (exit {error.returncode}); see diagnostics above.")
finally:
    replay.close()
