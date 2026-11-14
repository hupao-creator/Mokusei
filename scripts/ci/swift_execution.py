"""Route reviewed windowless suites without changing ordinary/native ownership."""
import json
import os
import re
import subprocess
import sys
import time

import deadline
from swift_ownership import native_filter


# Review the entire suite and its helpers before adding it. New/mixed suites
# retain graphical execution; a display skip is never headless coverage.
HEADLESS_SUITES = {
    "MokuseiCoreTests.RuntimeProtocolTests",
    "MokuseiCoreTests.RuntimeAppliedDeliveryTests",
    "MokuseiCoreTests.RuntimeCommandJournalIntegrationTests",
    "MokuseiCoreTests.RuntimeOfflineStoreTests",
    "MokuseiCoreTests.RuntimeQueryCancellationTests",
    "MokuseiGitIntegrationTests.ClaudeErrorSurfacingTests",
    "MokuseiGitIntegrationTests.ThreadCardExtensionLayoutTests",
    "MokuseiGitIntegrationTests.ThreadCardStatusTests",
    "MokuseiSettingsIntegrationTests.MarkdownFallbackSourceTests",
    "MokuseiSettingsIntegrationTests.MarkdownSourceIdentityTests",
    "MokuseiSettingsIntegrationTests.MarkdownSourceRangeTests",
    "MokuseiSettingsIntegrationTests.MarkdownTableRewriteTests",
    "MokuseiSettingsIntegrationTests.NativeArchivedThreadsTests",
    "MokuseiSettingsIntegrationTests.NativeBrowserAnnotationTests",
    "MokuseiSettingsIntegrationTests.NativeCloudMetalTests",
    "MokuseiSettingsIntegrationTests.NativeComposerAdmissionReplay",
    "MokuseiSettingsIntegrationTests.NativeMarkdownHTTPMediaTests",
    "MokuseiSettingsIntegrationTests.NativeMokuDirectoryMentionsTests",
    "MokuseiSettingsIntegrationTests.NativeMokuExecutionLinkRoutingTests",
    "MokuseiSettingsIntegrationTests.NativeMokuOperationTests",
    "MokuseiSettingsIntegrationTests.NativeMokuTalkTests",
    "MokuseiSettingsIntegrationTests.NativeOverviewAutoReturnTests",
    "MokuseiSettingsIntegrationTests.NativeOverviewCameraReadabilityTests",
    "MokuseiSettingsIntegrationTests.NativeOverviewDirectoryTagTests",
    "MokuseiSettingsIntegrationTests.NativeOverviewGestureTests",
    "MokuseiSettingsIntegrationTests.NativeOverviewPackingTests",
    "MokuseiSettingsIntegrationTests.NativeOverviewScopeFilterTests",
    "MokuseiSettingsIntegrationTests.NativePerformanceCacheTests",
    "MokuseiSettingsIntegrationTests.NativePerformanceDeliveryReviewTests",
    "MokuseiSettingsIntegrationTests.NativeReadingPageHeadlessTests",
    "MokuseiSettingsIntegrationTests.NativeSettingsAnimationVisitTests",
    "MokuseiSettingsIntegrationTests.NativeSettingsDiscoveryTests",
    "MokuseiSettingsIntegrationTests.NativeThreadVisibilityTests",
    "MokuseiSettingsIntegrationTests.NativeVoiceAnalysisTests",
    "MokuseiSettingsIntegrationTests.NativeVoiceCaptureWiringTests",
    "MokuseiSettingsIntegrationTests.NativeVoiceOwnershipTests",
}

# These suites are windowless too, but their existing fixture conditions must
# remain intact. Without the producer's environment they retain ordinary
# execution/deferral rather than introducing skips into the headless receipt.
HEADLESS_FIXTURE_SUITES = {
    "MokuseiGitIntegrationTests.GitNativeTests": "MOKUSEI_GIT_CONTRACT_EVIDENCE",
    "MokuseiSettingsIntegrationTests.NativeMokuDispatchTests": "MOKU_STATUS_NATIVE_FIXTURE",
    "MokuseiSettingsIntegrationTests.NativeMokuTimerTests": "MOKU_TIMER_NATIVE_FIXTURE",
    "MokuseiSettingsIntegrationTests.NativeOverviewTagEmojiTests": "MOKUSEI_CONVERSATION_CONTRACT_EXPORT",
    "MokuseiSettingsIntegrationTests.NativeVoiceInputTranscriptTests": "MOKUSEI_VOICE_EVENT_EXPORT",
}


def headless_suites(environment):
    return HEADLESS_SUITES | {suite for suite, variable in HEADLESS_FIXTURE_SUITES.items()
                              if environment.get(variable)}


def suite_filter(suites):
    return "^(?:" + "|".join(re.escape(suite) + "/" for suite in sorted(suites)) + ")"


def ordinary_runs(tests, environment, *, no_parallel=True):
    suites = headless_suites(environment)
    headless = [test for test in tests if test.split("/")[0] in suites]
    graphical = [test for test in tests if test.split("/")[0] not in suites]
    command = ["xcrun", "swift", "test", "--skip-build", "--package-path", "app/macos"]
    if no_parallel:
        command.append("--no-parallel")
    runs = []
    if headless:
        runs.append({"name": "headless", "tests": headless, "log": "headless-swift.log",
                     "environment": {"MOKUSEI_TEST_HEADLESS": "1"},
                     "command": command + ["--filter", suite_filter(suites), "--skip", native_filter()]})
    if graphical:
        # A negative suite selection also excludes Swift Testing's runtime
        # source-location suffixes, without restoring any native-owned sibling.
        skip = native_filter() + "|" + suite_filter(suites) if headless else native_filter()
        # A caller's windowless override must not disable display admission for
        # the graphical complement. Actual missing display capability still skips.
        runs.append({"name": "graphical", "tests": graphical, "log": "swift.log",
                     "environment": {"MOKUSEI_TEST_HEADLESS": "0"},
                     "command": command + ["--skip", skip]})
    return runs


def log_progress(message):
    try:
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        print(f"[Swift CI {stamp}] {message}", file=sys.stderr, flush=True)
    except (OSError, ValueError):
        # A closed diagnostic stream must not replace a process failure/cancellation.
        pass


def log_failure_tail(path):
    try:
        with path.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - 12000))
            tail = stream.read(12000).decode("utf-8", errors="replace")
    except (OSError, ValueError) as error:
        log_progress(f"ordinary LOG TAIL unavailable log={path} error={error!r}")
    else:
        log_progress(f"ordinary LOG TAIL (at most 12000 bytes) log={path}\n{tail}")


def execute_ordinary(tests, root, output, *, revision=None, no_parallel=True):
    environment = dict(os.environ)
    receipt = {"tests": tests, "skip": native_filter(), "status": "running", "startedAt": time.time(),
               "runs": [run | {"status": "not_run", "exit_code": None}
                        for run in ordinary_runs(tests, environment, no_parallel=no_parallel)]}
    if revision is not None:
        receipt["revision"] = revision
    path = output / "swift.json"

    def save():
        path.write_text(json.dumps(receipt, indent=2) + "\n")

    save()
    try:
        for run in receipt["runs"]:
            run.update(status="running", startedAt=time.time())
            save()
            started = time.monotonic()
            log_path = output / run["log"]
            log_progress(f"ordinary BEGIN mode={run['name']} log={log_path}")
            try:
                with log_path.open("w") as log:
                    run["exit_code"] = deadline.run(run["command"], cwd=root,
                        env=environment | run["environment"], stdout=log, stderr=subprocess.STDOUT)
                run["status"] = "passed" if run["exit_code"] == 0 else "failed"
            except (OSError, TimeoutError) as error:
                run.update(status="failed", error=str(error))
            except BaseException as error:
                run.update(status="failed", error=str(error))
                raise
            finally:
                run["finishedAt"] = time.time()
                log_progress(f"ordinary END mode={run['name']} status={run['status']} "
                             f"exit={run['exit_code']} elapsed={time.monotonic() - started:.3f}s "
                             f"log={log_path} error={run.get('error')!r}")
                if run["status"] != "passed":
                    log_failure_tail(log_path)
                save()
        receipt["exit_code"] = next((run["exit_code"] or 1 for run in receipt["runs"]
                                     if run["status"] != "passed"), 0)
        receipt["status"] = "passed" if receipt["runs"] and receipt["exit_code"] == 0 else "failed"
    except BaseException as error:
        receipt.update(status="failed", error=str(error))
        raise
    finally:
        receipt["finishedAt"] = time.time()
        save()
    return receipt
