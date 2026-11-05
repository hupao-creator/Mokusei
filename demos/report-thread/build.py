"""Build an isolated Report Thread proposal using shared native UI resources."""
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
parser.add_argument("--production", action="store_true")
parser.add_argument("--capture", action="store_true")
options = parser.parse_args()
output = repo / ".build/report-thread"
output.mkdir(parents=True, exist_ok=True)
if not options.skip_build:
    subprocess.run(["xcrun", "swift", "build", "--package-path", str(repo / "app/macos"),
                    "--product", "Mokusei"], cwd=repo, check=True)
replay = NativeReplay(repo, "ReportThreadDemo", "com.mokusei.report-thread-demo")
try:
    replay.compile([source / "Production.swift", source / "Fixtures.swift", source / "ReportDocument.swift", source / "main.swift"])
    retained = Path(tempfile.mkdtemp(prefix="mokusei-native-replay-report-", dir="/private/tmp"))
    (retained / "workspace").mkdir()
    application = retained / replay.application.name
    shutil.copytree(replay.application, application, symlinks=True)
    (output / "app-path.txt").write_text(str(application) + "\n")
    print(application, flush=True)
except subprocess.CalledProcessError as error:
    raise SystemExit(error.returncode)
finally:
    replay.close()
if options.capture:
    subprocess.run(["open", "-W", "-n", str(application), "--args", "--capture"], check=True, timeout=90)
    evidence = retained / "evidence"
    required = ["01-card.png", "02-report-list.png", "03-execution.png", "04-second-execution.png",
                "05-return-to-list.png", "06-dark-list.png", "07-dark-execution.png", "08-narrow-list.png", "geometry.json"]
    if any(not (evidence / name).is_file() for name in required):
        raise RuntimeError(f"Capture incomplete; inspect {retained}")
    shutil.copytree(evidence, output / "evidence", dirs_exist_ok=True)
    print(output / "evidence", flush=True)
if options.open:
    subprocess.run(["open", "-n", str(application)] + (["--args", "--production"] if options.production else []), check=True)
