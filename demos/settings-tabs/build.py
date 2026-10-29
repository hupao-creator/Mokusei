"""Build the native Settings tabs proposal with shared onboarding controls."""
from pathlib import Path
import argparse
import json
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
parser.add_argument("--verify", action="store_true")
parser.add_argument("--open", action="store_true")
options = parser.parse_args()
output = repo / ".build/settings-tabs"
output.mkdir(parents=True, exist_ok=True)
if not options.skip_build:
    subprocess.run(["xcrun", "swift", "build", "--package-path", str(repo / "app/macos")], cwd=repo, check=True)
replay = NativeReplay(repo, "MokuseiSettingsTabsDemo", "com.mokusei.settings-tabs-demo")
try:
    setup = source.parent / "landing-setup"
    replay.compile([source.parent / "moku-landing/LandingFixture.swift",
                    setup / "SetupFixture.swift", setup / "SetupCapabilityAnimation.swift",
                    setup / "SetupConfigurationPanel.swift", source / "SettingsTabsView.swift", source / "main.swift"])
    if options.verify:
        replay.acquire()
        try:
            status = replay.run(["--verify"], timeout=90)
        finally:
            replay.export(output / "evidence")
        report = json.loads((replay.root / "result.json").read_text())
        if status or not report["ok"]:
            raise RuntimeError(report["message"])
        print(report["message"], flush=True)
    retained = Path(tempfile.mkdtemp(prefix="mokusei-native-replay-settings-tabs-", dir="/private/tmp"))
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
