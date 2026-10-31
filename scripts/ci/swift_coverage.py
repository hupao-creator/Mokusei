"""Audit the ordinary suite and native replays against the current verified build."""
import json
import os
from pathlib import Path
import re
from collections import Counter
from swift_reporting import summarize, terminal_methods
from swift_ownership import NATIVE_METHOD_OWNERS, native_filter


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


    manifest = read_json(one("build-manifest.json"))
    if manifest and os.environ.get("GITHUB_SHA", manifest["revision"]) != manifest["revision"]:
        errors.append("Native build does not belong to the current commit.")
    if manifest:
        if manifest.get("nativeMethods") != NATIVE_METHOD_OWNERS:
            errors.append("Native build method ownership does not match the current registry.")
        if manifest["ordinary"].get("skip") != native_filter():
            errors.append("Native build method exclusion does not match the current registry.")
        assigned = manifest["ordinary"]["tests"] + list(NATIVE_METHOD_OWNERS)
        if len(assigned) != len(set(assigned)) or sorted(assigned) != manifest["tests"]:
            errors.append("Ordinary/native ownership plan omits or duplicates discovered tests.")
    receipt_tests = []
    observed_tests = []
    native_receipts = {name: [] for name in NATIVE_METHOD_OWNERS}
    native_outcomes = {name: [] for name in NATIVE_METHOD_OWNERS}


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
        "MokuseiSettingsIntegrationTests.NativeSettingsTransitionTests/capsuleExpandsWithoutRemountingAndFitsViewport()",
        "MokuseiSettingsIntegrationTests.NativeSettingsTransitionTests/modalInputClosesWithoutClickThroughAndRestoresDock()",
        "MokuseiSettingsIntegrationTests.NativeSettingsTransitionTests/reversalsResizeInactiveAndExplicitSettleFenceCompletions()",
        "MokuseiSettingsIntegrationTests.NativeMokuLandingTests/realWorkspaceWaitsForHydrationAndCentersItsEmptyComposer()",
        "MokuseiSettingsIntegrationTests.NativeMokuLandingTests/oneResidentOwnsSubmissionRunningTalkDispatchAndStop()",
        "MokuseiSettingsIntegrationTests.NativeMokuLandingTests/centerSurvivesEscapeResizeCoveringRoutesAndRemount()",
        "MokuseiSettingsIntegrationTests.NativeThreadHistorySidebarTests/pointerPreviewHandsOffAndDismissesWithoutLosingKeyboardNavigation()",
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
        "MokuseiSettingsIntegrationTests.NativeReportNavigationTests/reportNativeDialogsAndDownloadsPreserveTheDocument()",
    }
    allowed_skips = swift_launchers | {name.rsplit(".", 1)[0] + "/" + name.rsplit(".", 1)[1] for name in xctest_launchers}
    deferred = set()
    label = "Ordinary Swift suite"
    path = one("swift.log")
    results, parser_errors, rows = summarize([(label, path)] if path is not None else [])
    errors.extend(parser_errors)
    receipt = read_json(one("swift.json"))
    if receipt is None or receipt.get("status") != "passed" or receipt.get("exit_code") != 0:
        errors.append(f"{label}: missing successful process receipt.")
    if receipt and manifest:
        if (receipt.get("revision") != manifest["revision"]
                or receipt.get("tests") != manifest["ordinary"]["tests"]
                or receipt.get("skip") != manifest["ordinary"].get("skip")):
            errors.append(f"{label}: receipt does not match the complete test inventory.")
        receipt_tests.extend(receipt.get("tests", []))
    if path is None:
        errors.append(f"{label}: no test log; tests did not run.")
    else:
        log = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", path.read_text(errors="replace"))
        if "Requires a logged-in WindowServer session and a display" in log:
            errors.append(f"{label}: native display tests skipped; hosted UI coverage is required.")
        if manifest:
            outcomes = terminal_methods(log, manifest["tests"], errors)
            identities = [name for name, _ in outcomes]
            observed_tests.extend(identities)
            expected = manifest["ordinary"]["tests"]
            if Counter(identities) != Counter(expected):
                errors.append(f"{label}: observed method identities omit, repeat or substitute discovered ordinary tests.")
            skipped_names = {name for name, status in outcomes if status == "skipped"}
            deferred.update(skipped_names)
            for name in sorted(skipped_names - allowed_skips):
                errors.append(f"{label}: unexpected skip: {name}")
        if manifest and sum(result["tests"] for result in results) != len(manifest["ordinary"]["tests"]):
            errors.append(f"{label}: framework totals do not account for every ordinary method.")

    replay_passes = set()
    for group in ("fixtures", "interop", "native"):
        replay_path = one("ci-" + group + "/report.json")
        replay = read_json(replay_path)
        if replay is None:
            errors.append(f"{group}: required replay report missing.")
            continue
        if manifest and replay.get("revision") != manifest["revision"]:
            errors.append(f"{group}: replay belongs to a different commit.")
        if (replay.get("group") != group or replay.get("errors") or "selectedChecks" in replay or not replay["checks"]
                or any(check["status"] != "passed" for check in replay["checks"])):
            errors.append(f"{group}: required replays failed or did not complete.")
        if manifest and group != "fixtures":
            for check in replay["checks"]:
                for name, owner in NATIVE_METHOD_OWNERS.items():
                    if (group, check["name"]) == (owner["group"], owner["check"]):
                        native_receipts[name].append((check["status"], check.get("exit_code")))
                path = replay_path.parent / check["log"]
                if not path.is_file():
                    errors.append(f"{group}: missing actual replay log {check['log']}.")
                    continue
                log = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", path.read_text(errors="replace"))
                outcomes = terminal_methods(log, manifest["tests"], errors)
                for name, owner in NATIVE_METHOD_OWNERS.items():
                    if (group, check["name"]) == (owner["group"], owner["check"]) and owner["marker"] not in log:
                        errors.append(f"Native method lacks its required execution marker: {name}: {owner['marker']}")
                replay_passes.update(name for name, status in outcomes if status == "passed")
                for name, status in outcomes:
                    if name in native_outcomes:
                        native_outcomes[name].append((group, check["name"], status))

    for name, owner in NATIVE_METHOD_OWNERS.items():
        if native_receipts[name] != [("passed", 0)]:
            errors.append(f"Native method requires one successful owner receipt: {name}: {native_receipts[name]}")
        expected = [(owner["group"], owner["check"], "passed")]
        if native_outcomes[name] != expected:
            errors.append(f"Native method requires one passing outcome from its declared owner: {name}: {native_outcomes[name]}")

    if manifest:
        owned_receipts = [name for name, receipts in native_receipts.items() for _ in receipts]
        owned_outcomes = [name for name, outcomes in native_outcomes.items() for _ in outcomes]
        if Counter(receipt_tests + owned_receipts) != Counter(manifest["tests"]):
            errors.append("Ordinary/native receipts do not cover the complete discovered inventory exactly once.")
        if Counter(observed_tests + owned_outcomes) != Counter(manifest["tests"]):
            errors.append("Observed ordinary/native outcomes do not cover the complete inventory exactly once.")

    for name in sorted(deferred - replay_passes):
        errors.append(f"Deferred method has no observed passing replay: {name}")

    rows += ["", "Named live-fixture/isolated-host methods require observed passing replay outcomes.",
             "All discovered methods are observed once across the ordinary suite and explicit native owners; directory tags are not repeated.",
             f"Explicit native owners: {len(NATIVE_METHOD_OWNERS)} methods, each requiring its declared mandatory replay receipt and passing outcome.",
             "Display-capability skips fail CI."]
    report = "\n".join(rows) + "\n"
    destination = Path(os.environ["RUNNER_TEMP"]) / "swift-summary.json"
    destination.write_text(json.dumps({"runs": results, "errors": errors,
                                      "nativeMethods": [{"id": name, "owner": owner, "receipts": native_receipts[name],
                                                         "outcomes": native_outcomes[name]}
                                                        for name, owner in NATIVE_METHOD_OWNERS.items()],
                                      "discoveredMethods": len(manifest["tests"]) if manifest else None}, indent=2) + "\n")
    print(report)
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(report)
        for error in errors:
            summary.write(f"\n- {error}\n")
    for error in errors:
        print(f"::error::{error}")
    return 1 if errors else 0

