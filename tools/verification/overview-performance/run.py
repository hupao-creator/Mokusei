"""Preserve optimized production-linked probes and compare them without rebuild interference."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[2]
PACKAGE = REPO / "app/macos"
OUTPUT = REPO / ".build/overview-performance"


def source_fingerprint():
    digest = hashlib.sha256()
    paths = sorted(path for path in (PACKAGE / "Sources").rglob("*") if path.is_file())
    paths += [PACKAGE / "Package.swift", PACKAGE / "Package.resolved"]
    for path in paths:
        digest.update(str(path.relative_to(REPO)).encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def build(label):
    destination = OUTPUT / label
    destination.mkdir(parents=True, exist_ok=False)
    fingerprint = source_fingerprint()
    probe_source = (SOURCE / "main.swift").read_bytes()
    (destination / "main.swift").write_bytes(probe_source)
    command = ["xcrun", "swift", "build", "--package-path", str(PACKAGE), "-c", "release", "-Xswiftc", "-enable-testing"]
    subprocess.run(command, cwd=REPO, check=True)
    binary = Path(subprocess.check_output([*command, "--show-bin-path"], text=True).strip())
    objects = [line.strip().strip('"') for line in (binary / "Mokusei.product/Objects.LinkFileList").read_text().splitlines()
               if "/Mokusei.build/" not in line]
    args = ["xcrun", "swiftc", "-O", "-g", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
            "-target", f"{platform.machine()}-apple-macosx26.0", "-I", str(binary / "Modules"), "-F", str(binary),
            "-framework", "LiveKitWebRTC", "-Xlinker", "-rpath", "-Xlinker", str(binary),
            "-module-cache-path", str(OUTPUT / "ModuleCache")]
    for relative in ["swift-cmark/src/include", "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include", "swift-system/Sources/CSystem/include"]:
        include = PACKAGE / ".build/checkouts" / relative
        args += ["-I", str(include), "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap")]
    subprocess.run([*args, str(destination / "main.swift"), *objects, "-o", str(destination / "probe")], cwd=REPO, check=True)
    if source_fingerprint() != fingerprint:
        raise RuntimeError("Production sources changed during build; discard this label and build again")
    untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "app/macos/Sources"], text=True).splitlines()
    metadata = {"label": label, "head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                "diff": subprocess.check_output(["git", "diff"], text=True), "command": command,
                "toolchain": subprocess.check_output(["xcrun", "swift", "--version"], text=True),
                "builtAt": time.time(), "probeSourceSHA256": hashlib.sha256(probe_source).hexdigest(),
                "productionSourceSHA256": fingerprint,
                "untrackedSources": {path: (REPO / path).read_text() for path in untracked},
                "binarySHA256": hashlib.sha256((destination / "probe").read_bytes()).hexdigest()}
    (destination / "build.json").write_text(json.dumps(metadata, indent=2))
    print(destination / "probe", flush=True)


def measure(labels, destination, repetitions):
    builds = {label: json.loads((OUTPUT / label / "build.json").read_text()) for label in labels}
    if len({build["probeSourceSHA256"] for build in builds.values()}) != 1:
        raise RuntimeError("Compared probes must use exactly the same workload source")
    for label, metadata in builds.items():
        if hashlib.sha256((OUTPUT / label / "probe").read_bytes()).hexdigest() != metadata["binarySHA256"]:
            raise RuntimeError("Preserved binary changed: " + label)
    destination.mkdir(parents=True, exist_ok=False)
    observations = []
    for repetition in range(repetitions):
        order = labels if repetition % 2 == 0 else labels[::-1]
        for label in order:
            filename = destination / f"r{repetition + 1}-{label}.json"
            # Retain concurrent activity; no competing process is stopped here.
            power_before = subprocess.check_output(["pmset", "-g", "batt"], text=True)
            start = time.time()
            activity = []
            process = subprocess.Popen([str(OUTPUT / label / "probe"), str(filename)], cwd=REPO,
                                       env={**os.environ, "MOKUSEI_PERFORMANCE": "off"})
            try:
                while True:
                    activity.append({"at": time.time(), "processes": subprocess.check_output(
                        ["ps", "-axo", "pid,pcpu,ucomm"], text=True)})
                    try:
                        process.wait(timeout=1)
                        break
                    except subprocess.TimeoutExpired:
                        if time.time() - start > 180:
                            raise TimeoutError("CPU probe exceeded 180 seconds")
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, process.args)
            observations.append({"file": filename.name, "label": label, "repetition": repetition + 1,
                                 "start": start, "end": time.time(), "activity": activity,
                                 "powerBefore": power_before,
                                 "powerAfter": subprocess.check_output(["pmset", "-g", "batt"], text=True),
                                 "build": json.loads((OUTPUT / label / "build.json").read_text())})
            (destination / "observations.json").write_text(json.dumps(observations, indent=2))
            data = json.loads(filename.read_text())
            print(label, repetition + 1, [(r["scenario"], r["count"], round(statistics.median(r["elapsedMs"]), 3))
                                        for r in data["records"] if "elapsedMs" in r and r["count"] == 500], flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    compiler = commands.add_parser("build")
    compiler.add_argument("--label", required=True)
    runner = commands.add_parser("measure")
    runner.add_argument("--labels", required=True)
    runner.add_argument("--output", type=Path, required=True)
    runner.add_argument("--repetitions", type=int, default=5)
    args = parser.parse_args()
    labels = [args.label] if args.command == "build" else args.labels.split(",")
    if not all(label and all(char.isalnum() or char in "-_" for char in label) for label in labels):
        parser.error("Labels must contain only letters, digits, dashes or underscores")
    if args.command == "build":
        build(args.label)
    else:
        measure(labels, args.output.resolve(), args.repetitions)


if __name__ == "__main__":
    main()
