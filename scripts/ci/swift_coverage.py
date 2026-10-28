"""Audit observed shard and replay identities against the current verified build."""
import json
import os
from pathlib import Path
import re
from collections import Counter
from swift_reporting import summarize


def main():
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
        "MokuseiGitIntegrationTests.NativeModelSelectorReplayTests/applicationEscapeCancelsPickerBeforeSettingsNavigation()",
        "MokuseiGitIntegrationTests.NativeModelSelectorReplayTests/modelListPreservesIdentityAndKeyboardCancellation()",
        "MokuseiGitIntegrationTests.NativeModelSelectorReplayTests/reasoningMapsNativeStepsResetAndModelNavigation()",
        "MokuseiGitIntegrationTests.NativeModelSelectorReplayTests/refreshRetiresPopupAndSingleChoiceRemainsSelectable()",
        "MokuseiSettingsIntegrationTests.NativeBrowserDialogTests/retiringPageCancelsItsSheetAndCompletesExactlyOnce(dialog:retirement:)",
        "MokuseiSettingsIntegrationTests.NativeBrowserDialogTests/hiddenPageCannotPresentNewSheet(dialog:)",
        "MokuseiSettingsIntegrationTests.NativeBrowserDialogTests/acceptedPromptAllowsReentrantNextDialog()",
        "MokuseiSettingsIntegrationTests.NativeBrowserDialogTests/navigationCancellationRejectsReentrantPageDialog(navigateAgain:)",
        "MokuseiSettingsIntegrationTests.NativeApplicationNavigationTests/applicationBackActionSettlesAcrossRedrawLocaleAndRemount(type:)",
        "MokuseiSettingsIntegrationTests.NativeSettingsUserFlows/dailySettingsFlow()",
        "MokuseiSettingsIntegrationTests.NativeOverviewTagGlassTests/directorySelectionResizeKeepsRoundedGlass()",
        "MokuseiSettingsIntegrationTests.NativeOverviewTagGlassTests/shortChildMorphKeepsBothCapsuleEnds()",
        "MokuseiSettingsIntegrationTests.NativeMokuHistoryComposerTests/ordinaryClickFocusesAndPersistsExactUnicodeReplacement()",
        "MokuseiSettingsIntegrationTests.NativeBrowserViewportTests/annotationCaptureRefreshesMutatedTextAndRejectsRemovedTargets()",
        "MokuseiSettingsIntegrationTests.NativeBrowserViewportTests/focusedDocumentCommandsUseTheResponderChainWithoutChangingHostZoom()",
        "MokuseiSettingsIntegrationTests.NativeReportNavigationTests/reportNavigationMovesWithPageSurvivesReplacementSuppressionAndZoomAndClicksBack()",
    }
    allowed_skips = swift_launchers | {name.rsplit(".", 1)[0] + "/" + name.rsplit(".", 1)[1] for name in xctest_launchers}
    deferred = set()
    log_paths = {index: one(f"swift-{index}.log") for index in range(5)}
    results, parser_errors, rows = summarize([(f"Swift shard {index + 1}", path) for index, path in log_paths.items() if path is not None])
    errors.extend(parser_errors)
    for shard_index in range(5):
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
        path = log_paths[shard_index]
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
        if manifest and sum(result["tests"] for result in results if result["run"] == label) != len(manifest["shards"][shard_index]["tests"]):
            errors.append(f"{label}: framework totals do not account for every assigned method.")

    if manifest and sorted(receipt_tests) != manifest["tests"]:
        errors.append("Execution receipts do not cover the complete discovered inventory exactly once.")
    if manifest and Counter(observed_tests) != Counter(manifest["tests"]):
        errors.append("Observed framework outcomes do not cover the complete inventory exactly once.")

    replay_passes = set()
    for group in ("fixtures", "interop-wire", "interop-process", "native-controls", "native-capture", "native-runtime"):
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

    rows += ["", "Named live-fixture/isolated-host methods require observed passing replay outcomes.",
             "All discovered methods are observed once across five shards; directory tags are not repeated.",
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
    return 1 if errors else 0
