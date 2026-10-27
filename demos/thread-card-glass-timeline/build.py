"""Build the production glass timeline preview against local Release modules."""
from pathlib import Path
import plistlib
import shutil
import subprocess

preview = Path(__file__).resolve().parent
repo = preview.parents[1]
package = repo / "app/macos"
build = package / ".build/arm64-apple-macosx/release"
application = repo / ".build/thread-card-glass-timeline/ThreadCardGlassTimelineDemo.app"
executable = application / "Contents/MacOS/ThreadCardGlassTimelineDemo"
link_list = build / "Mokusei.product/Objects.LinkFileList"
if not link_list.is_file():
    raise SystemExit("Build native dependencies first: make build")

executable.parent.mkdir(parents=True, exist_ok=True)
resources = application / "Contents/Resources"
resources.mkdir(exist_ok=True)
shutil.copytree(build / "MokuseiNative_MokuseiPluginUI.bundle",
               resources / "MokuseiNative_MokuseiPluginUI.bundle", dirs_exist_ok=True)
with (application / "Contents/Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "com.mokusei.glass-timeline-demo",
        "CFBundleName": "ThreadCardGlassTimelineDemo",
        "CFBundleDisplayName": "清透时间线预览",
        "CFBundleExecutable": "ThreadCardGlassTimelineDemo",
        "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "26.0",
    }, output)

objects = [line.strip().strip('"') for line in link_list.read_text().splitlines()
           if "/Mokusei.build/" not in line and "/MokuseiUI.build/" not in line]
args = ["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors",
        "-target", "arm64-apple-macosx26.0", "-I", str(build / "Modules"), "-F", str(build),
        "-framework", "LiveKitWebRTC", "-Xlinker", "-rpath", "-Xlinker", str(build)]
for include in [
    package / ".build/checkouts/swift-cmark/src/include",
    package / ".build/checkouts/swift-cmark/extensions/include",
    package / ".build/checkouts/swift-markdown/Sources/CAtomic/include",
    package / ".build/checkouts/swift-system/Sources/CSystem/include",
]:
    args += ["-I", str(include), "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap")]
args += [str(preview / "main.swift"), str(package / "Sources/App/NativeContentHost.swift"),
         *objects, "-o", str(executable)]
result = subprocess.run(args)
if result.returncode:
    raise SystemExit(result.returncode)
print(application)
