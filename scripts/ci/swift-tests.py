"""Summarize both native test frameworks without counting repeated suite totals."""
import json
import os
import re
from collections import Counter
from pathlib import Path

rows = ["| Run / framework | tests | suites | issues | skipped | executed |",
        "| --- | ---: | ---: | ---: | ---: | ---: |"]
errors = []
results = []
evidence = Path(os.environ.get("MOKUSEI_CI_EVIDENCE", os.environ["RUNNER_TEMP"]))


def one(pattern):
    paths = list(evidence.rglob(pattern))
    if len(paths) != 1:
        errors.append(f"Expected exactly one {pattern}, found {len(paths)}.")
        return None
    return paths[0]


def read_json(path):
    if path is None:
        return None
    try:
        value = json.loads(path.read_text())
        if not isinstance(value, dict):
            raise ValueError("expected an object")
        return value
    except (OSError, ValueError) as error:
        errors.append(f"Invalid {path.name}: {error}")
        return None


# One builder plus five consumers must agree on the exact build/inventory.
manifest_paths = list(evidence.rglob("build-manifest.json"))
manifests = [read_json(path) for path in manifest_paths]
manifest = next((value for value in manifests if value), None)
if len(manifests) != 6 or any(value != manifest for value in manifests) or manifest is None:
    errors.append("Missing or inconsistent builder/consumer manifests.")
if manifest and os.environ.get("GITHUB_SHA", manifest["revision"]) != manifest["revision"]:
    errors.append("Shared build does not belong to the current commit.")
if manifest:
    assigned = [test for shard in manifest["shards"] for test in shard["tests"]]
    if len(assigned) != len(set(assigned)) or sorted(assigned) != manifest["tests"]:
        errors.append("Shard plan omits or duplicates discovered tests.")
receipt_tests = []
observed_tests = []


def terminal_methods(log, inventory):
    """Read framework outcomes, never infer execution from the requested filter."""
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
            outcomes.append((f"{xctest[1]}/{xctest[2]}", xctest[3]))
        testing = re.match(r"^[✔✘] Test (?!run with )(.+?)(?: with \d+ test cases)? (passed|failed) after ", line)
        skipped = re.match(r"^[➜↷✘] Test (.+?) skipped(?:[.:]| because)", line)
        if testing or skipped:
            name = testing[1] if testing else skipped[1]
            status = testing[2] if testing else "skipped"
            candidates = by_name.get(name, [])
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
    "MokuseiSettingsIntegrationTests.NativeBrowserDialogTests/retiringPageCancelsItsSheetAndCompletesExactlyOnce(dialog:retirement:)",
    "MokuseiSettingsIntegrationTests.NativeBrowserDialogTests/hiddenPageCannotPresentNewSheet(dialog:)",
    "MokuseiSettingsIntegrationTests.NativeBrowserDialogTests/acceptedPromptAllowsReentrantNextDialog()",
    "MokuseiSettingsIntegrationTests.NativeBrowserDialogTests/navigationCancellationRejectsReentrantPageDialog(navigateAgain:)",
    "MokuseiSettingsIntegrationTests.NativeApplicationNavigationTests/applicationBackActionSettlesAcrossRedrawLocaleAndRemount(type:)",
    "MokuseiSettingsIntegrationTests.NativeSettingsUserFlows/dailySettingsFlow()",
    "MokuseiSettingsIntegrationTests.NativeOverviewTagGlassTests/directorySelectionResizeKeepsRoundedGlass()",
    "MokuseiSettingsIntegrationTests.NativeOverviewTagGlassTests/shortChildMorphKeepsBothCapsuleEnds()",
}
allowed_skips = swift_launchers | {name.rsplit(".", 1)[0] + "/" + name.rsplit(".", 1)[1] for name in xctest_launchers}
deferred = set()
for shard_index in range(3):
    label = f"Swift shard {shard_index + 1}"
    receipt = read_json(one(f"swift-{shard_index}.json"))
    if receipt is None or receipt.get("status") != "passed" or receipt.get("exit_code") != 0:
        errors.append(f"{label}: missing successful process receipt.")
    if receipt and manifest:
        if (receipt.get("revision") != manifest["revision"] or receipt.get("shard") != shard_index
                or receipt.get("tests") != manifest["shards"][shard_index]["tests"]
                or receipt.get("filter") != manifest["shards"][shard_index]["filter"]):
            errors.append(f"{label}: receipt does not match the complete test inventory.")
        receipt_tests.extend(receipt.get("tests", []))
    start_result = len(results)
    path = one(f"swift-{shard_index}.log")
    if path is None:
        errors.append(f"{label}: no test log; tests did not run.")
        continue
    log = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", path.read_text(errors="replace"))
    if "Requires a logged-in WindowServer session and a display" in log:
        errors.append(f"{label}: native display tests skipped; hosted UI coverage is required.")
    if manifest:
        outcomes = terminal_methods(log, manifest["tests"])
        identities = [name for name, _ in outcomes]
        observed_tests.extend(identities)
        expected = manifest["shards"][shard_index]["tests"]
        if Counter(identities) != Counter(expected):
            errors.append(f"{label}: observed method identities omit, repeat or substitute assigned tests.")
        skipped_names = {name for name, status in outcomes if status == "skipped"}
        deferred.update(skipped_names)
        for name in sorted(skipped_names - allowed_skips):
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
    if manifest and sum(result["tests"] for result in results[start_result:]) != len(manifest["shards"][shard_index]["tests"]):
        errors.append(f"{label}: framework totals do not account for every assigned method.")

if manifest and sorted(receipt_tests) != manifest["tests"]:
    errors.append("Execution receipts do not cover the complete discovered inventory exactly once.")
if manifest and Counter(observed_tests) != Counter(manifest["tests"]):
    errors.append("Observed framework outcomes do not cover the complete inventory exactly once.")

replay_passes = set()
for group in ("fixtures", "interop", "native"):
    replay_path = one("ci-" + group + "/report.json")
    replay = read_json(replay_path)
    if replay is None:
        errors.append(f"{group}: required replay report missing.")
        continue
    if manifest and replay.get("revision") != manifest["revision"]:
        errors.append(f"{group}: replay belongs to a different commit.")
    if replay.get("errors") or not replay["checks"] or any(check["status"] != "passed" for check in replay["checks"]):
        errors.append(f"{group}: required replays failed or did not complete.")
    if manifest and group != "fixtures":
        for check in replay["checks"]:
            path = replay_path.parent / check["log"]
            if not path.is_file():
                errors.append(f"{group}: missing actual replay log {check['log']}.")
                continue
            log = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", path.read_text(errors="replace"))
            replay_passes.update(name for name, status in terminal_methods(log, manifest["tests"]) if status == "passed")

for name in sorted(deferred - replay_passes):
    errors.append(f"Deferred method has no observed passing replay: {name}")

rows += ["", "tests are framework-reported totals; executed excludes skipped tests.",
         "Only named live-fixture/isolated-host methods may defer to the required replay steps.",
         "All discovered methods are assigned once across three shards; directory tags are not repeated.",
         "Display-capability skips fail CI."]
report = "\n".join(rows) + "\n"
destination = Path(os.environ["RUNNER_TEMP"]) / "swift-summary.json"
destination.write_text(json.dumps({"runs": results, "errors": errors,
                                  "discoveredMethods": len(manifest["tests"]) if manifest else None}, indent=2) + "\n")
print(report)
with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
    summary.write(report)
    for error in errors:
        summary.write(f"\n- {error}\n")
for error in errors:
    print(f"::error::{error}")
if errors:
    raise SystemExit(1)
