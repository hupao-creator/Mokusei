"""Link the real Debug MokuseiUI into an isolated native visual replay."""
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess

preview = Path(__file__).resolve().parent
repo = preview.parents[1]
package = repo / "app/macos"
build = package / f".build/{platform.machine()}-apple-macosx/debug"
application = repo / ".build/overview-thread-search/OverviewSearchReplay.app"
executable = application / "Contents/MacOS/OverviewSearchReplay"
link_list = build / "Mokusei.product/Objects.LinkFileList"
if not link_list.is_file():
    raise SystemExit("Build current production modules first: make check")
executable.parent.mkdir(parents=True, exist_ok=True)
resources = application / "Contents/Resources"
resources.mkdir(exist_ok=True)
for bundle in build.glob("*.bundle"):
    shutil.copytree(bundle, resources / bundle.name, dirs_exist_ok=True)
with (application / "Contents/Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "com.mokusei.overview-search-replay",
        "CFBundleName": "OverviewSearchReplay",
        "CFBundleExecutable": "OverviewSearchReplay",
        "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "26.0",
    }, output)
objects = [line.strip().strip('"') for line in link_list.read_text().splitlines()
           if "/Mokusei.build/" not in line]
args = ["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
        "-target", f"{platform.machine()}-apple-macosx26.0", "-I", str(build / "Modules"), "-F", str(build),
        "-framework", "LiveKitWebRTC", "-Xlinker", "-rpath", "-Xlinker", str(build),
        "-module-cache-path", str(application.parent / "ModuleCache")]
platform_developer = Path(subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-platform-path"], text=True).strip()) / "Developer"
testing_frameworks = str(platform_developer / "Library/Frameworks")
toolchain = Path(subprocess.check_output(["/usr/bin/xcrun", "--find", "swiftc"], text=True).strip()).parent.parent
args += ["-plugin-path", str(toolchain / "lib/swift/host/plugins/testing"), "-plugin-path", str(platform_developer / "usr/lib/swift/host/plugins"), "-F", testing_frameworks, "-Xlinker", "-rpath", "-Xlinker", testing_frameworks]
for include in [
    package / ".build/checkouts/swift-cmark/src/include",
    package / ".build/checkouts/swift-cmark/extensions/include",
    package / ".build/checkouts/swift-markdown/Sources/CAtomic/include",
    package / ".build/checkouts/swift-system/Sources/CSystem/include",
]:
    args += ["-I", str(include), "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap")]
result = subprocess.run([*args, str(preview / "main.swift"), str(package / "Tests/Integration/Host/NativeOverviewSearchTests.swift"),
    str(package / "Tests/Integration/Host/SwiftUIReplaySupport.swift"), *objects, "-o", str(executable)])
if result.returncode:
    raise SystemExit(result.returncode)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(application)], check=True)
print(application)
