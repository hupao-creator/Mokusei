"""Run production reading integration suites in a staged temporary AppKit app."""
from pathlib import Path
from collections import Counter
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from native_replay import NativeReplay


def compile_native_input_support(replay, repo):
    source = repo / "app/macos/Tests/NativeInputSupport"
    staged = replay.build / "NativeInputSupport"
    include = staged / "include"
    include.mkdir(parents=True)
    inputs = {}
    staged_inputs = {}
    for relative in ("NativeInputSupport.m", "include/MokuseiNativeInputSupport.h", "include/module.modulemap"):
        target = staged / relative
        shutil.copy2(source / relative, target)
        name = str((source / relative).relative_to(repo))
        inputs[name] = hashlib.sha256(target.read_bytes()).hexdigest()
        staged_inputs[name] = str(target)
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    # NativeReplay.compile uses this host architecture and deployment target.
    target = f"{platform.machine()}-apple-macosx26.0"
    module_map = include / "module.modulemap"
    object_file = staged / "NativeInputSupport.o"
    command = ["/usr/bin/xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
               "-isysroot", sdk, "-target", target, "-fmodules",
               "-fmodules-cache-path=" + str(replay.module_cache),
               "-I", str(include), "-fmodule-map-file=" + str(module_map),
               "-c", str(staged / "NativeInputSupport.m"), "-o", str(object_file)]
    receipt = {"inputSHA256": inputs, "stagedInputs": staged_inputs, "compileCommand": command,
               "sdk": sdk, "target": target, "objectPath": str(object_file)}
    replay.manifest["nativeInputSupport"] = receipt
    try:
        subprocess.run(command, cwd=replay.workspace, check=True)
        receipt["objectSHA256"] = hashlib.sha256(object_file.read_bytes()).hexdigest()
    finally:
        # Retain compiler inputs even when compilation fails before app launch.
        (replay.root / "launch.json").write_text(json.dumps(replay.manifest, indent=2) + "\n")
    return ["-sdk", sdk, "-I", str(include), "-Xcc", "-fmodule-map-file=" + str(module_map), str(object_file)]


def main():
    if "--model-selector" in sys.argv:
        raise SystemExit("Removed embedded model-selector fixture; current Settings use the system select and settings replays")
    if "--moku-execution-links" in sys.argv and os.environ.get("MOKUSEI_TEST_HEADLESS") == "1":
        raise SystemExit("Mounted execution-link replay requires a display; run MOKUSEI_TEST_HEADLESS=1 swift test --package-path app/macos --filter NativeMokuExecutionLinkRoutingTests for window-free coverage")
    source = Path(__file__).resolve().parent
    repo = source.parents[2]
    package = repo / "app/macos"
    native_methods = None
    if "--native-owned" in sys.argv:
        checks = {"--local-images": "local-images", "--moku-execution-links": "moku-execution-links",
                  "--rolling-numbers": "rolling-numbers"}
        flags = set(sys.argv[1:]) - {"--native-owned"}
        if len(sys.argv) != 3 or len(flags) != 1 or not flags <= checks.keys():
            raise SystemExit("--native-owned requires exactly one of --local-images, --moku-execution-links or --rolling-numbers")
        check = checks[flags.pop()]
        sys.path.insert(0, str(repo / "scripts/ci"))
        from swift_ownership import NATIVE_METHOD_OWNERS
        # The standalone app has a different module name from SwiftPM. Keep
        # the declared suite/method identity and its runtime location suffix.
        native_methods = [name.split(".", 1)[1] for name, owner in NATIVE_METHOD_OWNERS.items()
                          if owner["group"] == "native" and owner["check"] == check]
        if not native_methods:
            raise SystemExit("No declared native methods for " + check)
    if os.environ.get("MOKUSEI_SWIFT_SKIP_BUILD") != "1":
        subprocess.run(["xcrun", "swift", "build", "--package-path", str(package)], cwd=repo, check=True)
    developer = Path(subprocess.check_output(["xcrun", "--show-sdk-platform-path"], text=True).strip()) / "Developer"
    frameworks = developer / "Library/Frameworks"
    private_frameworks = developer / "Library/PrivateFrameworks"
    libraries = developer / "usr/lib"
    toolchain = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()).parent.parent
    # Selected SwiftPM objects can retain module-wide XCTestSwiftSupport anchors.
    # Match SwiftPM's SDK platform test paths, including XCTestCore at runtime.
    args = ["-g", "-plugin-path", str(toolchain / "lib/swift/host/plugins/testing"),
            "-plugin-path", str(developer / "usr/lib/swift/host/plugins"),
            "-F", str(frameworks), "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
            "-Xlinker", "-rpath", "-Xlinker", str(private_frameworks),
            "-L", str(libraries), "-Xlinker", "-rpath", "-Xlinker", str(libraries)]
    glass_captures = "--tag-glass-captures" in sys.argv
    workspace_lifecycle = "--workspace-lifecycle" in sys.argv
    standalone_owners = None
    if workspace_lifecycle:
        sys.path.insert(0, str(repo / "scripts/ci"))
        from swift_ownership import STANDALONE_METHOD_OWNERS
        standalone_owners = {name: owner for name, owner in STANDALONE_METHOD_OWNERS.items()
                             if (owner["group"], owner["check"]) == ("native", "workspace-lifecycle")}
        if not standalone_owners:
            raise SystemExit("No declared Workspace lifecycle methods")
        native_methods = [name.split(".", 1)[1] for name in standalone_owners]
    isolated_input = "--isolated-input" in sys.argv
    tag_glass = "--tag-glass" in sys.argv or glass_captures
    thread_send_native = "--thread-send-feedback-native" in sys.argv
    composer_refocus = "--execution-composer-focus" in sys.argv
    thread_send = "--thread-send-feedback" in sys.argv or thread_send_native or composer_refocus
    suite = ("NativeWorkspaceLifecycleReplay" if workspace_lifecycle else
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
             "NativeThreadSendFeedbackTests" if thread_send else
             "NativeComposerPasteTests" if "--composer-paste" in sys.argv else
             "NativeMokuExecutionLinkTests" if "--moku-execution-links" in sys.argv else
             "NativeMokuNoteTests" if "--moku-note-tests" in sys.argv else
             "NativeOverviewTagGlassTests" if tag_glass else "NativeReadingPagePresentationTests")
    thread_suite = "--rolling-numbers" in sys.argv or "--initial-response" in sys.argv or "--harness-forms" in sys.argv
    suites = (["NativeMokuHistoryComposerTests", "NativeBrowserViewportTests", "NativeReportNavigationTests", "NativeThreadHistorySidebarTests", "NativeMokuLandingTests"]
              if isolated_input else [suite, "SwiftUIOverviewInteractionTests", "NativeOverviewDecorationCaptureTests", "NativeOnboardingTagSurfaceTests"] if glass_captures else [suite])
    if "--rolling-numbers" in sys.argv:
        suites.append("GitThreadExtensionTests")
    tests = ([source / "WorkspaceLifecycleReplay.swift"] if workspace_lifecycle else
             [package / f"Tests/Integration/{'Threads' if thread_suite else 'Host'}/{name}.swift" for name in suites])
    app_sources = sorted((package / "Sources/App").glob("*.swift")) if workspace_lifecycle else []
    if workspace_lifecycle:
        args += ["-D", "MOKUSEI_WORKSPACE_LIFECYCLE_REPLAY"]
    support = package / "Tests/Integration/Host/SwiftUIReplaySupport.swift"
    test_environment = package / "Tests/Support/NativeTestEnvironment.swift"
    replay = NativeReplay(repo, "ReadingPresentationReplay", "com.mokusei.reading-presentation-replay")
    evidence = repo / ".scratch/reading-presentation" / ("isolated-input" if isolated_input else suite)
    provenance = None
    capture_evidence = [replay.workspace / "evidence" / name for name in ("excerpt", "native-decoration", "tag-first-frame")]
    if thread_send:
        capture_evidence = [replay.workspace / "evidence"]
    try:
        replay.acquire()
        if "NativeMokuHistoryComposerTests" in suites:
            args += compile_native_input_support(replay, repo)
        reuse_objects = (not workspace_lifecycle and os.environ.get("MOKUSEI_SWIFT_SKIP_BUILD") == "1"
                         and "MOKUSEI_CI_EVIDENCE" in os.environ)
        if reuse_objects:
            selected_objects = {"MokuseiTestSupport": [test_environment],
                                "MokuseiSettingsIntegrationTests": [support]}
            test_target = "MokuseiGitIntegrationTests" if thread_suite else "MokuseiSettingsIntegrationTests"
            selected_objects.setdefault(test_target, []).extend(tests)
            replay.reuse_test_objects(repo, selected_objects)
            compile_sources = [source / "main.swift"]
        else:
            compile_sources = [source / "main.swift", test_environment, support, *tests, *app_sources]
        replay.compile(compile_sources, extra_args=args)
        if reuse_objects:
            replay.manifest["swiftPMTestObjects"]["signedReplayExecutableSHA256"] = hashlib.sha256(
                replay.executable.read_bytes()).hexdigest()
        if glass_captures or thread_send:
            # The merge tree and signed replay binary identify what produced the
            # pixels; a PR head label alone does not identify the tested build.
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=repo, text=True).strip()
            inputs = [source / "main.swift", source / "run.py", support, *tests,
                      package / "Tests/Support/NativeTestEnvironment.swift",
                      package / "Package.swift", package / "Package.resolved",
                      package / "Plugins/CloudMetalCompiler/CloudMetalCompiler.swift",
                      repo / "tools/verification/native_replay.py",
                      repo / "tools/verification/NativeReplayIsolation.swift",
                      repo / "scripts/ci/swift_ownership.py"]
            product_paths = ["app/macos/Sources", "app/macos/Plugins",
                             "app/macos/Package.swift", "app/macos/Package.resolved"]
            product_diff = subprocess.check_output(["git", "diff", "HEAD", "--", *product_paths], cwd=repo)
            provenance = {
                "actualCheckoutSHA": git("rev-parse", "HEAD"),
                "productionSourcesGitTree": git("rev-parse", "HEAD:app/macos/Sources"),
                "configuration": "debug",
                "ci": {key: os.environ.get(key) for key in (
                    "GITHUB_SHA", "GITHUB_EVENT_NAME", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT")},
                "productHasDiff": bool(product_diff),
                "productDiffSHA256": hashlib.sha256(product_diff).hexdigest(),
                "untrackedProductFiles": git("ls-files", "--others", "--exclude-standard", "--", *product_paths).splitlines(),
                "inputSHA256": {str(path.relative_to(repo)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs},
                "signedReplayExecutableSHA256": hashlib.sha256(replay.executable.read_bytes()).hexdigest(),
            }
            if reuse_objects:
                provenance["swiftPMTestObjects"] = replay.manifest["swiftPMTestObjects"]
            for directory in capture_evidence:
                directory.mkdir(parents=True, exist_ok=True)
                (directory / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        environment = {**os.environ, "MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY": "1", "NSUnbufferedIO": "YES",
                       "MOKUSEI_READING_MOTION_ARTIFACTS": str(replay.workspace / "evidence")}
        if "--settings-transition" in sys.argv:
            environment["MOKUSEI_SETTINGS_ARTIFACTS"] = str(replay.workspace / "evidence")
        if "--local-images" in sys.argv:
            environment.setdefault("MOKUSEI_LOCAL_IMAGES_ARTIFACTS", str(replay.workspace / "evidence"))
        if "--moku-composer" in sys.argv:
            environment["MOKUSEI_MOKU_HISTORY_ARTIFACTS"] = str(replay.workspace / "evidence")
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
                            "reportPanelPreservesEditingReplacementSuppressionZoomAndClose",
                            "reportNativeDialogsAndDownloadsPreserveTheDocument",
                            "pointerPreviewHandsOffAndDismissesWithoutLosingKeyboardNavigation",
                            "realWorkspaceWaitsForHydrationAndCentersItsEmptyComposer",
                            "oneResidentOwnsSubmissionRunningTalkDispatchAndStop",
                            "centerSurvivesEscapeResizeCoveringRoutesAndRemount"]
        selected = ("reportNativeDialogsAndDownloadsPreserveTheDocument|reportDoesNotRetainAnErrorOwnedByTheRecoverableSurface"
                    if "--report-controls" in sys.argv else
                    "|".join(isolated_methods) if isolated_input else
                    "directorySelectionResizeKeepsRoundedGlass|shortChildMorphKeepsBothCapsuleEnds|titleReversalAndVisibilityCancellationSettlePixels|excerptRevealKeepsMovingThroughRewriteAndWidthChanges|nativeCloudAndScanMoveInComposedOverview|productionAnimationMountsWithoutAnOpaqueFirstFrame"
                    if glass_captures else
                    "NativeMokuExecutionLink" if "--moku-execution-links" in sys.argv else
                    "RollingNumberCellTests|sharedTokenFlipAnimationWorksAtSummaryAndOriginalSizes"
                    if "--rolling-numbers" in sys.argv else suite)
        if thread_send_native:
            selected = "mountedProductionReadersHandOffAfterContentAdmission|productionDockFoldsOnSendAndOnlyRestoresAFailedCurrentDraft|rightSidecardButtonsToggleRetainedPluginsWithoutCloseIcons|sidecardApertureTravelsBetweenItsActualLauncherAndPanel|completedSendAllowsClickingAndTypingIntoTheResidentComposer"
        if composer_refocus:
            selected = "completedSendAllowsClickingAndTypingIntoTheResidentComposer"
        if native_methods is not None:
            selected = r"(?:^|\.)(?:" + "|".join(re.escape(name) for name in native_methods) + r")(?:/|$)"
        status = replay.run(["--no-parallel", "--filter", selected], timeout=90,
                            launch_services=suite == "NativeSettingsTransitionTests" or "--rolling-numbers" in sys.argv,
                            env=environment,
                            launch_environment={key: environment[key] for key in (
                                "MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY", "MOKUSEI_SETTINGS_ARTIFACTS", "NSUnbufferedIO",
                                "MOKUSEI_CI_EVIDENCE", "MOKUSEI_ROLLING_NUMBER_ARTIFACTS", "MOKUSEI_GIT_ARTIFACTS")
                                if key in environment})
        output = (replay.root / "stdout.log").read_text()
        if (replay.root / "stderr.log").is_file():
            output += (replay.root / "stderr.log").read_text()
        print(output, end="")
        result = subprocess.CompletedProcess([], status, stdout=output)
        result.check_returncode()
    finally:
        try:
            if provenance is not None:
                for directory in capture_evidence:
                    recorded = {**provenance, "captureSHA256": {
                        str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in sorted(directory.rglob("*")) if path.is_file() and path.name != "provenance.json"
                    }}
                    (directory / "provenance.json").write_text(json.dumps(recorded, indent=2) + "\n")
        finally:
            replay.export(evidence)
            replay.close()
    count = (
             len(native_methods) if native_methods is not None else
             1 if composer_refocus else
             5 if thread_send_native else
             9 if isolated_input else
             2 if "--report-controls" in sys.argv else
             5 if "--thread-sidebar" in sys.argv else
             12 if "--moku-execution-links" in sys.argv else
             3 if "--rolling-numbers" in sys.argv else
             1 if "--application-navigation" in sys.argv else
             4 if "--initial-response" in sys.argv else
             4 if "--browser-dialogs" in sys.argv or "--harness-forms" in sys.argv else
             16 if "--overview-search" in sys.argv else
             10 if "--moku-landing" in sys.argv else
             12 if thread_send else
             11 if "--overview-mounting" in sys.argv else
             4 if "--report-navigation" in sys.argv else
             3 if "--settings-transition" in sys.argv or "--local-images" in sys.argv or "--composer-contrast" in sys.argv else
             10 if "--browser-viewport" in sys.argv else
             12 if "--markdown" in sys.argv else
             6 if glass_captures else
             7 if "--moku-composer" in sys.argv else
             7 if tag_glass else
             12)
    if f"Test run with {count} test{'s' if count != 1 else ''}" not in result.stdout or "passed" not in result.stdout.splitlines()[-1]:
        raise SystemExit("FAIL: native replay did not report the complete suite")
    if " skipped" in result.stdout:
        raise SystemExit("FAIL: native replay skipped required cases; inspect the reported environment requirements")
    if standalone_owners is not None:
        from swift_reporting import terminal_methods
        errors = []
        outcomes = terminal_methods(result.stdout, standalone_owners, errors)
        if (errors or Counter(outcomes) != Counter((name, "passed") for name in standalone_owners)
                or any(owner["marker"] not in result.stdout for owner in standalone_owners.values())):
            raise SystemExit("FAIL: workspace replay lacks exactly one passing outcome and marker per owned method: " + str(errors))
    if thread_send and not composer_refocus and any(marker not in result.stdout for marker in (
            "THREAD_SEND_NATIVE_HANDOFF_CONFIRMED", "THREAD_SEND_DOCK_FEEDBACK_CONFIRMED", "THREAD_SIDECARD_TOGGLES_CONFIRMED", "THREAD_SIDECARD_ORIGIN_GEOMETRY_CONFIRMED")):
        raise SystemExit("FAIL: thread send replay did not confirm both native boundaries")
    if thread_send and any(f"THREAD_SEND_COMPOSER_REFOCUS_CONFIRMED exactExecution={exact} cancelHandoff={cancel}" not in result.stdout
                           for exact in ("false", "true") for cancel in ("false", "true")):
        raise SystemExit("FAIL: composer refocus replay did not confirm both detail entry paths")
    if "--moku-execution-links" in sys.argv and "MOKU_NOTE_EXECUTION_CAPSULES_CONFIRMED" not in result.stdout:
        raise SystemExit("FAIL: execution capsules did not confirm their native input path")
    if "--local-images" in sys.argv and "MARKDOWN_LOCAL_IMAGE_NATIVE_CLICK_CONFIRMED" not in result.stdout:
        raise SystemExit("FAIL: local images did not confirm their native attachment click path")
    if "--rolling-numbers" in sys.argv and "GIT_TOKEN_FLIP_FRAMES_CONFIRMED" not in result.stdout:
        raise SystemExit("FAIL: token animation did not confirm its original three-frame assertions")
    if "--rolling-numbers" in sys.argv and "PROJECTED_USAGE_FLIP_FRAMES_CONFIRMED" not in result.stdout:
        raise SystemExit("FAIL: projected usage did not confirm its original three-frame assertions")
    if glass_captures:
        for name in ["directorySelectionResizeKeepsRoundedGlass", "shortChildMorphKeepsBothCapsuleEnds",
                     "titleReversalAndVisibilityCancellationSettlePixels",
                     "excerptRevealKeepsMovingThroughRewriteAndWidthChanges", "nativeCloudAndScanMoveInComposedOverview",
                     "productionAnimationMountsWithoutAnOpaqueFirstFrame"]:
            if f"Test {name}() passed" not in result.stdout:
                raise SystemExit("FAIL: incomplete native capture replay: " + name)
        if "TITLE_INCOMING_MOTION_CONFIRMED" not in result.stdout:
            raise SystemExit("FAIL: title replay did not observe and cancel a live incoming frame")
        if "EXCERPT_INK_MOTION_CONFIRMED" not in result.stdout:
            raise SystemExit("FAIL: excerpt replay did not observe mask movement through rewrite and local width changes")
        if "NATIVE_OVERVIEW_DECORATION_MOTION_CONFIRMED" not in result.stdout:
            raise SystemExit("FAIL: native Overview replay did not observe cloud and scan pixels in composed frames")
        if "TAG_ONBOARDING_FIRST_FRAME_CONFIRMED" not in result.stdout:
            raise SystemExit("FAIL: Tag onboarding replay did not observe entry and return frames")
    if isolated_input:
        for name in isolated_methods:
            if f"Test {name}() passed" not in result.stdout:
                raise SystemExit("FAIL: incomplete isolated input replay: " + name)
    if "--application-navigation" in sys.argv:
        if "applicationBackActionSettlesAcrossRedrawLocaleAndRemount(type:) with 1 test case passed" not in result.stdout:
            raise SystemExit("FAIL: Report application navigation did not pass")
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
