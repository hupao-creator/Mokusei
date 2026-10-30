"""Capture or summarize complete XCTest and Swift Testing runs."""
import json
from pathlib import Path
import re
import subprocess
import sys
from swift_ownership import ordinary_filter


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
    rows.append("Headless / fixture-gated skips are not coverage of native user flows.")
    return results, errors, rows


def terminal_methods(log, inventory, errors, *, allow_other=False):
    """Read framework outcomes, never infer execution from the requested filter."""
    log = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", log)
    by_name = {}
    for test in inventory:
        by_name.setdefault(test.split("/", 1)[1], []).append(test)
    current_suites = []
    outcomes = []
    for line in log.splitlines():
        suite = re.match(r"^◇ Suite (.+) started\.", line)
        if suite:
            current_suites.append(suite[1].strip('"'))
        xctest = re.match(r"^Test Case '-\[([^ ]+) ([^\]]+)\]' (passed|failed|skipped) \(", line)
        if xctest:
            identity = f"{xctest[1]}/{xctest[2]}"
            if not allow_other or identity in inventory:
                outcomes.append((identity, xctest[3]))
        testing = re.match(r"^[✔✘] Test (?!run with )(.+?)(?: with \d+ test cases)? (passed|failed) after ", line)
        skipped = re.match(r"^[➜↷✘] Test (.+?) skipped(?:[.:]| because)", line)
        if testing or skipped:
            name = testing[1] if testing else skipped[1]
            status = testing[2] if testing else "skipped"
            candidates = by_name.get(name, [])
            if not candidates and allow_other:
                continue
            if len(candidates) > 1:
                candidates = [test for test in candidates if test.split("/")[0].split(".")[-1] in current_suites]
            if len(candidates) != 1:
                errors.append(f"Cannot identify framework outcome {name!r} unambiguously.")
            else:
                outcomes.append((candidates[0], status))
        finished = re.match(r"^[✔✘] Suite (.+) (?:passed|failed) after ", line)
        if finished and finished[1].strip('"') in current_suites:
            current_suites.remove(finished[1].strip('"'))
    return outcomes


def capture(output_dir):
    repo = Path(__file__).resolve().parents[2]
    command = ["xcrun", "swift", "test", "--package-path", str(repo / "app/macos"),
               "--filter", ordinary_filter()]
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
