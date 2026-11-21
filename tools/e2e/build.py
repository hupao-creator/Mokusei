#!/usr/bin/env python3
"""Build current production artifacts and bind them to source digests."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from report import save, sha256

ROOT = Path(__file__).resolve().parents[2]


def source_digest():
    paths = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others",
        "--exclude-standard", "cmd", "internal", "app/macos", "go.mod", "go.sum", "scripts/go.sh"], text=True).split("\0")
    files = {name: sha256(ROOT / name) if (ROOT / name).is_file() else None
             for name in sorted(set(paths) - {""}) if not name.endswith(".md")}
    return hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()


def receipt(binary, source, command):
    binary = binary.resolve()
    save(binary.with_name(binary.name + ".e2e.json"), {"version": 1, "sha256": sha256(binary),
         "productionSourceSHA256": source, "command": command,
         "commit": subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()})


def validate(binary):
    path = binary.with_name(binary.name + ".e2e.json")
    if not path.is_file():
        raise ValueError("missing build receipt; build with tools/e2e/build.py")
    value = json.loads(path.read_text())
    if value["sha256"] != sha256(binary) or value["productionSourceSHA256"] != source_digest():
        raise ValueError("artifact or current production sources differ from the build receipt")
    return {"path": str(binary), **value}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", default="go", help="Go executable or scripts/go.sh")
    parser.add_argument("--runtime", type=Path, default=ROOT / ".build/e2e/chief-runtime")
    parser.add_argument("--with-app", action="store_true")
    args = parser.parse_args()
    before = source_digest()
    args.runtime.parent.mkdir(parents=True, exist_ok=True)
    command = [args.go, "build", "-o", str(args.runtime.resolve()), "./cmd/chief-runtime"]
    subprocess.run(command, cwd=ROOT, check=True, timeout=600)
    app_command = ["xcrun", "swift", "build", "--package-path", "app/macos", "-Xswiftc", "-warnings-as-errors"]
    if args.with_app:
        subprocess.run(app_command, cwd=ROOT, check=True, timeout=1200)
    if source_digest() != before:
        raise RuntimeError("production sources changed during build; no receipt issued")
    receipt(args.runtime, before, command)
    if args.with_app:
        receipt(ROOT / "app/macos/.build/debug/Chief", before, app_command)


if __name__ == "__main__":
    main()
