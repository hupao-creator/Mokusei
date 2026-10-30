"""Run a GUI probe from a relocated, self-contained bundle.

The build tree lives under ~/Desktop on the measurement host. LaunchServices
launches from that path intermittently stalled inside dyld while the same
executable launched directly or from /tmp did not. This runner copies the
signed bundle to /tmp, makes the bundled LiveKitWebRTC framework the first
rpath, signs the copy, launches it with `open -n` and then activates it with
`open -a`. The copied executable is byte-identical except for the added rpath
and the bundle identifier; production sources and the original build metadata
are unchanged. Every result records the relocation in its .run.json sidecar.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[2]
BUILD_ROOT = REPO / ".build/overview-scale"
RELOCATED_ROOT = Path("/tmp/MokuseiOverviewScale")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command(args):
    subprocess.run(args, check=True, capture_output=True, text=True)


def prepare(label):
    metadata_path = BUILD_ROOT / label / "build.json"
    metadata = json.loads(metadata_path.read_text())
    original = Path(metadata["bundle"])
    destination = RELOCATED_ROOT / label / "OverviewScaleProbe.app"
    sidecar = RELOCATED_ROOT / label / "relocated.json"
    identity = {"originalExecutableSHA256": metadata.get("bundleExecutableSHA256"),
                "label": label, "relocation": "bundled-rpath"}
    if sidecar.exists() and destination.exists():
        try:
            if json.loads(sidecar.read_text()) == identity:
                return metadata, destination, identity
        except ValueError:
            pass
    RELOCATED_ROOT.mkdir(parents=True, exist_ok=True)
    if destination.parent.exists():
        shutil.rmtree(destination.parent)
    destination.parent.mkdir(parents=True)
    shutil.copytree(original, destination, symlinks=True)
    executable = destination / "Contents/MacOS/OverviewScaleProbe"
    framework = destination / "Contents/Frameworks/LiveKitWebRTC.framework"
    command(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(executable)])
    listing = subprocess.check_output(["otool", "-l", str(executable)], text=True)
    rpaths = []
    lines = listing.splitlines()
    for index, line in enumerate(lines):
        if "LC_RPATH" in line and index + 2 < len(lines):
            candidate = lines[index + 2].strip().split(" ", 1)[-1].split(" (offset")[0]
            if candidate.startswith("/Users/"):
                rpaths.append(candidate)
    for rpath in rpaths:
        command(["install_name_tool", "-delete_rpath", rpath, str(executable)])
    plist = destination / "Contents/Info.plist"
    subprocess.run(["plutil", "-replace", "CFBundleIdentifier", "-string",
                    f"com.mokusei.overview-scale.{label}.relocated", str(plist)], check=True)
    if framework.exists():
        command(["codesign", "--force", "--sign", "-", str(framework)])
    command(["codesign", "--force", "--sign", "-", str(destination)])
    command(["codesign", "--verify", "--deep", "--strict", str(destination)])
    sidecar.write_text(json.dumps(identity, indent=2))
    return metadata, destination, identity


def probe_processes(bundle):
    executable = os.path.realpath(bundle / "Contents/MacOS/OverviewScaleProbe")
    output = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    pids = []
    for line in output.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, invocation = parts
        if invocation.startswith(executable):
            pids.append(int(pid))
    return pids


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("extra", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    extra = args.extra[1:] if args.extra and args.extra[0] == "--" else args.extra
    metadata, bundle, identity = prepare(args.label)
    output = Path(args.output).resolve()
    if output.exists():
        raise SystemExit("Output must be new: " + str(output))
    output.parent.mkdir(parents=True, exist_ok=True)
    command_line = ["open", "-n", str(bundle), "--args", "--mode", args.mode,
                    "--output", str(output), *extra]
    started = time.time()
    subprocess.run(command_line, check=True)
    time.sleep(0.5)
    subprocess.run(["open", "-a", str(bundle)], check=False)
    deadline = started + args.timeout
    failure = ""
    while time.time() < deadline:
        running = probe_processes(bundle)
        if output.exists() and not running:
            break
        if not output.exists() and not running:
            time.sleep(0.5)
            if not probe_processes(bundle) and not output.exists():
                failure = "probe exited without writing its result"
                break
        time.sleep(0.2)
    else:
        failure = "timeout"
    running = probe_processes(bundle)
    if failure:
        for pid in running:
            try:
                os.kill(pid, 15)
            except ProcessLookupError:
                pass
        time.sleep(0.5)
        for pid in probe_processes(bundle):
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
    observation = {
        "command": command_line, "seconds": time.time() - started,
        "output": str(output), "build": metadata,
        "relocated": {"bundle": str(bundle), "identity": identity,
                      "bundleExecutableSHA256": sha256(bundle / "Contents/MacOS/OverviewScaleProbe")},
        "relocationReason": "LaunchServices launches from the Desktop build tree stalled in dyld; "
                            "the relocated copy uses @executable_path/../Frameworks and is activated with open -a.",
        "failure": failure or None,
    }
    (output.parent / (output.name + ".run.json")).write_text(json.dumps(observation, indent=2))
    if failure:
        raise SystemExit(failure)
    result = json.loads(output.read_text())
    if "error" in result:
        raise SystemExit("GUI probe failed: " + str(result["error"]))


if __name__ == "__main__":
    main()
