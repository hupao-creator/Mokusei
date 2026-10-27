"""Retired. Moku no longer renders a reasoning trace, so this contour replay cannot pass.

The historical procedure remains below for the removed implementation. Do not
treat a failure here as a regression of the current dock.
"""
raise SystemExit("Retired: Moku no longer renders a reasoning trace. This replay asserted the removed contour.")

from pathlib import Path
import argparse
import json
import os
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time

preview = Path(__file__).resolve().parent
repo = preview.parents[2]
package = repo / "app/macos"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--negative-control", action="store_true", help="Remove production contour rendering; require capture verification to fail")
options = parser.parse_args()
if not options.skip_build:
    subprocess.run(["/usr/bin/xcrun", "swift", "build", "--package-path", str(package)], cwd=repo, check=True)
build = package / f".build/{platform.machine()}-apple-macosx/debug"
temporary = tempfile.TemporaryDirectory(prefix="mokusei-moku-reasoning-")
application = Path(temporary.name) / "MokuReasoningReplay.app"
executable = application / "Contents/MacOS/MokuReasoningReplay"
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
        "CFBundleIdentifier": "com.mokusei.moku-reasoning-replay",
        "CFBundleName": "MokuReasoningReplay",
        "CFBundleExecutable": "MokuReasoningReplay",
        "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "26.0",
    }, output)
objects = [line.strip().strip('"') for line in link_list.read_text().splitlines()
           if "/Mokusei.build/" not in line]
if not objects or any(not Path(item).is_file() for item in objects):
    raise SystemExit("Production link list contains missing objects; run make check")
# Other authorized threads build the shared package concurrently. Link a stable
# private copy, never object files that SwiftPM may replace during swiftc linking.
object_directory = application.parent / "LinkObjects"
object_directory.mkdir()
for attempt in range(20):
    before = [(Path(item).stat().st_size, Path(item).stat().st_mtime_ns) for item in objects]
    snapshots = []
    for index, item in enumerate(objects):
        destination = object_directory / (str(index) + ".o")
        shutil.copy2(item, destination)
        snapshots.append(str(destination))
    after = [(Path(item).stat().st_size, Path(item).stat().st_mtime_ns) for item in objects]
    if before == after:
        objects = snapshots
        break
    time.sleep(0.1)
else:
    raise SystemExit("Production objects remained busy; retry after the parallel build")
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
if options.negative_control:
    launch += ["--negative-control"]
try:
    execution = subprocess.run(launch, cwd=repo, check=False, timeout=150)
except subprocess.TimeoutExpired:
    # Only this disposable fixture, never another production or demo process.
    subprocess.run(["/usr/bin/pkill", "-TERM", "-f", str(executable)], check=False)
    raise SystemExit("FAIL: own native reasoning replay timed out")
if not report.is_file():
    raise SystemExit("FAIL: replay exited without a result")
result = json.loads(report.read_text())
passed = result["ok"] and execution.returncode == 0
evidence = Path(os.environ.get("MOKU_REASONING_EVIDENCE", "/tmp/mokusei-moku-reasoning-evidence"))
if options.negative_control:
    evidence /= "negative-control"
elif not passed:
    evidence /= "failed"
if (application.parent / "evidence").is_dir():
    shutil.copytree(application.parent / "evidence", evidence, dirs_exist_ok=True)
    (evidence / "replay-result.json").write_text(json.dumps(result))
    if passed:
        print((evidence / "measurements.json").read_text())
    print("Evidence: " + str(evidence))
if options.negative_control:
    detected = not result["ok"] and "no naturally changing reasoning pixels" in result["message"]
    print(("PASS: " if detected else "FAIL: ") + "negative control: " + result["message"])
    raise SystemExit(0 if detected else 1)
print(("PASS: " if passed else "FAIL: ") + result["message"])
raise SystemExit(0 if passed else 1)
