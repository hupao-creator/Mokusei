"""Build isolated Debug functional or Release performance SwiftUI replays.

Links only this worktree's production objects. Starts no Mokusei runtime and
posts no global input; only the fixture's own state and window are operated.
"""
from pathlib import Path
import json
import hashlib
import os
import platform
import plistlib
import shutil
import sys
import tempfile
import uuid
import subprocess

from performance_run import run_performance


def main():
    source = Path(__file__).resolve().parent
    repo = source.parents[2]
    package = repo / "app/macos"
    output = repo / ".build/overview-input"
    output.mkdir(parents=True, exist_ok=True)
    performance_destination = None
    if "--glass-performance" in sys.argv:
        performance_destination = Path(sys.argv[sys.argv.index("--glass-performance") + 1]).resolve()
        if performance_destination.exists():
            raise SystemExit("Performance output must be a new directory")
    if "--run-built" in sys.argv:
        if not performance_destination or "--build-only" in sys.argv:
            raise SystemExit("--run-built requires --glass-performance and cannot build")
        bundle = Path(sys.argv[sys.argv.index("--run-built") + 1])
        run_performance(bundle, performance_destination)
        subprocess.run([sys.executable, str(source / "analyze-performance.py"), str(performance_destination)], check=True)
        return
    build_command = ["xcrun", "swift", "build", "--package-path", str(package)]
    if performance_destination:
        # Testable access only exposes the existing fixture's internal components;
        # optimization remains Release (-O), with no DEBUG code paths.
        build_command += ["-c", "release", "-Xswiftc", "-enable-testing"]
    subprocess.run(build_command, cwd=repo, check=True)
    build = Path(subprocess.check_output([*build_command, "--show-bin-path"], cwd=repo, text=True).strip())
    objects = [line.strip().strip('"') for line in (build / "Mokusei.product/Objects.LinkFileList").read_text().splitlines()
               if "/Mokusei.build/" not in line]
    capture_destination = None
    if "--capture-transitions" in sys.argv:
        capture_destination = Path(sys.argv[sys.argv.index("--capture-transitions") + 1]).resolve()
    glass_destination = None
    if "--glass-world" in sys.argv:
        glass_destination = Path(sys.argv[sys.argv.index("--glass-world") + 1]).resolve()
    if sum(bool(x) for x in [capture_destination, glass_destination, performance_destination]) > 1:
        raise SystemExit("Choose one capture/performance mode")
    # Only the authorized build driver touches the checkout. LaunchServices apps
    # have their own TCC identity, even when the invoking terminal can read Desktop.
    # Do not honor TMPDIR here: callers may have placed it inside the checkout.
    run = Path(tempfile.mkdtemp(prefix="mokusei-overview-", dir="/private/tmp"))
    capture_dir = run / "capture" if capture_destination else None
    if capture_dir:
        capture_dir.mkdir()
    glass_dir = run / "glass" if glass_destination else None
    if glass_dir:
        glass_dir.mkdir()
    performance_dir = run / "performance" if performance_destination else None
    if performance_dir:
        performance_dir.mkdir()
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
        "MokuseiGlassPerformanceSmoke": "--performance-smoke" in sys.argv,
        "MokuseiGlassPerformanceDirectory": str(performance_dir) if performance_dir else "",
        "MokuseiGlassCaptureDirectory": str(glass_dir) if glass_dir else "",
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
    if performance_dir:
        args += ["-O"]
    for include in [package / ".build/checkouts/swift-cmark/src/include",
                    package / ".build/checkouts/swift-cmark/extensions/include",
                    package / ".build/checkouts/swift-markdown/Sources/CAtomic/include",
                    package / ".build/checkouts/swift-system/Sources/CSystem/include"]:
        args += ["-I", str(include), "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap")]
    replay_source = "performance.swift" if performance_dir else "glass.swift" if glass_dir else "capture.swift" if capture_dir else "main.swift"
    shared = [str(source / "glass-fixture.swift")] if glass_dir or performance_dir else []
    subprocess.run([*args, str(source / "environment.swift"), str(source / "gestures.swift"), str(source / replay_source), *shared, *objects, "-o", str(executable)], cwd=repo, check=True)
    # Local fixture signing only; no production identity or privacy entitlements.
    subprocess.run(["codesign", "--force", "--sign", "-", str(frameworks / "LiveKitWebRTC.framework")], cwd=run, check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], cwd=run, check=True)
    if performance_dir:
        provenance = {
            "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
            "sourceDiffSHA256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD"], cwd=repo)).hexdigest(),
            "sources": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in source.glob("*") if p.is_file()},
            "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            "buildCommand": build_command, "linkCommand": [*args, str(source / "environment.swift"), str(source / "gestures.swift"), str(source / replay_source), *shared, *objects, "-o", str(executable)],
            "configuration": "release -O -enable-testing", "bundle": str(bundle),
            "swift": subprocess.check_output(["xcrun", "swift", "--version"], text=True),
            "os": subprocess.check_output(["sw_vers"], text=True),
            "hardware": {key: subprocess.check_output(["sysctl", "-n", key], text=True).strip() for key in ["hw.model", "machdep.cpu.brand_string", "hw.memsize", "hw.logicalcpu"]},
            "power": subprocess.check_output(["pmset", "-g", "batt"], text=True),
            "templates": subprocess.run(["xcrun", "xctrace", "list", "templates"], capture_output=True, text=True).stdout,
        }
        (performance_dir / "build.json").write_text(json.dumps(provenance, indent=2))
    print(f"Replay app: {bundle}\nReplay result: {result}", flush=True)
    if "--build-only" in sys.argv:
        print(bundle)
        return
    result.unlink(missing_ok=True)
    # A SwiftUI App receives its open-scene event through Launch Services.
    if performance_dir:
        run_performance(bundle, performance_destination)
        subprocess.run([sys.executable, str(source / "analyze-performance.py"), str(performance_destination)], check=True)
    else:
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
    if glass_dir:
        inspector = output / "InspectGlassCapture"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
                        str(source / "inspect-glass.swift"), "-o", str(inspector)], cwd=repo, check=True)
        subprocess.run([str(inspector), str(glass_dir)], cwd=run, check=True)
        glass_destination.mkdir(parents=True, exist_ok=True)
        shutil.copytree(glass_dir, glass_destination, dirs_exist_ok=True)
    if capture_dir:
        inspector = output / "InspectTransitionCapture"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
                        str(source / "inspect-capture.swift"), "-o", str(inspector)], cwd=repo, check=True)
        subprocess.run([str(inspector), str(capture_dir)], cwd=run, check=True)
        capture_destination.mkdir(parents=True, exist_ok=True)
        shutil.copytree(capture_dir, capture_destination, dirs_exist_ok=True)


if __name__ == "__main__":
    main()
