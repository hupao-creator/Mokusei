"""Partition freshly discovered tests and verify the exact shared Swift build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import time

import deadline

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "app/macos/.build/ci-manifest.json"


def identity():
    commands = [["xcodebuild", "-version"], ["xcrun", "swift", "--version"],
                ["xcrun", "--sdk", "macosx", "--show-sdk-version"], ["xcrun", "--find", "swiftc"]]
    fingerprint = b"".join(subprocess.check_output(command) for command in commands)
    return {"revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "workspace": str(ROOT), "architecture": platform.machine(), "configuration": "debug",
            "toolchain": hashlib.sha256(fingerprint).hexdigest(),
            "run": os.environ.get("GITHUB_RUN_ID"),
            "attempt": os.environ.get("MOKUSEI_SWIFT_BUILD_ATTEMPT", os.environ.get("GITHUB_RUN_ATTEMPT"))}


def prepare():
    # SwiftPM's list subcommand ignores --filter. Partition its full inventory,
    # then verify the run filters independently and check execution counts later.
    listed = subprocess.check_output(["xcrun", "swift", "test", "list", "--skip-build", "--package-path", "app/macos"],
                                     cwd=ROOT, text=True).splitlines()
    tests = sorted(line.strip() for line in listed if line.strip())
    if not tests or len(tests) != len(set(tests)) or any("/" not in test or "." not in test.split("/")[0] for test in tests):
        raise RuntimeError("Invalid or empty Swift test inventory")
    suites = {}
    for test in tests:
        suites.setdefault(test.split("/", 1)[0], []).append(test)
    weights = json.loads((ROOT / "scripts/ci/swift-suite-weights.json").read_text())
    # Account for the real boundary replays sharing each native session. This
    # lets shorter replay lanes consume more Swift work without GUI overlap.
    replays = [("interop-wire", 86), ("interop-process", 98),
               ("native-controls", 104), ("native-capture", 120), ("native-runtime", 121)]
    shards = [{"suites": [], "tests": [], "replay": name, "estimatedSeconds": seconds}
              for name, seconds in replays]
    for suite in sorted(suites, key=lambda name: (-weights.get(name, 1), name)):
        shard = min(shards, key=lambda row: row["estimatedSeconds"])
        shard["suites"].append(suite)
        shard["tests"].extend(suites[suite])
        shard["estimatedSeconds"] += weights.get(suite, 1)
    for shard in shards:
        shard["filter"] = "^(?:" + "|".join(re.escape(suite) for suite in shard["suites"]) + ")/"
        shard["tests"].sort()
    if any(sum(bool(re.search(shard["filter"], test)) for shard in shards) != 1 for test in tests):
        raise RuntimeError("Swift filters omit or duplicate discovered methods")
    manifest = {**identity(), "tests": tests, "shards": shards}
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"methods": len(tests), "suites": len(suites),
                      "shards": [{"methods": len(row["tests"]), "estimatedSeconds": row["estimatedSeconds"]} for row in shards]}))


def verify(evidence):
    deadline.remaining()
    manifest = json.loads(MANIFEST.read_text())
    for key, value in identity().items():
        if manifest.get(key) != value:
            raise RuntimeError(f"Shared build {key} mismatch: {manifest.get(key)!r} != {value!r}")
    evidence.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(MANIFEST, evidence / "build-manifest.json")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["fingerprint", "prepare", "verify", "run"])
    parser.add_argument("--shard", type=int, choices=range(5))
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.mode == "fingerprint":
        print(identity()["toolchain"])
        return
    if args.mode == "prepare":
        prepare()
        return
    if args.evidence is None:
        parser.error("--evidence is required")
    manifest = verify(args.evidence)
    if args.mode == "verify":
        return
    if args.shard is None:
        parser.error("--shard is required")
    shard = manifest["shards"][args.shard]
    receipt = {"revision": manifest["revision"], "shard": args.shard, "tests": shard["tests"],
               "filter": shard["filter"], "status": "running", "startedAt": time.time()}
    path = args.evidence / f"swift-{args.shard}.json"
    path.write_text(json.dumps(receipt, indent=2) + "\n")
    command = ["xcrun", "swift", "test", "--skip-build", "--no-parallel", "--package-path", "app/macos",
               "--filter", shard["filter"]]
    try:
        with (args.evidence / f"swift-{args.shard}.log").open("w") as log:
            receipt["exit_code"] = deadline.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        receipt["status"] = "passed" if receipt["exit_code"] == 0 else "failed"
    finally:
        receipt["finishedAt"] = time.time()
        path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt | {"tests": len(receipt["tests"])}))
    if receipt["status"] != "passed":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
