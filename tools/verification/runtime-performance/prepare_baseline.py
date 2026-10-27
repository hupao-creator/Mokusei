#!/usr/bin/env python3
"""Prepare a Go source overlay without switching HEAD or touching another tree."""

import argparse
import json
import pathlib
import subprocess


def git(*args):
    return subprocess.check_output(["git", *args])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference")
    parser.add_argument("output", type=pathlib.Path)
    options = parser.parse_args()
    root = pathlib.Path(git("rev-parse", "--show-toplevel").decode().strip())
    revision = git("rev-parse", "--verify", options.reference + "^{commit}").decode().strip()
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    paths = set(git("diff", "--name-only", "-z", revision, "--", "internal").decode().split("\0"))
    paths.update(git("ls-files", "--others", "--exclude-standard", "-z", "--", "internal").decode().split("\0"))
    replacements = {}
    for name in sorted(paths):
        if not name.endswith(".go"):
            continue
        source = root / name
        result = subprocess.run(["git", "show", revision + ":" + name], capture_output=True)
        if result.returncode:
            # Newly added production files must not enter the historical build.
            replacements[str(source)] = ""
            continue
        target = output / "source" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(result.stdout)
        replacements[str(source)] = str(target)
    overlay = output / "overlay.json"
    overlay.write_text(json.dumps({"Replace": replacements}, indent=2) + "\n")
    manifest = {"baseCommit": revision, "worktreeHead": git("rev-parse", "HEAD").decode().strip(),
                "overlay": str(overlay), "productionFiles": sorted(replacements),
                "fixtures": "current worktree, identical for before and after builds"}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(overlay)


if __name__ == "__main__":
    main()
