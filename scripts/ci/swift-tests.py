"""Summarize both native test frameworks without counting repeated suite totals."""
import json
import os
import re
from pathlib import Path

rows = ["| Run / framework | tests | suites | issues | skipped | executed |",
        "| --- | ---: | ---: | ---: | ---: | ---: |"]
errors = []
results = []
# These methods run under their live Go fixture or isolated AppKit launcher in
# the required replay steps below. No capability or newly introduced skip is
# allowed to turn a partial Swift run into complete CI coverage.
xctest_launchers = {
    "MokuseiCoreTests.GoDeltaInteropTests.testGoGeneratedDeltasReconstructNativeContent",
    "MokuseiCoreTests.IntegerWireTests.testExportActualSwiftRequestsToGo",
    "MokuseiCoreTests.RuntimeHostFilesInteropTests.testNativeUploadsAndDownloadsCrossTheGoTransportBoundary",
    "MokuseiCoreTests.RuntimeSettingsCapacityInteropTests.testColdSettingsBurstAndCancellation",
    "MokuseiCoreTests.RuntimeShutdownInteropTests.testCanonicalProfileIdentity",
    "MokuseiCoreTests.RuntimeShutdownInteropTests.testStaleDiscoveryRecovery",
    "MokuseiCoreTests.RuntimeShutdownInteropTests.testReopenAfterFailedShutdown",
    "MokuseiGitIntegrationTests.PiTokenUsageTests.testGoUsageProjectionsReachNativeCardAndExecutionUsage",
}
swift_launchers = {
    "retiringPageCancelsItsSheetAndCompletesExactlyOnce(dialog:retirement:)",
    "hiddenPageCannotPresentNewSheet(dialog:)",
    "acceptedPromptAllowsReentrantNextDialog()",
    "navigationCancellationRejectsReentrantPageDialog(navigateAgain:)",
    "applicationBackActionSettlesAcrossRedrawLocaleAndRemount(type:)",
    "dailySettingsFlow()",
    "directorySelectionResizeKeepsRoundedGlass()",
    "shortChildMorphKeepsBothCapsuleEnds()",
}
for label, filename in [("Full suite", "swift-tests.log")]:
    path = Path(os.environ["RUNNER_TEMP"]) / filename
    if not path.is_file():
        errors.append(f"{label}: no test log; tests did not run.")
        continue
    log = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", path.read_text(errors="replace"))
    if "Requires a logged-in WindowServer session and a display" in log:
        errors.append(f"{label}: native display tests skipped; hosted UI coverage is required.")
    skipped_xctest = {f"{suite}.{method}" for suite, method in re.findall(
        r"Test Case '-\[([^ ]+) ([^\]]+)\]' skipped", log)}
    skipped_swift = set(re.findall(r"(?m)^[➜↷✘] Test (.+?) skipped(?:[.:]| because)", log))
    for name in sorted((skipped_xctest - xctest_launchers) | (skipped_swift - swift_launchers)):
        errors.append(f"{label}: unexpected skip: {name}")
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

for group in ("fixtures", "interop", "native"):
    path = Path(os.environ["RUNNER_TEMP"]) / ("ci-" + group) / "report.json"
    if not path.is_file():
        errors.append(f"{group}: required replay report missing.")
        continue
    replay = json.loads(path.read_text())
    if replay.get("errors") or not replay["checks"] or any(check["status"] != "passed" for check in replay["checks"]):
        errors.append(f"{group}: required replays failed or did not complete.")

rows += ["", "tests are framework-reported totals; executed excludes skipped tests.",
         "Only named live-fixture/isolated-host methods may defer to the required replay steps.",
         "Directory tags execute once in the full suite. Display-capability skips fail CI."]
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
