"""Capture real go test JSON and report completed, failed, skipped and missing work."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def run(prefix, command):
    prefix.parent.mkdir(parents=True, exist_ok=True)
    record = {"command": command, "exit_code": None}
    prefix.with_suffix(".status.json").write_text(json.dumps(record) + "\n")
    with prefix.with_suffix(".jsonl").open("wb") as output, prefix.with_suffix(".stderr.log").open("wb") as errors:
        try:
            result = subprocess.run(command, stdout=output, stderr=errors)
            record["exit_code"] = result.returncode
        except OSError as error:
            errors.write((str(error) + "\n").encode())
            record["exit_code"] = 127
    prefix.with_suffix(".status.json").write_text(json.dumps(record) + "\n")
    if record["exit_code"]:
        print(prefix.with_suffix(".stderr.log").read_text(errors="replace"), end="")
    return 0 if record["exit_code"] == 0 else 1


def inspect(prefix):
    result = {"run": prefix.name, "errors": []}
    errors = result["errors"]
    status_path = prefix.with_suffix(".status.json")
    log_path = prefix.with_suffix(".jsonl")
    if not status_path.is_file() or not log_path.is_file():
        errors.append("No complete capture: this test command did not run or was interrupted.")
        return result
    try:
        status = json.loads(status_path.read_text())
    except (ValueError, OSError) as error:
        errors.append(f"Invalid command status: {error}")
        return result
    result["exit_code"] = status.get("exit_code")
    tests, packages = {}, {}
    no_test_files, failed_builds = set(), set()
    for number, line in enumerate(log_path.read_text(errors="replace").splitlines(), 1):
        try:
            event = json.loads(line)
            if not isinstance(event, dict) or not isinstance(event.get("Action"), str):
                raise ValueError("expected a go test event object")
        except ValueError as error:
            errors.append(f"Invalid JSON event at line {number}: {error}")
            continue
        action, package, test = event["Action"], event.get("Package"), event.get("Test")
        if action == "build-fail":
            failed_builds.add(event.get("ImportPath", "unknown build"))
        if not package:
            if action not in ("build-output", "build-fail"):
                errors.append(f"Event at line {number} has no package.")
            continue
        packages.setdefault(package, None)
        if not test and "[no test files]" in event.get("Output", ""):
            no_test_files.add(package)
        if test:
            key = (package, test)
            tests.setdefault(key, None)
            target = tests
        else:
            key, target = package, packages
        if action in ("pass", "fail", "skip"):
            if target[key] is not None:
                errors.append(f"Repeated terminal event for {key}; use -count=1.")
            target[key] = action
    failed_tests = [f"{package}: {test}" for (package, test), state in tests.items() if state == "fail"]
    failed_packages = [package for package, state in packages.items() if state == "fail"]
    packages_with_failed_tests = {package for (package, _), state in tests.items() if state == "fail"}
    package_only_failures = set(failed_packages) - packages_with_failed_tests
    incomplete_tests = [f"{package}: {test}" for (package, test), state in tests.items() if state is None]
    incomplete_packages = [package for package, state in packages.items() if state is None]
    result.update({
        "tests": len(tests), "suites": len(packages),
        # Go reports terminal failures, not assertion-level Swift issues.
        # A failed parent and its failed subtest are separate test nodes.
        "failures": len(failed_tests) + len(package_only_failures),
        "skipped": sum(state == "skip" for state in tests.values()),
        "passed": sum(state == "pass" for state in tests.values()),
        "failed_tests": failed_tests, "failed_packages": failed_packages,
        "package_only_failures": sorted(package_only_failures),
        "skipped_packages": sorted(package for package, state in packages.items() if state == "skip" and package not in no_test_files),
        "no_test_packages": sorted(no_test_files), "failed_builds": sorted(failed_builds),
        "incomplete_tests": incomplete_tests, "incomplete_packages": incomplete_packages,
    })
    if status.get("exit_code") != 0:
        errors.append(f"go test exit code: {status.get('exit_code')} (null means interrupted).")
    if failed_tests or failed_packages or failed_builds:
        errors.append("Go reported failed tests, packages or builds; see the named lists in the JSON report.")
    if incomplete_tests or incomplete_packages:
        errors.append("Missing terminal events; partial output cannot certify a successful run.")
    if not tests or not any(state in ("pass", "fail") for state in tests.values()):
        errors.append("No named tests executed; no-test packages and all-skipped runs are not coverage.")
    return result


def report(prefixes, destination):
    results = [inspect(prefix) for prefix in prefixes]
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(results, indent=2) + "\n")
    rows = ["| Go run | tests | suites (packages) | failures | skipped | failed packages | skipped packages | no-test packages | incomplete tests |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for result in results:
        if "tests" not in result:
            rows.append(f"| {result['run']} (not run / no capture) | — | — | — | — | — | — | — | — |")
        else:
            values = [result[key] for key in ("tests", "suites", "failures", "skipped")]
            values += [len(result[key]) for key in ("failed_packages", "skipped_packages", "no_test_packages", "incomplete_tests")]
            rows.append(f"| {result['run']} | " + " | ".join(map(str, values)) + " |")
    for result in results:
        for error in result["errors"]:
            rows.append(f"\n- {result['run']}: {error}")
    rows += ["", "tests/skipped count named test nodes, including parent tests, subtests and examples; -count=1 is required.",
             "suites counts all reported packages, including packages without test files.",
             "failures counts failed test nodes plus failed packages with no failed test node; it is not an assertion/defect count.",
             "Failed parent/subtest nodes remain separately visible. Build/package failures, skips and incomplete work are retained in the JSON report.",
             "Runs overlap (unit/race/properties/platforms); do not add them as unique coverage."]
    text = "\n".join(rows) + "\n"
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(text)
    return 1 if any(result["errors"] for result in results) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    execute = sub.add_parser("run")
    execute.add_argument("prefix", type=Path)
    execute.add_argument("command", nargs=argparse.REMAINDER)
    summarize = sub.add_parser("report")
    summarize.add_argument("--output", type=Path, required=True)
    summarize.add_argument("prefixes", nargs="+", type=Path)
    args = parser.parse_args()
    if args.action == "run":
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not command:
            parser.error("a go test -json command is required")
        return run(args.prefix, command)
    return report(args.prefixes, args.output)


if __name__ == "__main__":
    sys.exit(main())
