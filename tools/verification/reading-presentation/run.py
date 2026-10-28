"""Run production reading integration suites in a staged temporary AppKit app."""
from pathlib import Path
import os
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from native_replay import NativeReplay


def main():
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
    tag_glass = "--tag-glass" in sys.argv or glass_captures
    suite = ("RollingNumberCellTests" if "--rolling-numbers" in sys.argv else
             "NativeApplicationNavigationTests" if "--application-navigation" in sys.argv else
             "ThreadCardInitialResponseTests" if "--initial-response" in sys.argv else
             "NativeBrowserDialogTests" if "--browser-dialogs" in sys.argv else
             "NativeBrowserViewportTests" if "--browser-viewport" in sys.argv else
             "NativeComposerContrastTests" if "--composer-contrast" in sys.argv else
             "NativeHarnessFormTests" if "--harness-forms" in sys.argv else
             "NativeOverviewSearchTests" if "--overview-search" in sys.argv else
             "NativeOverviewMountingIntegrationTests" if "--overview-mounting" in sys.argv else
             "NativeReportNavigationTests" if "--report-navigation" in sys.argv else
             "NativeSettingsTransitionTests" if "--settings-transition" in sys.argv else
             "NativeMarkdownLocalImageTests" if "--local-images" in sys.argv else
             "NativeMarkdownRegressionTests" if "--markdown" in sys.argv else
             "NativeMokuHistoryComposerTests" if "--moku-composer" in sys.argv else
             "NativeComposerPasteTests" if "--composer-paste" in sys.argv else
             "NativeMokuNoteTests" if "--moku-note-tests" in sys.argv else
             "NativeOverviewTagGlassTests" if tag_glass else "NativeReadingPagePresentationTests")
    thread_suite = "--rolling-numbers" in sys.argv or "--initial-response" in sys.argv or "--harness-forms" in sys.argv
    tests = package / f"Tests/Integration/{'Threads' if thread_suite else 'Host'}/{suite}.swift"
    support = package / "Tests/Integration/Host/SwiftUIReplaySupport.swift"
    replay = NativeReplay(repo, "ReadingPresentationReplay", "com.mokusei.reading-presentation-replay")
    evidence = repo / ".scratch/reading-presentation" / suite
    try:
        replay.acquire()
        replay.compile([source / "main.swift", package / "Tests/Support/NativeTestEnvironment.swift", support, tests], extra_args=args)
        environment = {**os.environ, "MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY": "1", "NSUnbufferedIO": "YES"}
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
        selected = ("directorySelectionResizeKeepsRoundedGlass|shortChildMorphKeepsBothCapsuleEnds"
                    if glass_captures else suite)
        status = replay.run(["--no-parallel", "--filter", selected], timeout=90, launch_services=False, env=environment)
        output = (replay.root / "stdout.log").read_text()
        print(output, end="")
        result = subprocess.CompletedProcess([], status, stdout=output)
        result.check_returncode()
    finally:
        replay.export(evidence)
        replay.close()
    count = (3 if "--rolling-numbers" in sys.argv else
             1 if "--application-navigation" in sys.argv else
             4 if "--initial-response" in sys.argv else
             4 if "--browser-dialogs" in sys.argv or "--harness-forms" in sys.argv else
             14 if "--overview-search" in sys.argv else
             6 if "--overview-mounting" in sys.argv else
             2 if "--report-navigation" in sys.argv else
             3 if "--settings-transition" in sys.argv or "--local-images" in sys.argv or "--composer-contrast" in sys.argv else
             8 if "--browser-viewport" in sys.argv else
             2 if glass_captures else
             7 if tag_glass or "--markdown" in sys.argv or "--moku-composer" in sys.argv else
             10 if "--moku-note-tests" in sys.argv else 5)
    if f"Test run with {count} test{'s' if count != 1 else ''}" not in result.stdout or "passed" not in result.stdout.splitlines()[-1]:
        raise SystemExit("FAIL: native replay did not report the complete suite")
    if " skipped" in result.stdout:
        raise SystemExit("FAIL: native replay skipped required cases; inspect the reported environment requirements")
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
