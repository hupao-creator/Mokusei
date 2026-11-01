"""Build isolated Debug functional SwiftUI replays.

Links only this worktree's production objects. Starts no Mokusei runtime and
posts no global input; only the fixture's own state and window are operated.
"""
from pathlib import Path
import json
import os
import platform
import plistlib
import shutil
import sys
import tempfile
import uuid
import subprocess


def main():
    source = Path(__file__).resolve().parent
    repo = source.parents[2]
    package = repo / "app/macos"
    output = repo / ".build/overview-input"
    output.mkdir(parents=True, exist_ok=True)
    retired = {"--glass-world", "--glass-performance", "--run-built", "--performance-smoke"}
    if retired.intersection(sys.argv):
        raise SystemExit("The glass on/off replay is retired: Overview cards are always flat. Use --card-materials for appearance verification; see PERFORMANCE.md for historical analysis.")
    build_command = ["xcrun", "swift", "build", "--package-path", str(package)]
    subprocess.run(build_command, cwd=repo, check=True)
    build = Path(subprocess.check_output([*build_command, "--show-bin-path"], cwd=repo, text=True).strip())
    objects = [line.strip().strip('"') for line in (build / "Mokusei.product/Objects.LinkFileList").read_text().splitlines()
               if "/Mokusei.build/" not in line]
    capture_destination = None
    if "--capture-transitions" in sys.argv:
        capture_destination = Path(sys.argv[sys.argv.index("--capture-transitions") + 1]).resolve()
    materials_destination = None
    if "--card-materials" in sys.argv:
        materials_destination = Path(sys.argv[sys.argv.index("--card-materials") + 1]).resolve()
    if capture_destination and materials_destination:
        raise SystemExit("Choose one capture mode")
    # Only the authorized build driver touches the checkout. LaunchServices apps
    # have their own TCC identity, even when the invoking terminal can read Desktop.
    # Do not honor TMPDIR here: callers may have placed it inside the checkout.
    run = Path(tempfile.mkdtemp(prefix="mokusei-overview-", dir="/private/tmp"))
    capture_dir = run / "capture" if capture_destination else None
    if capture_dir:
        capture_dir.mkdir()
    materials_dir = run / "card-materials" if materials_destination else None
    if materials_dir:
        materials_dir.mkdir()
    result = run / "result.txt"
    (output / "result-path.txt").write_text(str(result))
    bundle = run / "OverviewInputReplay.app"
    (output / "app-path.txt").write_text(str(bundle))
    macos = bundle / "Contents/MacOS"
    resources = bundle / "Contents/Resources"
    macos.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "OverviewInputReplay",
        # Keep macOS saved-window restoration from resizing a fresh replay after
        # its first layout. Each run already owns a fresh result file as well.
        "CFBundleIdentifier": f"com.mokusei.overview-swiftui-replay.{uuid.uuid4().hex}",
        "CFBundleName": "Overview SwiftUI Replay", "CFBundlePackageType": "APPL",
        "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "26.0",
        "MokuseiReplayResult": str(result),
        "MokuseiCardMaterialsDirectory": str(materials_dir) if materials_dir else "",
        "MokuseiTransitionCaptureDirectory": str(capture_dir) if capture_dir else "", "MokuseiReplayInteractive": "--interactive" in sys.argv,
    }))
    resource = resources / "MokuseiNative_MokuseiPluginUI.bundle"
    shutil.copytree(build / resource.name, resource)
    frameworks = bundle / "Contents/Frameworks"
    frameworks.mkdir()
    shutil.copytree(build / "LiveKitWebRTC.framework", frameworks / "LiveKitWebRTC.framework", symlinks=True)
    # Framework version links are relative and stay inside this private bundle.
    for path in bundle.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(bundle):
            raise RuntimeError(f"Replay dependency escapes its bundle: {path}")
    executable = macos / "OverviewInputReplay"
    args = ["xcrun", "swiftc", "-g", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
            "-target", f"{platform.machine()}-apple-macosx26.0", "-I", str(build / "Modules"), "-F", str(build),
            "-framework", "LiveKitWebRTC", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
            "-module-cache-path", str(output / "ModuleCache")]
    for include in [package / ".build/checkouts/swift-cmark/src/include",
                    package / ".build/checkouts/swift-cmark/extensions/include",
                    package / ".build/checkouts/swift-markdown/Sources/CAtomic/include",
                    package / ".build/checkouts/swift-system/Sources/CSystem/include"]:
        args += ["-I", str(include), "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap")]
    replay_source = "card-materials.swift" if materials_dir else "capture.swift" if capture_dir else "main.swift"
    shared = [str(source / "card-materials-fixture.swift")] if materials_dir else []
    subprocess.run([*args, str(source / "environment.swift"), str(source / "gestures.swift"), str(source / replay_source), *shared, *objects, "-o", str(executable)], cwd=repo, check=True)
    # Local fixture signing only; no production identity or privacy entitlements.
    subprocess.run(["codesign", "--force", "--sign", "-", str(frameworks / "LiveKitWebRTC.framework")], cwd=run, check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], cwd=run, check=True)
    print(f"Replay app: {bundle}\nReplay result: {result}", flush=True)
    if "--build-only" in sys.argv:
        print(bundle)
        return
    result.unlink(missing_ok=True)
    # A SwiftUI App receives its open-scene event through Launch Services.
    subprocess.run(["open", "-n", "-W", str(bundle)], cwd=run, env=os.environ, check=True, timeout=60)
    report = result.read_text()
    print(report, end="")
    if not report.startswith("PASS "):
        raise SystemExit(1)
    launch = json.loads((run / "launch.json").read_text())
    if Path(launch["cwd"]).resolve() != run:
        raise RuntimeError(f"Replay cwd escaped its fixture: {launch['cwd']}")
    for image in launch["images"]:
        if not image.startswith(("/System/", "/usr/lib/")) and not Path(image).resolve().is_relative_to(bundle):
            raise RuntimeError(f"Replay loaded an external dependency: {image}")
    if materials_dir:
        inspector = output / "InspectCardMaterialsCapture"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
                        str(source / "inspect-card-materials.swift"), "-o", str(inspector)], cwd=repo, check=True)
        subprocess.run([str(inspector), str(materials_dir)], cwd=run, check=True)
        materials_destination.mkdir(parents=True, exist_ok=True)
        shutil.copytree(materials_dir, materials_destination, dirs_exist_ok=True)
    if capture_dir:
        inspector = output / "InspectTransitionCapture"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
                        str(source / "inspect-capture.swift"), "-o", str(inspector)], cwd=repo, check=True)
        subprocess.run([str(inspector), str(capture_dir)], cwd=run, check=True)
        capture_destination.mkdir(parents=True, exist_ok=True)
        shutil.copytree(capture_dir, capture_destination, dirs_exist_ok=True)


if __name__ == "__main__":
    main()
