"""Capture or summarize complete XCTest and Swift Testing runs."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def summarize(logs):
    rows = ["| Run / framework | tests | suites | issues | skipped | executed |",
            "| --- | ---: | ---: | ---: | ---: | ---: |"]
    errors = []
    results = []
    for label, path in logs:
        if not path.is_file():
            errors.append(f"{label}: no test log; tests did not run.")
            continue
        log = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", path.read_text(errors="replace"))
        executed = 0

        # Read only XCTest's final aggregate, not each repeated suite total.
        xctest = re.search(
            r"Test Suite '(?:All|Selected) tests' (passed|failed)[^\n]*\n"
            r"\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", log)
        if not xctest:
            errors.append(f"{label}: missing XCTest completion summary.")
        else:
            status, tests, skipped, issues = xctest.groups()
            tests, skipped, issues = int(tests), int(skipped or 0), int(issues)
            suites = {name for name in re.findall(r"Test Suite '([^']+)' started", log)
                      if name not in ("All tests", "Selected tests") and not name.endswith(".xctest")}
            ran = tests - skipped
            cases = re.findall(r"(?m)^Test Case '[^\n]+' (passed|failed|skipped) \(", log)
            if len(cases) != tests or cases.count("skipped") != skipped:
                errors.append(f"{label}: incomplete XCTest case/skip records.")
            executed += ran
            results.append({"run": label, "framework": "XCTest", "tests": tests,
                            "suites": len(suites), "failures": issues, "skipped": skipped,
                            "executed": ran, "status": status})
            rows.append(f"| {label} / XCTest | {tests} | {len(suites)} | {issues} | {skipped} | {ran} |")
            if issues or status != "passed":
                errors.append(f"{label}: XCTest failed ({issues} issues).")

        testing = re.search(
            r"Test run with (\d+) tests?(?: in (\d+) suites?)? (passed|failed) after ([^\n]+)", log)
        if not testing:
            errors.append(f"{label}: missing Swift Testing completion summary.")
        else:
            tests, suites, status, detail = testing.groups()
            tests, suites = int(tests), int(suites or 0)
            issue_count = re.search(r"with (\d+) (?:known )?issues?", detail)
            issues = int(issue_count[1]) if issue_count else (0 if status == "passed" else None)
            skipped = len(re.findall(r"(?m)^[➜↷✘] Test [^\n]* skipped(?:[.:]| because)", log))
            ran = len(re.findall(r"(?m)^[✔✘] Test (?!run with )[^\n]* (?:passed|failed) after ", log))
            executed += ran
            results.append({"run": label, "framework": "Swift Testing", "tests": tests,
                            "suites": suites, "issues": issues, "skipped": skipped,
                            "executed": ran, "status": status})
            rows.append(f"| {label} / Swift Testing | {tests} | {suites} | {issues} | {skipped} | {ran} |")
            if ran + skipped != tests:
                errors.append(f"{label}: incomplete Swift Testing counts ({ran} executed + {skipped} skipped != {tests} tests).")
            if tests and not ran:
                errors.append(f"{label}: all Swift Testing methods skipped.")
            if issues or status != "passed":
                errors.append(f"{label}: Swift Testing failed ({issues} issues).")

        if executed <= 0:
            errors.append(f"{label}: no tests executed (skips do not count).")

    rows += ["", "tests are framework-reported totals; executed excludes skipped tests."]
    if len(logs) > 1:
        rows.append("Directory tags also appear in the full run; do not add the runs together.")
    rows.append("Headless / fixture-gated skips are not coverage of native user flows.")
    return results, errors, rows


def capture(output_dir):
    repo = Path(__file__).resolve().parents[2]
    command = ["xcrun", "swift", "test", "--package-path", str(repo / "app/macos")]
    path = output_dir / "swift-tests.log"
    status = output_dir / "swift-status.json"
    record = {"command": command, "exit_code": None, "log": str(path)}
    status.write_text(json.dumps(record, indent=2) + "\n")
    with path.open("wb") as log:
        try:
            with subprocess.Popen(command, cwd=repo, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, bufsize=0) as process:
                while chunk := process.stdout.read(64 * 1024):
                    log.write(chunk)
                    log.flush()
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                record["exit_code"] = process.wait()
        except OSError as error:
            log.write((str(error) + "\n").encode())
            record["exit_code"] = 127
    status.write_text(json.dumps(record, indent=2) + "\n")
    return path, record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--run", action="store_true", help="Run and stream the complete local Swift suite")
    mode.add_argument("--full-log", type=Path, help="Validate an existing full-suite capture")
    parser.add_argument("--exit-code", type=int, help="Actual process status for --full-log")
    parser.add_argument("--output-dir", type=Path, help="Local logs and JSON summary directory (default: .build/check-swift)")
    args = parser.parse_args()
    ci = not args.run and args.full_log is None
    if args.full_log is not None and args.exit_code is None:
        parser.error("--full-log requires its actual --exit-code")
    if args.full_log is None and args.exit_code is not None:
        parser.error("--exit-code requires --full-log")
    if ci and args.output_dir is not None:
        parser.error("--output-dir requires --run or --full-log")

    record = None
    if ci:
        output_dir = Path(os.environ["RUNNER_TEMP"])
        logs = [("Directory tags", output_dir / "swift-directory-tags.log"),
                ("Full suite", output_dir / "swift-tests.log")]
    else:
        output_dir = (args.output_dir or Path(".build/check-swift")).resolve()
        output_dir.mkdir(parents=True, exist_ok=True)
        if args.run:
            path, record = capture(output_dir)
        else:
            path = args.full_log.resolve()
            record = {"command": None, "exit_code": args.exit_code, "log": str(path)}
        logs = [("Full suite", path)]

    results, errors, rows = summarize(logs)
    if record is not None and record["exit_code"] != 0:
        errors.append(f"Full suite: swift test exit code {record['exit_code']} (null means interrupted).")
    data = {"runs": results, "errors": errors}
    if record is not None:
        data["capture"] = record
    (output_dir / "swift-summary.json").write_text(json.dumps(data, indent=2) + "\n")
    report = "\n".join(rows) + "\n"
    print(report)
    if ci:
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(report)
            for error in errors:
                summary.write(f"\n- {error}\n")
    for error in errors:
        print(("::error::" if ci else "ERROR: ") + error)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
