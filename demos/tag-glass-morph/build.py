"""Build a dependency-free, native macOS 26 Liquid Glass review app."""
from pathlib import Path
import platform
import plistlib
import subprocess

preview = Path(__file__).resolve().parent
repo = preview.parents[1]
application = repo / ".build/tag-glass-morph/TagGlassMorphDemo.app"
executable = application / "Contents/MacOS/TagGlassMorphDemo"
if platform.system() != "Darwin" or int(platform.mac_ver()[0].split(".")[0]) < 26:
    raise SystemExit("This native Liquid Glass preview requires macOS 26+ and Xcode 26+.")
executable.parent.mkdir(parents=True, exist_ok=True)
with (application / "Contents/Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "com.mokusei.tag-glass-morph-demo",
        "CFBundleName": "TagGlassMorphDemo",
        "CFBundleDisplayName": "Tag Glass Morph 预览",
        "CFBundleExecutable": "TagGlassMorphDemo",
        "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "26.0",
    }, output)
subprocess.run([
    "/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors",
    "-parse-as-library", "-target", f"{platform.machine()}-apple-macosx26.0",
    "-module-cache-path", str(application.parent / "ModuleCache"),
    str(preview / "TagGlassMorphDemo.swift"), str(preview / "main.swift"),
    "-o", str(executable),
], check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(application)], check=True)
print(application)
