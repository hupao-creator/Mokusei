"""Build the isolated macOS material proposal using production capsule sources."""
from pathlib import Path
import platform
import plistlib
import subprocess

preview = Path(__file__).resolve().parent
repo = preview.parents[1]
application = repo / ".build/moku-gradient-material/MokuGradientMaterialDemo.app"
executable = application / "Contents/MacOS/MokuGradientMaterialDemo"
if platform.system() != "Darwin" or int(platform.mac_ver()[0].split(".")[0]) < 26:
    raise SystemExit("Requires macOS 26+ and Xcode 26+.")
executable.parent.mkdir(parents=True, exist_ok=True)
build = application.parent
sources = repo / "app/macos/Sources"
flags = [
    "/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors",
    "-parse-as-library", "-target", f"{platform.machine()}-apple-macosx26.0",
    "-module-cache-path", str(build / "ModuleCache"),
]
# Compile the unmodified platform bridge as a minimal module. This keeps the
# real capsule and eyes available without linking the runtime or voice stack.
subprocess.run([
    *flags, "-module-name", "MokuseiPluginUI", "-emit-module", "-emit-object",
    "-emit-module-path", str(build / "MokuseiPluginUI.swiftmodule"),
    str(sources / "Shared/PluginUI/Design/NativePlatform.swift"),
    "-o", str(build / "NativePlatform.o"),
], check=True)
subprocess.run([
    *flags, "-I", str(build), str(build / "NativePlatform.o"),
    str(sources / "Host/Moku/MokuGeometry.swift"),
    str(sources / "Host/MokuScene/NativeMokuCapsule.swift"),
    str(preview / "MokuGradientDemo.swift"), str(preview / "main.swift"),
    "-o", str(executable),
], check=True)
with (application / "Contents/Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "com.mokusei.gradient-material-demo",
        "CFBundleName": "MokuGradientMaterialDemo",
        "CFBundleDisplayName": "Moku 材质预览",
        "CFBundleExecutable": executable.name,
        "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "26.0",
    }, output)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(application)], check=True)
print(application)
