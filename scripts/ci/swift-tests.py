"""Summarize both native test frameworks without counting repeated suite totals."""
import json
import os
import re
from pathlib import Path

rows = ["| Run / framework | tests | suites | issues | skipped | executed |",
        "| --- | ---: | ---: | ---: | ---: | ---: |"]
errors = []
results = []
for label, filename in [("Directory tags", "swift-directory-tags.log"),
                        ("Full suite", "swift-tests.log")]:
    path = Path(os.environ["RUNNER_TEMP"]) / filename
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

rows += ["", "tests are framework-reported totals; executed excludes skipped tests.",
         "Directory tags also appear in the full run; do not add the runs together.",
         "Headless / fixture-gated skips are not coverage of native user flows."]
report = "\n".join(rows) + "\n"
destination = Path(os.environ["RUNNER_TEMP"]) / "swift-summary.json"
destination.write_text(json.dumps({"runs": results, "errors": errors}, indent=2) + "\n")
print(report)
with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
    summary.write(report)
    for error in errors:
        summary.write(f"\n- {error}\n")
for error in errors:
    print(f"::error::{error}")
if errors:
    raise SystemExit(1)
