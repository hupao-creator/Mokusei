"""Run production Moku capsule lifecycle and attachment UI in an isolated AppKit application.

Usage: python3 tools/verification/moku-attachments/run.py [--skip-build] [--appearance-only | --completion-only | --picker-only]
The default builds current production Debug modules first. --skip-build is for
a just-completed make check. Run serially with other SwiftPM builds.
Set MOKU_MENTION_SAMPLE=/tmp/mention.sample.txt with --completion-only to
capture a three-second CPU sample during the large-catalog typing replay.
"""
from pathlib import Path
import argparse
import json
import os
import platform
import plistlib
import shutil
import subprocess
import tempfile

preview = Path(__file__).resolve().parent
repo = preview.parents[2]
package = repo / "app/macos"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-build", action="store_true")
scope = parser.add_mutually_exclusive_group()
scope.add_argument("--completion-only", action="store_true", help="Replay production dock/history mention keyboard handling only")
scope.add_argument("--picker-only", action="store_true", help="Replay attachment picker open, cancel, reopen and disposal only")
scope.add_argument("--appearance-only", action="store_true", help="Replay production capsule layout and theme changes only")
options = parser.parse_args()
if options.picker_only:
    os.environ["MOKU_CAPSULE_REPLAY"] = "pickers"
if options.completion_only:
    os.environ["MOKU_CAPSULE_REPLAY"] = "completion"
if options.appearance_only:
    os.environ["MOKU_CAPSULE_REPLAY"] = "appearance"
if not options.skip_build:
    subprocess.run(["/usr/bin/xcrun", "swift", "build", "--package-path", str(package)], cwd=repo, check=True)
build = package / f".build/{platform.machine()}-apple-macosx/debug"
temporary = tempfile.TemporaryDirectory(prefix="mokusei-moku-attachments-")
application = Path(temporary.name) / "MokuAttachmentsReplay.app"
executable = application / "Contents/MacOS/MokuAttachmentsReplay"
link_list = build / "Mokusei.product/Objects.LinkFileList"
if not link_list.is_file():
    raise SystemExit("Build current production modules first: make check")
executable.parent.mkdir(parents=True, exist_ok=True)
resources = application / "Contents/Resources"
resources.mkdir(exist_ok=True)
frameworks = application / "Contents/Frameworks"
frameworks.mkdir(exist_ok=True)
subprocess.run(["/usr/bin/ditto", str(build / "LiveKitWebRTC.framework"),
                str(frameworks / "LiveKitWebRTC.framework")], check=True)
for bundle in build.glob("*.bundle"):
    shutil.copytree(bundle, resources / bundle.name, dirs_exist_ok=True)
with (application / "Contents/Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "com.mokusei.moku-attachments-replay",
        "CFBundleName": "MokuAttachmentsReplay",
        "CFBundleExecutable": "MokuAttachmentsReplay",
        "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "26.0",
    }, output)
objects = [line.strip().strip('"') for line in link_list.read_text().splitlines()
           if "/Mokusei.build/" not in line]
if not objects or any(not Path(item).is_file() for item in objects):
    raise SystemExit("Production link list contains missing objects; run make check")
args = ["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
        "-target", f"{platform.machine()}-apple-macosx26.0", "-I", str(build / "Modules"), "-F", str(build),
        "-framework", "LiveKitWebRTC", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-module-cache-path", str(application.parent / "ModuleCache")]
for include in [
    package / ".build/checkouts/swift-cmark/src/include",
    package / ".build/checkouts/swift-cmark/extensions/include",
    package / ".build/checkouts/swift-markdown/Sources/CAtomic/include",
    package / ".build/checkouts/swift-system/Sources/CSystem/include",
]:
    args += ["-I", str(include), "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap")]
result = subprocess.run([*args, str(preview / "main.swift"), str(preview / "InputPresentationReplay.swift"), *objects, "-o", str(executable)])
if result.returncode:
    raise SystemExit(result.returncode)
subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(application)], check=True)
# The executable runs NSApplication's full event loop in an isolated process.
report = application.parent / "result.json"
report.unlink(missing_ok=True)
execution = subprocess.run([str(executable)], cwd=repo, check=False,
                           timeout=300 if os.environ.get("MOKU_CAPSULE_INSPECT") == "presentation" else (180 if os.environ.get("MOKU_CAPSULE_INSPECT") else 90))
if not report.is_file():
    raise SystemExit("FAIL: replay exited without a result")
result = json.loads(report.read_text())
passed = result["ok"] and execution.returncode == 0
print(("PASS: " if passed else "FAIL: ") + result["message"])
raise SystemExit(0 if passed else 1)
