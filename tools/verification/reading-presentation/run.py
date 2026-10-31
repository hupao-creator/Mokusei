"""Run production reading integration suites in a staged temporary AppKit app."""
from pathlib import Path
import os
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from native_replay import NativeReplay


def main():
    if "--model-selector" in sys.argv and os.environ.get("MOKUSEI_TEST_HEADLESS") == "1":
        raise SystemExit("Model-selector popover replay requires a display; run NativeModelSelectorHeadlessTests for window-free coverage")
    if "--moku-execution-links" in sys.argv and os.environ.get("MOKUSEI_TEST_HEADLESS") == "1":
        raise SystemExit("Mounted execution-link replay requires a display; run MOKUSEI_TEST_HEADLESS=1 swift test --package-path app/macos --filter NativeMokuExecutionLinkRoutingTests for window-free coverage")
    source = Path(__file__).resolve().parent
    repo = source.parents[2]
    package = repo / "app/macos"
    if os.environ.get("MOKUSEI_SWIFT_SKIP_BUILD") != "1":
        subprocess.run(["xcrun", "swift", "build", "--package-path", str(package)], cwd=repo, check=True)
    developer = Path(subprocess.check_output(["xcrun", "--show-sdk-platform-path"], text=True).strip()) / "Developer"
    frameworks = developer / "Library/Frameworks"
    toolchain = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()).parent.parent
    args = ["-g", "-plugin-path", str(toolchain / "lib/swift/host/plugins/testing"),
            "-plugin-path", str(developer / "usr/lib/swift/host/plugins"),
            "-F", str(frameworks), "-Xlinker", "-rpath", "-Xlinker", str(frameworks)]
    glass_captures = "--tag-glass-captures" in sys.argv
    isolated_input = "--isolated-input" in sys.argv
    tag_glass = "--tag-glass" in sys.argv or glass_captures
    suite = ("NativeModelSelectorReplayTests" if "--model-selector" in sys.argv else
             "RollingNumberCellTests" if "--rolling-numbers" in sys.argv else
             "NativeThreadHistorySidebarTests" if "--thread-sidebar" in sys.argv else
             "NativeApplicationNavigationTests" if "--application-navigation" in sys.argv else
             "ThreadCardInitialResponseTests" if "--initial-response" in sys.argv else
             "NativeBrowserDialogTests" if "--browser-dialogs" in sys.argv else
             "NativeBrowserViewportTests" if "--browser-viewport" in sys.argv else
             "NativeComposerContrastTests" if "--composer-contrast" in sys.argv else
             "NativeHarnessFormTests" if "--harness-forms" in sys.argv else
             "NativeOverviewSearchTests" if "--overview-search" in sys.argv else
             "NativeOverviewMountingIntegrationTests" if "--overview-mounting" in sys.argv else
             "NativeReportNavigationTests" if "--report-navigation" in sys.argv or "--report-controls" in sys.argv else
             "NativeSettingsTransitionTests" if "--settings-transition" in sys.argv else
             "NativeMarkdownLocalImageTests" if "--local-images" in sys.argv else
             "NativeMarkdownRegressionTests" if "--markdown" in sys.argv else
             "NativeMokuHistoryComposerTests" if "--moku-composer" in sys.argv else
             "NativeMokuLandingTests" if "--moku-landing" in sys.argv else
             "NativeComposerPasteTests" if "--composer-paste" in sys.argv else
             "NativeMokuExecutionLinkTests" if "--moku-execution-links" in sys.argv else
             "NativeMokuNoteTests" if "--moku-note-tests" in sys.argv else
             "NativeOverviewTagGlassTests" if tag_glass else "NativeReadingPagePresentationTests")
    thread_suite = "--model-selector" in sys.argv or "--rolling-numbers" in sys.argv or "--initial-response" in sys.argv or "--harness-forms" in sys.argv
    suites = (["NativeMokuHistoryComposerTests", "NativeBrowserViewportTests", "NativeReportNavigationTests", "NativeThreadHistorySidebarTests", "NativeMokuLandingTests"]
              if isolated_input else [suite, "SwiftUIOverviewInteractionTests"] if glass_captures else [suite])
    tests = [package / f"Tests/Integration/{'Threads' if thread_suite else 'Host'}/{name}.swift" for name in suites]
    support = package / "Tests/Integration/Host/SwiftUIReplaySupport.swift"
    replay = NativeReplay(repo, "ReadingPresentationReplay", "com.mokusei.reading-presentation-replay")
    evidence = repo / ".scratch/reading-presentation" / ("isolated-input" if isolated_input else suite)
    try:
        replay.acquire()
        replay.compile([source / "main.swift", package / "Tests/Support/NativeTestEnvironment.swift", support, *tests], extra_args=args)
        environment = {**os.environ, "MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY": "1", "NSUnbufferedIO": "YES",
                       "MOKUSEI_READING_MOTION_ARTIFACTS": str(replay.workspace / "evidence")}
        if "--settings-transition" in sys.argv:
            environment["MOKUSEI_SETTINGS_ARTIFACTS"] = str(replay.workspace / "evidence")
        if "--model-selector" in sys.argv:
            environment["MOKUSEI_MODEL_SELECTOR_ARTIFACTS"] = str(replay.workspace / "evidence")
        if "--thread-sidebar" in sys.argv:
            environment["MOKUSEI_SIDEBAR_ARTIFACTS"] = str(replay.workspace / "evidence")
        if "--overview-search" in sys.argv:
            environment["MOKUSEI_OVERVIEW_SEARCH_NATIVE_REPLAY"] = "1"
        if tag_glass:
            environment.setdefault("MOKUSEI_TAG_SWITCH_ARTIFACTS", str(replay.workspace / "evidence/switch"))
            environment.setdefault("MOKUSEI_TAG_MORPH_ARTIFACTS", str(replay.workspace / "evidence/morph"))
        if "--initial-response" in sys.argv:
            fixture = replay.workspace / "initial-response.json"
            subprocess.run([str(repo / "scripts/go.sh"), "run", "-race", "./tools/verification/initial-response", "-output", str(fixture)], cwd=repo, check=True)
            environment["MOKUSEI_INITIAL_RESPONSE_FIXTURES"] = str(fixture)
            environment["MOKUSEI_INITIAL_RESPONSE_ARTIFACTS"] = str(replay.workspace / "evidence")
        if "--harness-forms" in sys.argv:
            fixture = replay.workspace / "harness-forms.json"
            subprocess.run([str(repo / "scripts/go.sh"), "run", "-race", "./tools/verification/opencode/cases/renderer", "-forms-output", str(fixture)], cwd=repo, check=True)
            environment["MOKUSEI_HARNESS_FORM_FIXTURE"] = str(fixture)
        isolated_methods = ["ordinaryClickFocusesAndPersistsExactUnicodeReplacement",
                            "annotationCaptureRefreshesMutatedTextAndRejectsRemovedTargets",
                            "focusedDocumentCommandsUseTheResponderChainWithoutChangingHostZoom",
                            "reportNavigationMovesWithPageSurvivesReplacementSuppressionAndZoomAndClicksBack",
                            "reportNativeDialogsAndDownloadsPreserveTheDocument",
                            "pointerPreviewHandsOffAndDismissesWithoutLosingKeyboardNavigation",
                            "realWorkspaceWaitsForHydrationAndCentersItsEmptyComposer",
                            "oneResidentOwnsSubmissionRunningTalkDispatchAndStop",
                            "centerSurvivesEscapeResizeCoveringRoutesAndRemount"]
        selected = ("reportNativeDialogsAndDownloadsPreserveTheDocument|reportDoesNotRetainAnErrorOwnedByTheRecoverableSurface"
                    if "--report-controls" in sys.argv else
                    "|".join(isolated_methods) if isolated_input else
                    "directorySelectionResizeKeepsRoundedGlass|shortChildMorphKeepsBothCapsuleEnds|titleReversalAndVisibilityCancellationSettlePixels"
                    if glass_captures else
                    "NativeMokuExecutionLink" if "--moku-execution-links" in sys.argv else suite)
        status = replay.run(["--no-parallel", "--filter", selected], timeout=90,
                            launch_services=suite == "NativeSettingsTransitionTests", env=environment,
                            launch_environment={key: environment[key] for key in (
                                "MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY", "MOKUSEI_SETTINGS_ARTIFACTS", "NSUnbufferedIO")
                                if key in environment})
        output = (replay.root / "stdout.log").read_text()
        if (replay.root / "stderr.log").is_file():
            output += (replay.root / "stderr.log").read_text()
        print(output, end="")
        result = subprocess.CompletedProcess([], status, stdout=output)
        result.check_returncode()
    finally:
        replay.export(evidence)
        replay.close()
    count = (4 if "--model-selector" in sys.argv else
             9 if isolated_input else
             2 if "--report-controls" in sys.argv else
             5 if "--thread-sidebar" in sys.argv else
             8 if "--moku-execution-links" in sys.argv else
             3 if "--rolling-numbers" in sys.argv else
             1 if "--application-navigation" in sys.argv else
             4 if "--initial-response" in sys.argv else
             4 if "--browser-dialogs" in sys.argv or "--harness-forms" in sys.argv else
             14 if "--overview-search" in sys.argv else
             9 if "--moku-landing" in sys.argv else
             11 if "--overview-mounting" in sys.argv else
             4 if "--report-navigation" in sys.argv else
             3 if "--settings-transition" in sys.argv or "--local-images" in sys.argv or "--composer-contrast" in sys.argv else
             10 if "--browser-viewport" in sys.argv else
             8 if "--markdown" in sys.argv else
             3 if glass_captures else
             7 if tag_glass or "--moku-composer" in sys.argv else
             11 if "--moku-note-tests" in sys.argv else 6)
    if f"Test run with {count} test{'s' if count != 1 else ''}" not in result.stdout or "passed" not in result.stdout.splitlines()[-1]:
        raise SystemExit("FAIL: native replay did not report the complete suite")
    if " skipped" in result.stdout:
        raise SystemExit("FAIL: native replay skipped required cases; inspect the reported environment requirements")
    if glass_captures:
        for name in ["directorySelectionResizeKeepsRoundedGlass", "shortChildMorphKeepsBothCapsuleEnds",
                     "titleReversalAndVisibilityCancellationSettlePixels"]:
            if f"Test {name}() passed" not in result.stdout:
                raise SystemExit("FAIL: incomplete native capture replay: " + name)
        if "TITLE_INCOMING_MOTION_CONFIRMED" not in result.stdout:
            raise SystemExit("FAIL: title replay did not observe and cancel a live incoming frame")
    if isolated_input:
        for name in isolated_methods:
            if f"Test {name}() passed" not in result.stdout:
                raise SystemExit("FAIL: incomplete isolated input replay: " + name)
    if "--application-navigation" in sys.argv:
        if "applicationBackActionSettlesAcrossRedrawLocaleAndRemount(type:) with 2 test cases passed" not in result.stdout:
            raise SystemExit("FAIL: application and Git navigation cases did not both pass")
    if "--initial-response" in sys.argv:
        for marker in ["actualGoProjectionsPreserveContentAndStructure()", "publicFactsTakePrecedenceOverPendingInput()",
                       "malformedAndMissingFlagsRemainConservative()", "mountedProductionCardsShowStatesAndFirstContent()"]:
            if f"Test {marker} passed" not in result.stdout:
                raise SystemExit("FAIL: incomplete initial-response native suite: " + marker)
        if "Suite ThreadCardInitialResponseTests passed" not in result.stdout:
            raise SystemExit("FAIL: initial-response suite did not pass")
    if "--browser-dialogs" in sys.argv:
        for marker in [
            "retiringPageCancelsItsSheetAndCompletesExactlyOnce(dialog:retirement:) with 12 test cases passed",
            "hiddenPageCannotPresentNewSheet(dialog:) with 4 test cases passed",
            "acceptedPromptAllowsReentrantNextDialog() passed",
            "navigationCancellationRejectsReentrantPageDialog(navigateAgain:) with 2 test cases passed",
        ]:
            if marker not in result.stdout:
                raise SystemExit("FAIL: browser replay did not complete every dialog case")


if __name__ == "__main__":
    main()
