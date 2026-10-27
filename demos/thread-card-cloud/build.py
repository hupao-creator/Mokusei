"""Build the isolated harness cloud preview using the native Release modules."""
from pathlib import Path
import plistlib
import shutil
import subprocess

preview = Path(__file__).resolve().parent
repo = preview.parents[1]
package = repo / "app/macos"
build = package / ".build/arm64-apple-macosx/release"
application = repo / ".build/thread-card-cloud/ThreadCardCloudDemo.app"
executable = application / "Contents/MacOS/ThreadCardCloudDemo"
link_list = build / "Mokusei.product/Objects.LinkFileList"
if not link_list.is_file():
    raise SystemExit("Build the native dependencies first: make build")

executable.parent.mkdir(parents=True, exist_ok=True)
resources = application / "Contents/Resources"
resources.mkdir(exist_ok=True)
shutil.copytree(build / "MokuseiNative_MokuseiPluginUI.bundle",
               resources / "MokuseiNative_MokuseiPluginUI.bundle", dirs_exist_ok=True)
with (application / "Contents/Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "com.mokusei.threadcardclouddemo",
        "CFBundleName": "ThreadCardCloudDemo",
        "CFBundleDisplayName": "Thread 光云预览",
        "CFBundleExecutable": "ThreadCardCloudDemo",
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
sources = [
    preview / "main.swift",
    preview / "DemoHarness.swift",
    package / "Sources/App/NativeContentHost.swift",
    package / "Sources/Host/Overview/NativeOverviewChrome.swift",
    package / "Sources/Host/Overview/NativeOverviewSelection.swift",
    package / "Sources/Host/Shell/NativeThreadVisibility.swift",
]
args += [*(str(source) for source in sources), *objects, "-o", str(executable)]
result = subprocess.run(args)
if result.returncode:
    raise SystemExit(result.returncode)
print(application)
