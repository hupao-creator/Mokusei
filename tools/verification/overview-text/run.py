"""Capture production overview text at controlled scales in an isolated own window."""
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import uuid

source = Path(__file__).resolve().parent
repo = source.parents[2]
package = repo / "app/macos"
output = repo / ".build/overview-text"
destination = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else output / "captures"
destination.mkdir(parents=True, exist_ok=True)
bundle = output / "OverviewTextReplay.app"
build_command = ["xcrun", "swift", "build", "--package-path", str(package)]
subprocess.run(build_command, cwd=repo, check=True)
build = Path(subprocess.check_output([*build_command, "--show-bin-path"], cwd=repo, text=True).strip())
objects = [line.strip().strip('"') for line in (build / "Mokusei.product/Objects.LinkFileList").read_text().splitlines()
           if "/Mokusei.build/" not in line]
macos = bundle / "Contents/MacOS"
resources = bundle / "Contents/Resources"
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
(bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleExecutable": "OverviewTextReplay",
    "CFBundleIdentifier": "com.mokusei.overview-text." + uuid.uuid4().hex,
    "CFBundleName": "Overview Text Replay", "CFBundlePackageType": "APPL",
    "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "26.0",
    "OutputDirectory": str(destination),
}))
resource = resources / "MokuseiNative_MokuseiPluginUI.bundle"
if resource.is_symlink():
    resource.unlink()
shutil.copytree(build / resource.name, resource, dirs_exist_ok=True)
executable = macos / "OverviewTextReplay"
compiler = ["xcrun", "swiftc", "-g", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
            "-target", f"{platform.machine()}-apple-macosx26.0", "-I", str(build / "Modules"), "-F", str(build),
            "-framework", "LiveKitWebRTC", "-Xlinker", "-rpath", "-Xlinker", str(build),
            "-module-cache-path", str(output / "ModuleCache")]
for include in [package / ".build/checkouts/swift-cmark/src/include",
                package / ".build/checkouts/swift-cmark/extensions/include",
                package / ".build/checkouts/swift-markdown/Sources/CAtomic/include",
                package / ".build/checkouts/swift-system/Sources/CSystem/include"]:
    compiler += ["-I", str(include), "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap")]
subprocess.run([*compiler, str(source / "main.swift"), *objects, "-o", str(executable)], cwd=repo, check=True)
subprocess.run([str(executable)], cwd=repo, check=True, timeout=90)
print(destination)
