"""Run production Moku voice cloud and synthetic PCM in an isolated AppKit application.

Usage: python3 tools/verification/moku-voice-cloud/run.py [--skip-build]
The default builds current production Debug modules first. --skip-build is for
a just-completed make check. Run serially with other SwiftPM builds.
"""
from pathlib import Path
import argparse
import fcntl
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
options = parser.parse_args()
if not options.skip_build:
    subprocess.run(["/usr/bin/xcrun", "swift", "build", "--package-path", str(package)], cwd=repo, check=True)
build = package / f".build/{platform.machine()}-apple-macosx/debug"
temporary = tempfile.TemporaryDirectory(prefix="mokusei-moku-voice-cloud-")
application = Path(temporary.name) / "MokuVoiceCloudReplay.app"
executable = application / "Contents/MacOS/MokuVoiceCloudReplay"
link_list = build / "Mokusei.product/Objects.LinkFileList"
if not link_list.is_file():
    raise SystemExit("Build current production modules first: make check")
executable.parent.mkdir(parents=True, exist_ok=True)
# Snapshot one consistent build while respecting SwiftPM's output-directory
# lock. Other verification threads can rebuild after this brief copy; swiftc
# then links immutable files instead of racing their rewritten .o files.
lock_name = str(package / ".build").replace("/", "_") + ".lock"
build_lock = (Path(tempfile.gettempdir()) / lock_name).open("a+")
fcntl.flock(build_lock, fcntl.LOCK_SH)
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
        "CFBundleIdentifier": "com.mokusei.moku-voice-cloud-replay",
        "CFBundleName": "MokuVoiceCloudReplay",
        "CFBundleExecutable": "MokuVoiceCloudReplay",
        "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "26.0",
    }, output)
objects = [line.strip().strip('"') for line in link_list.read_text().splitlines()
           if "/Mokusei.build/" not in line]
if not objects or any(not Path(item).is_file() for item in objects):
    raise SystemExit("Production link list contains missing objects; run make check")
snapshot = application.parent / "ProductionObjects"
snapshot.mkdir()
shutil.copytree(build / "Modules", snapshot / "Modules")
copied = []
for item in objects:
    source = Path(item)
    target = snapshot / source.parent.name / source.name
    target.parent.mkdir(exist_ok=True)
    shutil.copy2(source, target)
    copied.append(str(target))
objects = copied
fcntl.flock(build_lock, fcntl.LOCK_UN)
build_lock.close()
args = ["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
        "-target", f"{platform.machine()}-apple-macosx26.0", "-I", str(snapshot / "Modules"), "-F", str(build),
        "-framework", "LiveKitWebRTC", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-module-cache-path", str(application.parent / "ModuleCache")]
for include in [
    package / ".build/checkouts/swift-cmark/src/include",
    package / ".build/checkouts/swift-cmark/extensions/include",
    package / ".build/checkouts/swift-markdown/Sources/CAtomic/include",
    package / ".build/checkouts/swift-system/Sources/CSystem/include",
]:
    args += ["-I", str(include), "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap")]
result = subprocess.run([*args, str(preview / "main.swift"), *objects, "-o", str(executable)])
if result.returncode:
    raise SystemExit(result.returncode)
subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(application)], check=True)
# The executable runs NSApplication's full event loop in an isolated process.
report = application.parent / "result.json"
report.unlink(missing_ok=True)
try:
    execution = subprocess.run(["/usr/bin/open", "-W", "-n", str(application)], cwd=repo, check=False,
                               timeout=180 if os.environ.get("MOKU_VOICE_INSPECT") else 90)
except subprocess.TimeoutExpired:
    # This exact disposable executable only; never the running production app.
    subprocess.run(["/usr/bin/pkill", "-TERM", "-f", str(executable)], check=False)
    raise SystemExit("FAIL: own native voice replay timed out")
if not report.is_file():
    raise SystemExit("FAIL: replay exited without a result")
result = json.loads(report.read_text())
passed = result["ok"] and execution.returncode == 0
evidence = Path(os.environ.get("MOKU_VOICE_EVIDENCE", "/tmp/mokusei-moku-voice-cloud-evidence"))
if not passed:
    evidence /= "failure"
if (application.parent / "evidence").is_dir():
    shutil.copytree(application.parent / "evidence", evidence, dirs_exist_ok=True)
    shutil.copy2(report, evidence / "result.json")
    print("Evidence: " + str(evidence))
if passed:
    print((evidence / "measurements.json").read_text())
print(("PASS: " if passed else "FAIL: ") + result["message"])
raise SystemExit(0 if passed else 1)
