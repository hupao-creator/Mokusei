"""Run production Moku talk audit-to-UI lifecycle in an isolated AppKit application.

Usage: python3 tools/verification/moku-talk/run.py [--skip-build]
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
parser.add_argument("--records", type=Path, required=True, help="Go replay's real talk audit export")
parser.add_argument("--evidence", type=Path, default=Path(".scratch/moku-talk-production/evidence"))
options = parser.parse_args()
options.evidence = options.evidence.resolve()
options.records = options.records.resolve()
if not options.skip_build:
    subprocess.run(["/usr/bin/xcrun", "swift", "build", "--package-path", str(package)], cwd=repo, check=True)
build = package / f".build/{platform.machine()}-apple-macosx/debug"
temporary = tempfile.TemporaryDirectory(prefix="mokusei-moku-talk-")
application = Path(temporary.name) / "MokuTalkReplay.app"
executable = application / "Contents/MacOS/MokuTalkReplay"
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
        "CFBundleIdentifier": "com.mokusei.moku-talk-replay",
        "CFBundleName": "MokuTalkReplay",
        "CFBundleExecutable": "MokuTalkReplay",
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
result = subprocess.run([*args, str(preview / "main.swift"), str(preview / "dispatch.swift"), *objects, "-o", str(executable)])
if result.returncode:
    raise SystemExit(result.returncode)
subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(application)], check=True)
# The executable runs NSApplication's full event loop in an isolated process.
report = application.parent / "result.json"
report.unlink(missing_ok=True)
execution = subprocess.run([str(executable), str(options.records), str(options.evidence)],
                           cwd=repo, check=False, timeout=120)
if not report.is_file():
    raise SystemExit("FAIL: replay exited without a result")
result = json.loads(report.read_text())
passed = result["ok"] and execution.returncode == 0
print(("PASS: " if passed else "FAIL: ") + result["message"])
raise SystemExit(0 if passed else 1)
