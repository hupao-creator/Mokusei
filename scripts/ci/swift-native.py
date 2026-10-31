"""Discover and execute the complete ordinary suite from the current Swift build."""
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
from swift_ownership import NATIVE_METHOD_OWNERS, native_filter

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
            "attempt": os.environ.get("GITHUB_RUN_ATTEMPT")}


def prepare():
    # Discover from the binary that will run, then audit observed outcomes against
    # this inventory. A requested command alone is not evidence of execution.
    listed = subprocess.check_output(["xcrun", "swift", "test", "list", "--skip-build", "--package-path", "app/macos"],
                                     cwd=ROOT, text=True).splitlines()
    tests = sorted(line.strip() for line in listed if line.strip())
    if not tests or len(tests) != len(set(tests)) or any("/" not in test or "." not in test.split("/")[0] for test in tests):
        raise RuntimeError("Invalid or empty Swift test inventory")
    if set(NATIVE_METHOD_OWNERS) - set(tests):
        raise RuntimeError("A declared native method is absent from the current Swift inventory")
    ordinary = {"tests": [test for test in tests if test not in NATIVE_METHOD_OWNERS], "skip": native_filter()}
    if [test for test in tests if not re.search(ordinary["skip"], test)] != ordinary["tests"]:
        raise RuntimeError("Swift exclusion does not match the declared native methods")
    manifest = {**identity(), "tests": tests, "ordinary": ordinary, "nativeMethods": NATIVE_METHOD_OWNERS}
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"methods": len(tests), "ordinaryMethods": len(ordinary["tests"]),
                      "nativeMethods": len(NATIVE_METHOD_OWNERS)}))


def verify(evidence):
    manifest = json.loads(MANIFEST.read_text())
    for key, value in identity().items():
        if manifest.get(key) != value:
            raise RuntimeError(f"Current build {key} mismatch: {manifest.get(key)!r} != {value!r}")
    if manifest.get("nativeMethods") != NATIVE_METHOD_OWNERS:
        raise RuntimeError("Current build native method ownership mismatch")
    ordinary = manifest["ordinary"]
    if ordinary.get("skip") != native_filter():
        raise RuntimeError("Current build native method exclusion mismatch")
    assigned = ordinary["tests"] + list(NATIVE_METHOD_OWNERS)
    if len(assigned) != len(set(assigned)) or sorted(assigned) != manifest["tests"]:
        raise RuntimeError("Current build ownership omits or duplicates discovered methods")
    evidence.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(MANIFEST, evidence / "build-manifest.json")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["fingerprint", "prepare", "verify", "run"])
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
    ordinary = manifest["ordinary"]
    receipt = {"revision": manifest["revision"], "tests": ordinary["tests"],
               "skip": ordinary["skip"], "status": "running", "startedAt": time.time()}
    path = args.evidence / "swift.json"
    path.write_text(json.dumps(receipt, indent=2) + "\n")
    command = ["xcrun", "swift", "test", "--skip-build", "--no-parallel", "--package-path", "app/macos",
               "--skip", ordinary["skip"]]
    try:
        with (args.evidence / "swift.log").open("w") as log:
            receipt["exit_code"] = deadline.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        receipt["status"] = "passed" if receipt["exit_code"] == 0 else "failed"
    except (OSError, TimeoutError) as error:
        receipt.update(status="failed", error=str(error))
    finally:
        receipt["finishedAt"] = time.time()
        path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt | {"tests": len(receipt["tests"])}))
    if receipt["status"] != "passed":
        log = args.evidence / "swift.log"
        text = log.read_text(errors="replace") if log.exists() else "No Swift log was captured."
        failures = [line for line in text.splitlines()
                    if re.search(r"recorded an issue|Expectation failed|error:|failed after|failed \(|Incomplete", line)]
        excerpt = "\n".join(failures[:40])[-12000:] if failures else text[-12000:]
        message = f"Ordinary Swift suite: exit={receipt.get('exit_code')}; {receipt.get('error', 'test process failed')}"
        print(message + "\n" + excerpt, flush=True)
        if "GITHUB_STEP_SUMMARY" in os.environ:
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                summary.write(f"\n### Swift failure\n\n{message}\n\n````text\n{excerpt}\n````\n\nFull log: `{log}`\n")
        raise SystemExit(1)


if __name__ == "__main__":
    main()

