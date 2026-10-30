"""Build and run the Overview card-count scale harness.

Formal builds use Release -O without per-frame diagnostics. Diagnostic builds
add OVERVIEW_PERF_DIAGNOSTICS to count TimelineView callbacks, motion samples,
projection cache hits and layout comparison work. GUI runs use an isolated
ad-hoc-signed bundle and write their own JSON evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import sys
import time

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[2]
PACKAGE = REPO / "app/macos"
OUTPUT = REPO / ".build/overview-scale"
SWIFT_SOURCES = [SOURCE / "main.swift", SOURCE / "ScaleSupport.swift"]


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, command, result.stdout, result.stderr)


def source_fingerprint():
    digest = hashlib.sha256()
    paths = sorted(path for path in (PACKAGE / "Sources").rglob("*") if path.is_file())
    paths += [PACKAGE / "Package.swift", PACKAGE / "Package.resolved"]
    for path in paths:
        digest.update(str(path.relative_to(REPO)).encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def build(label, diagnostics):
    destination = OUTPUT / label
    destination.mkdir(parents=True, exist_ok=True)
    scratch = REPO / ".build" / f"overview-scale-{label}"
    build_command = ["xcrun", "swift", "build", "--package-path", str(PACKAGE), "-c", "release",
                     "-Xswiftc", "-enable-testing", "--scratch-path", str(scratch)]
    if diagnostics:
        build_command += ["-Xswiftc", "-DOVERVIEW_PERF_DIAGNOSTICS"]
    fingerprint = source_fingerprint()
    run(build_command, cwd=REPO)
    binary = Path(subprocess.check_output([*build_command, "--show-bin-path"], cwd=REPO, text=True).strip())
    objects = [line.strip().strip('"') for line in (binary / "Mokusei.product/Objects.LinkFileList").read_text().splitlines()
               if "/Mokusei.build/" not in line]
    arguments = ["xcrun", "swiftc", "-O", "-g", "-swift-version", "6", "-parse-as-library",
                 "-target", f"{platform.machine()}-apple-macosx26.0",
                 "-I", str(binary / "Modules"), "-F", str(binary),
                 "-framework", "LiveKitWebRTC", "-Xlinker", "-rpath", "-Xlinker", str(binary),
                 "-module-cache-path", str(OUTPUT / "ModuleCache")]
    if diagnostics:
        arguments += ["-DOVERVIEW_PERF_DIAGNOSTICS"]
    for include in ["swift-cmark/src/include", "swift-cmark/extensions/include",
                    "swift-markdown/Sources/CAtomic/include", "swift-system/Sources/CSystem/include"]:
        path = PACKAGE / ".build/checkouts" / include
        arguments += ["-I", str(path), "-Xcc", "-fmodule-map-file=" + str(path / "module.modulemap")]
    executable = destination / "OverviewScaleProbe"
    run([*arguments, *[str(path) for path in SWIFT_SOURCES], *objects, "-o", str(executable)], cwd=REPO)
    if source_fingerprint() != fingerprint:
        raise RuntimeError("Production sources changed during build; discard this label and build again")

    bundle = destination / "OverviewScaleProbe.app"
    if bundle.exists():
        shutil.rmtree(bundle)
    macos = bundle / "Contents" / "MacOS"
    resources = bundle / "Contents" / "Resources"
    frameworks = bundle / "Contents" / "Frameworks"
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)
    frameworks.mkdir()
    (bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "OverviewScaleProbe",
        "CFBundleIdentifier": f"com.mokusei.overview-scale.{label}.{os.getpid()}",
        "CFBundleName": "Overview Scale Probe", "CFBundlePackageType": "APPL",
        "NSPrincipalClass": "NSApplication", "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "26.0"}))
    resource_bundle = binary / "MokuseiNative_MokuseiPluginUI.bundle"
    if resource_bundle.exists():
        shutil.copytree(resource_bundle, resources / resource_bundle.name)
    framework = binary / "LiveKitWebRTC.framework"
    if framework.exists():
        shutil.copytree(framework, frameworks / framework.name, symlinks=True)
    shutil.copy2(executable, macos / "OverviewScaleProbe")
    run(["codesign", "--force", "--sign", "-", str(frameworks / "LiveKitWebRTC.framework")], cwd=destination) \
        if framework.exists() else None
    run(["codesign", "--force", "--sign", "-", str(bundle)], cwd=destination)

    untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "app/macos/Sources"],
                                       text=True, cwd=REPO).splitlines()
    metadata = {
        "label": label, "diagnostics": diagnostics,
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
        "diff": subprocess.check_output(["git", "diff"], cwd=REPO, text=True),
        "diffSHA256": hashlib.sha256(subprocess.check_output(["git", "diff"], cwd=REPO)).hexdigest(),
        "buildCommand": build_command, "linkCommand": [str(part) for part in arguments],
        "toolchain": subprocess.check_output(["xcrun", "swift", "--version"], cwd=REPO, text=True),
        "sources": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in SWIFT_SOURCES},
        "productionSourceSHA256": fingerprint,
        "untrackedSources": {path: (REPO / path).read_text() for path in untracked},
        "binarySHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "bundleExecutableSHA256": hashlib.sha256((macos / "OverviewScaleProbe").read_bytes()).hexdigest(),
        "bundle": str(bundle), "builtAt": time.time(),
        "hardware": {key: subprocess.check_output(["sysctl", "-n", key], text=True).strip()
                     for key in ["hw.model", "machdep.cpu.brand_string", "hw.memsize", "hw.logicalcpu"]},
        "os": subprocess.check_output(["sw_vers"], text=True),
        "power": subprocess.check_output(["pmset", "-g", "batt"], text=True),
        "templates": subprocess.run(["xcrun", "xctrace", "list", "templates"], capture_output=True, text=True).stdout,
    }
    (destination / "build.json").write_text(json.dumps(metadata, indent=2))
    print(executable)
    print(bundle)


def load_build(label):
    metadata = json.loads((OUTPUT / label / "build.json").read_text())
    executable = OUTPUT / label / "OverviewScaleProbe"
    if hashlib.sha256(executable.read_bytes()).hexdigest() != metadata["binarySHA256"]:
        raise RuntimeError("Preserved executable changed")
    for path in SWIFT_SOURCES:
        if hashlib.sha256(path.read_bytes()).hexdigest() != metadata["sources"][path.name]:
            raise RuntimeError("Harness source changed after build: " + path.name)
    return metadata, executable, Path(metadata["bundle"])


def run_direct(label, mode, output, extra):
    if extra and extra[0] == "--":
        extra = extra[1:]
    metadata, executable, _ = load_build(label)
    output = Path(output).resolve()
    if output.exists():
        raise SystemExit("Output must be new: " + str(output))
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [str(executable), "--mode", mode, "--output", str(output), *extra]
    started = time.time()
    result = subprocess.run(command, cwd=REPO)
    observation = {"command": command, "exit": result.returncode, "seconds": time.time() - started,
                   "output": str(output), "build": metadata}
    (output.parent / (output.name + ".run.json")).write_text(json.dumps(observation, indent=2))
    if result.returncode:
        raise SystemExit(result.returncode)


def run_gui(label, mode, output, extra, timeout):
    if extra and extra[0] == "--":
        extra = extra[1:]
    metadata, _, bundle = load_build(label)
    output = Path(output).resolve()
    if output.exists():
        raise SystemExit("Output must be new: " + str(output))
    output.parent.mkdir(parents=True, exist_ok=True)
    command = ["open", "-n", "-W", str(bundle), "--args", "--mode", mode, "--output", str(output), *extra]
    started = time.time()
    process = subprocess.Popen(command, cwd=REPO)
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        subprocess.run(["pkill", "-f", str(bundle / "Contents/MacOS/OverviewScaleProbe")])
        process.wait(timeout=20)
        raise
    observation = {"command": command, "exit": process.returncode, "seconds": time.time() - started,
                   "output": str(output), "build": metadata,
                   "environment": subprocess.check_output(["pmset", "-g", "batt"], text=True)}
    (output.parent / (output.name + ".run.json")).write_text(json.dumps(observation, indent=2))
    if process.returncode:
        raise SystemExit(process.returncode)
    if not output.exists():
        raise SystemExit("GUI probe did not write its result")
    result = json.loads(output.read_text())
    if "error" in result:
        raise SystemExit("GUI probe failed: " + str(result["error"]))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    builder = sub.add_parser("build")
    builder.add_argument("--label", required=True)
    builder.add_argument("--diagnostics", action="store_true")
    runner = sub.add_parser("run")
    runner.add_argument("--label", required=True)
    runner.add_argument("--mode", required=True)
    runner.add_argument("--output", required=True)
    runner.add_argument("extra", nargs=argparse.REMAINDER)
    gui = sub.add_parser("gui")
    gui.add_argument("--label", required=True)
    gui.add_argument("--mode", required=True)
    gui.add_argument("--output", required=True)
    gui.add_argument("--timeout", type=float, default=600)
    gui.add_argument("extra", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.command == "build":
        build(arguments.label, arguments.diagnostics)
    elif arguments.command == "run":
        run_direct(arguments.label, arguments.mode, arguments.output, arguments.extra)
    else:
        run_gui(arguments.label, arguments.mode, arguments.output, arguments.extra, arguments.timeout)


if __name__ == "__main__":
    main()
