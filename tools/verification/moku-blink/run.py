"""Run production Moku capsule blinking in an isolated AppKit application.

Usage: python3 tools/verification/moku-blink/run.py [--skip-build]
The default builds current production Debug modules first. --skip-build is for
a just-completed make check. Run serially with other SwiftPM builds.
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
parser.add_argument("--orbit-only", action="store_true", help="Replay running orbit and lifecycle exits")
parser.add_argument("--focus-only", action="store_true", help="Only replay eye focus transitions")
parser.add_argument("--negative-control", action="store_true", help="Pause the blink schedule; require pixel detection to fail")
options = parser.parse_args()
if not options.skip_build:
    subprocess.run(["/usr/bin/xcrun", "swift", "build", "--package-path", str(package)], cwd=repo, check=True)
build = package / f".build/{platform.machine()}-apple-macosx/debug"
temporary = tempfile.TemporaryDirectory(prefix="mokusei-moku-blink-")
application = Path(temporary.name) / "MokuBlinkReplay.app"
executable = application / "Contents/MacOS/MokuBlinkReplay"
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
        "CFBundleIdentifier": "com.mokusei.moku-blink-replay",
        "CFBundleName": "MokuBlinkReplay",
        "CFBundleExecutable": "MokuBlinkReplay",
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
result = subprocess.run([*args, str(preview / "main.swift"), *objects, "-o", str(executable)])
if result.returncode:
    raise SystemExit(result.returncode)
subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(application)], check=True)
# The executable runs NSApplication's full event loop in an isolated process.
report = application.parent / "result.json"
report.unlink(missing_ok=True)
launch = ["/usr/bin/open", "-W", "-n", str(application), "--args", str(application.parent / "evidence")]
if options.orbit_only:
    launch += ["--orbit-only"]
if options.focus_only:
    launch += ["--focus-only"]
if options.negative_control:
    launch += ["--negative-control"]
try:
    execution = subprocess.run(launch, cwd=repo, check=False, timeout=120)
except subprocess.TimeoutExpired:
    # Only this disposable fixture, never another production or demo process.
    subprocess.run(["/usr/bin/pkill", "-TERM", "-f", str(executable)], check=False)
    raise SystemExit("FAIL: own native blink replay timed out")
if not report.is_file():
    raise SystemExit("FAIL: replay exited without a result")
result = json.loads(report.read_text())
passed = result["ok"] and execution.returncode == 0
# Keep failed captures too: a black/occluded crop must be diagnosable rather
# than confused with an animation regression after the disposable app exits.
evidence = Path(os.environ.get("MOKU_BLINK_EVIDENCE", "/tmp/mokusei-moku-blink-evidence"))
if options.negative_control:
    evidence /= "negative-control"
elif not passed:
    evidence /= "failure"
if (application.parent / "evidence").is_dir():
    shutil.copytree(application.parent / "evidence", evidence, dirs_exist_ok=True)
    shutil.copy2(report, evidence / "result.json")
    print("Evidence: " + str(evidence))
if options.negative_control:
    detected = not result["ok"] and "no natural close/reopen" in result["message"]
    print(("PASS: " if detected else "FAIL: ") + "negative control: " + result["message"])
    raise SystemExit(0 if detected else 1)
if passed and (evidence / "measurements.json").is_file():
    print((evidence / "measurements.json").read_text())
print(("PASS: " if passed else "FAIL: ") + result["message"])
raise SystemExit(0 if passed else 1)
