"""Build and replay the isolated native first-run setup proposal."""
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
output = repo / ".build/landing-setup"
output.mkdir(parents=True, exist_ok=True)
if not options.skip_build:
    subprocess.run(["xcrun", "swift", "build", "--package-path", str(repo / "app/macos")], cwd=repo, check=True)
replay = NativeReplay(repo, "ChiefSetupDemo", "com.chief.landing-setup-demo")
try:
    replay.compile([source.parent / "moku-landing/LandingFixture.swift",
                    source / "SetupFixture.swift", source / "SetupCapabilityAnimation.swift",
                    source / "SetupConfigurationPanel.swift", source / "SetupView.swift", source / "main.swift"])
    retained = Path(tempfile.mkdtemp(prefix="chief-native-replay-setup-", dir="/private/tmp"))
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
