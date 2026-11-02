"""Reject mislabeled hosts before executing native macOS CI commands.

This checks platform identity, not trust or graphical execution. Review the
exact source before invoking the local CI entry point; see local-macos.md.
"""
import json
import platform
import sys


def main():
    system, machine = platform.system(), platform.machine().lower()
    facts = {"system": system, "machine": machine,
             "python": platform.python_version()}
    errors = []
    if sys.version_info < (3, 11):
        errors.append("CI requires Python 3.11 or later")
    version = platform.mac_ver()[0]
    facts["macOS"] = version
    if system != "Darwin" or machine != "arm64" or version.split(".")[0] != "26":
        errors.append("Native checks require macOS 26 arm64, including Xcode/Metal and a graphical session")
    print(json.dumps(facts, sort_keys=True), flush=True)
    if errors:
        raise SystemExit("; ".join(errors))


if __name__ == "__main__":
    main()
