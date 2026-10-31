"""Paired foreground Overview measurements from two Release builds on one Mac."""
from contextlib import contextmanager
from datetime import datetime, timezone
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import traceback

SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parents[2]
sys.path.insert(0, str(SOURCE.parent))
from native_replay import NativeReplay

PRODUCT_PATHS = ["app/macos/Sources", "app/macos/Plugins", "app/macos/Package.swift",
                 "app/macos/Package.resolved", "internal", "cmd", "go.mod", "go.sum"]
SWIFT_FLAGS = ["-O", "-g", "-enable-testing"]

# Select only modes already offered by the runner's real display. No virtual
# display or offscreen window may make the four-card visibility check pass.
DISPLAY_SOURCE = r'''
import AppKit
import CoreGraphics
import Foundation

func describe(_ mode: CGDisplayMode) -> [String: Any] {
    ["id": mode.ioDisplayModeID, "width": mode.width, "height": mode.height,
     "pixelWidth": mode.pixelWidth, "pixelHeight": mode.pixelHeight, "refreshHz": mode.refreshRate]
}
func setSessionMode(_ display: CGDirectDisplayID, _ mode: CGDisplayMode) -> CGError {
    var configuration: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&configuration)
    guard begin == .success else { return begin }
    let configure = CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
    guard configure == .success else {
        _ = CGCancelDisplayConfiguration(configuration)
        return configure
    }
    // A temporary helper exits before the matrix. App-only changes would revert
    // on that exit; session-scoped changes survive until explicit cleanup.
    // Complete consumes the configuration even when it reports failure.
    return CGCompleteDisplayConfiguration(configuration, .forSession)
}
func write(_ value: [String: Any], _ path: String) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path), options: .atomic)
}
func modes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
    CGDisplayCopyAllDisplayModes(display,
        [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
}
@MainActor func screenFacts() -> [[String: Any]] {
    NSScreen.screens.map { ["frame": NSStringFromRect($0.frame), "visibleFrame": NSStringFromRect($0.visibleFrame),
        "backingScale": $0.backingScaleFactor, "maximumFramesPerSecond": $0.maximumFramesPerSecond] }
}
@main struct DisplayMode {
    @MainActor static func main() {
        do {
            _ = NSApplication.shared
            let arguments = CommandLine.arguments
            guard arguments.count == 4 else { throw NSError(domain: "DisplayMode", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected inspect|prepare|restore input output"]) }
            let action = arguments[1], output = arguments[3]
            if action == "restore" {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[2]))) as! [String: Any]
                let display = (object["displayID"] as! NSNumber).uint32Value
                let original = object["originalMode"] as! [String: Any]
                let originalID = (original["id"] as! NSNumber).int32Value
                guard let target = modes(display).first(where: { $0.ioDisplayModeID == originalID }) else {
                    throw NSError(domain: "DisplayMode", code: 2, userInfo: [NSLocalizedDescriptionKey: "Original display mode unavailable"])
                }
                let status = setSessionMode(display, target)
                try write(["status": status.rawValue, "restored": status == .success,
                    "requestedMode": describe(target), "configurationScope": "forSession"], output)
                guard status == .success else { exit(1) }
                return
            }
            let display = CGMainDisplayID()
            guard let original = CGDisplayCopyDisplayMode(display) else {
                throw NSError(domain: "DisplayMode", code: 3, userInfo: [NSLocalizedDescriptionKey: "No current display mode"])
            }
            let available = modes(display)
            var result: [String: Any] = ["displayID": display, "originalMode": describe(original),
                "offeredModes": available.map(describe), "screensBefore": screenFacts(), "changed": false,
                "configurationScope": "forSession"]
            // Write restoration information before any mutation, including a failed mutation.
            try write(result, output)
            var selected = original
            if (original.width < 1265 || original.height < 800) && action == "prepare" {
                let candidates = available.filter { $0.width >= 1265 && $0.height >= 800 }
                guard let target = candidates.min(by: { a, b in
                    let aScore = abs(a.width - 1440) + abs(a.height - 900)
                    let bScore = abs(b.width - 1440) + abs(b.height - 900)
                    return aScore == bScore ? a.pixelWidth * a.pixelHeight < b.pixelWidth * b.pixelHeight : aScore < bScore
                }) else {
                    result["valid"] = false; result["reason"] = "No offered mode at least 1265x800 logical pixels"
                    try write(result, output); exit(1)
                }
                let status = setSessionMode(display, target)
                result["setModeStatus"] = status.rawValue
                guard status == .success else { try write(result, output); exit(1) }
                selected = target; result["changed"] = true
                try write(result, output)
                let deadline = Date(timeIntervalSinceNow: 3)
                while Date() < deadline && !(NSScreen.main.map { $0.frame.width >= 1265 && $0.frame.height >= 800 } ?? false) {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                }
            }
            let actual = CGDisplayCopyDisplayMode(display) ?? selected
            let valid = actual.width >= 1265 && actual.height >= 800
            result["selectedMode"] = describe(selected); result["actualMode"] = describe(actual)
            result["screensAfter"] = screenFacts(); result["valid"] = valid
            try write(result, output)
            if !valid { exit(1) }
        } catch {
            fputs("Display capability error: \(error)\n", stderr); exit(1)
        }
    }
}
'''


def utc():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    temporary.replace(path)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(repo, *arguments):
    return subprocess.check_output(["git", *arguments], cwd=repo, text=True).strip()


def hash_files(root, files):
    # Hash names and content digests with unambiguous separators; retain every
    # per-file digest so this inventory is independently reproducible.
    hashes = {str(path.relative_to(root)): digest(path) for path in sorted(files)}
    encoded = b"".join(name.encode() + b"\0" + value.encode() + b"\n" for name, value in hashes.items())
    return {"sha256": hashlib.sha256(encoded).hexdigest(), "files": hashes,
            "algorithm": "sha256 of sorted UTF-8 relative path + NUL + file SHA256 hex + LF"}


def product_identity(repo):
    names = subprocess.check_output(["git", "ls-files", "-z", "--", *PRODUCT_PATHS], cwd=repo).decode().split("\0")
    inventory = hash_files(repo, [repo / name for name in names if name])
    inventory.update(revision=git(repo, "rev-parse", "HEAD"),
                     sourcesGitTree=git(repo, "rev-parse", "HEAD:app/macos/Sources"),
                     diff=git(repo, "diff", "HEAD", "--", *PRODUCT_PATHS),
                     untracked=git(repo, "ls-files", "--others", "--exclude-standard", "--", *PRODUCT_PATHS).splitlines())
    if inventory["diff"] or inventory["untracked"]:
        raise RuntimeError("Product files differ from the fixed commit: " + str(repo))
    return inventory


@contextmanager
def time_limit(seconds):
    def expired(*_):
        raise TimeoutError("Overview benchmark operation exceeded its remaining time budget")
    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, max(1, seconds))
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


@contextmanager
def native_build_log(path):
    """Retain subprocess output from the common replay compiler in the artifact."""
    sys.stdout.flush()
    sys.stderr.flush()
    saved = [os.dup(1), os.dup(2)]
    try:
        with path.open("w") as stream:
            os.dup2(stream.fileno(), 1)
            os.dup2(stream.fileno(), 2)
            yield
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
        for descriptor, original in zip((1, 2), saved):
            os.dup2(original, descriptor)
            os.close(original)


class Budget:
    def __init__(self, seconds):
        self.deadline = time.monotonic() + seconds

    def remaining(self, limit):
        remaining = self.deadline - time.monotonic()
        if remaining < 1:
            raise TimeoutError("Overview performance run exhausted its time budget")
        return min(limit, remaining)


def command(arguments, log, *, cwd=ROOT, timeout=120, environment=None):
    log.parent.mkdir(parents=True, exist_ok=True)
    receipt = {"command": list(map(str, arguments)), "cwd": str(cwd), "startedAt": utc(), "exitCode": None}
    write_json(log.with_suffix(".command.json"), receipt)
    process = None
    try:
        with log.open("w") as stream:
            process = subprocess.Popen(arguments, cwd=cwd, env=environment, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            receipt["exitCode"] = process.wait(timeout=timeout)
        if receipt["exitCode"]:
            raise RuntimeError(f"Command failed ({receipt['exitCode']}): {arguments[0]}; see {log}")
    except BaseException as error:
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=3)
        error.overview_log = log
        error.overview_command = receipt["command"]
        error.overview_exit_code = process.returncode if process is not None else None
        raise
    finally:
        receipt["finishedAt"] = utc()
        write_json(log.with_suffix(".command.json"), receipt)


def observation(arguments):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=15)
        return {"command": arguments, "exitCode": result.returncode, "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"command": arguments, "error": str(error)}


def machine_snapshot(full=False):
    commands = {"power": ["pmset", "-g", "batt"], "thermal": ["pmset", "-g", "therm"],
                "load": ["sysctl", "-n", "vm.loadavg"]}
    if full:
        commands.update(os=["sw_vers"], hardware=["system_profiler", "SPHardwareDataType", "SPDisplaysDataType", "-json"],
                        swift=["xcrun", "swift", "--version"], xcode=["xcodebuild", "-version"], go=["go", "version"],
                        reduceMotion=["defaults", "read", "com.apple.universalaccess", "reduceMotion"],
                        reduceTransparency=["defaults", "read", "com.apple.universalaccess", "reduceTransparency"])
    return {"at": utc(), "architecture": platform.machine(), "observations": {name: observation(cmd) for name, cmd in commands.items()}}


def power_source(snapshot):
    value = snapshot["observations"]["power"].get("stdout", "")
    match = re.search(r"Now drawing from '([^']+)'", value)
    return match.group(1) if match else None


def file_identity(path):
    """Identify an existing file, retaining both its reported and resolved path."""
    if not isinstance(path, (str, Path)) or not str(path):
        raise ValueError("Executable path is missing")
    value = Path(path)
    resolved = value.resolve(strict=True)
    details = resolved.stat()
    if not stat.S_ISREG(details.st_mode):
        raise ValueError("Executable path is not a regular file: " + str(path))
    return {"reportedPath": str(path), "resolvedPath": str(resolved),
            "device": details.st_dev, "inode": details.st_ino}


def same_existing_file(actual, expected):
    try:
        left, right = file_identity(actual), file_identity(expected)
        return (left["device"], left["inode"]) == (right["device"], right["inode"])
    except (OSError, ValueError, RuntimeError):
        return False


def validate_runtime_identity(process, startup, expected_executable):
    evidence = {"pid": process.get("pid"), "parentPID": process.get("parentPID"),
                "expectedParentPID": startup.get("pid")}
    reasons = []
    pid, parent = process.get("pid"), startup.get("pid")
    if (not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1 or
            not isinstance(parent, int) or isinstance(parent, bool) or parent <= 1 or
            process.get("parentPID") != parent):
        reasons.append("Core process identity does not belong to this fresh native application")
    try:
        actual, expected = file_identity(process.get("executable")), file_identity(expected_executable)
        evidence.update(reportedExecutable=actual, expectedExecutable=expected)
        evidence["samePhysicalFile"] = (actual["device"], actual["inode"]) == (expected["device"], expected["inode"])
        if not evidence["samePhysicalFile"]:
            reasons.append("Core executable is not the staged runtime file")
    except (OSError, ValueError, RuntimeError) as error:
        evidence["fileIdentityError"] = str(error)
        reasons.append("Core executable identity could not be verified: " + str(error))
    return evidence, reasons


def cleanup_runtime(replay, output):
    receipts = []
    for path in (replay.workspace / "evidence").rglob("*ready*.json"):
        try:
            value = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        pid, executable = value.get("pid"), value.get("executable")
        receipt = {"file": str(path.relative_to(replay.workspace)), "pid": pid, "executable": executable}
        if isinstance(pid, int) and pid > 1 and same_existing_file(executable, replay.workspace / "runtime"):
            actual = observation(["/bin/ps", "-p", str(pid), "-o", "comm="])
            if actual.get("exitCode") == 0 and same_existing_file(actual.get("stdout"), replay.workspace / "runtime"):
                try:
                    os.kill(pid, signal.SIGTERM)
                    receipt["terminatedOwnedRuntime"] = True
                except ProcessLookupError:
                    pass
                for _ in range(30):
                    if subprocess.run(["/bin/kill", "-0", str(pid)], capture_output=True).returncode:
                        break
                    time.sleep(0.1)
                else:
                    # Recheck identity before escalating an owned process only.
                    actual = observation(["/bin/ps", "-p", str(pid), "-o", "comm="])
                    if actual.get("exitCode") == 0 and same_existing_file(actual.get("stdout"), replay.workspace / "runtime"):
                        try:
                            os.kill(pid, signal.SIGKILL)
                            receipt["killedOwnedRuntime"] = True
                        except ProcessLookupError:
                            pass
        # Connection credentials are ephemeral and irrelevant to the evidence.
        write_json(path, {key: value[key] for key in ("pid", "executable", "controlURL") if key in value})
        receipts.append(receipt)
    write_json(output / "runtime-cleanup.json", receipts)


def numeric(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def validate_startup(receipt, replay, arguments):
    reasons = []
    if not isinstance(receipt.get("pid"), int) or receipt["pid"] <= 1:
        reasons.append("Native startup receipt has no valid application PID")
    if receipt.get("cwd") != str(replay.workspace) or receipt.get("arguments") != arguments:
        reasons.append("Native startup did not identify the requested isolated workspace and arguments")
    if sorted(receipt.get("resourceBundles", [])) != sorted(replay.manifest["resourceBundles"]):
        reasons.append("Native startup resource bundles do not match this fixed product application")
    return reasons


def validate_result(result, condition, seconds):
    reasons = []
    if result.get("schemaVersion") != 1 or result.get("condition") != condition or result.get("n") != 40 or result.get("k") != 4:
        reasons.append("Unexpected result schema or scenario")
    if result.get("valid") is not True:
        reasons.extend(result.get("invalidReasons") or ["UI harness did not certify foreground validity"])
    if not isinstance(result.get("comparisonIdentity"), dict) or not result["comparisonIdentity"]:
        reasons.append("Missing stable fixture/window/display comparison identity")
    core = result.get("core", {})
    if core.get("valid") is not True:
        reasons.extend(core.get("invalidReasons") or ["Core harness did not certify source/publication validity"])
    for label, cpu in (("UI", result.get("ui", {})), ("Core", core.get("cpu", {}))):
        values = [cpu.get(key) for key in ("cpuSeconds", "wallSeconds", "cpuPercent")]
        if not all(numeric(value) for value in values) or values[0] < 0 or values[1] < seconds * 0.9:
            reasons.append(label + " has missing/invalid formal CPU or a shortened formal interval")
        elif abs(values[2] - 100 * values[0] / values[1]) > 0.02:
            reasons.append(label + " CPU percentage does not match CPU seconds / actual wall seconds")
    source = core.get("source", {})
    if source.get("planned") != source.get("sent") or source.get("sent") != source.get("accepted") or source.get("errors"):
        reasons.append("Source events were rejected, lost, or failed")
    if not all(isinstance(source.get(key), int) for key in ("planned", "sent", "accepted")):
        reasons.append("Source accounting is missing")
    return list(dict.fromkeys(map(str, reasons)))


def cpu_values(record):
    result = record.get("result", {})
    ui = result.get("ui", {}).get("cpuPercent")
    core = result.get("core", {}).get("cpu", {}).get("cpuPercent")
    return (ui, core, ui + core) if numeric(ui) and numeric(core) else (None, None, None)


def model_flow(result):
    """Summarize completed model work separately from fixed-window CPU."""
    records = result.get("installations", {}).get("records", [])
    end = result.get("clock", {}).get("formalEnd", {}).get("uptimeNanoseconds")
    summary = {"meaning": "Model catalog installation, not queue depth, pixels or frame rate"}
    if not numeric(end):
        return summary
    before = [record for record in records if numeric(record.get("uptimeNanoseconds"))
              and record["uptimeNanoseconds"] <= end]
    if before:
        summary["formalEndSequences"] = max(before, key=lambda record: record["uptimeNanoseconds"]).get("sequences")
    summary["postFormalInstallCount"] = sum(
        numeric(record.get("uptimeNanoseconds")) and record["uptimeNanoseconds"] > end for record in records)
    expected = result.get("core", {}).get("expectedCards", [])
    target = [card.get("seq") for card in sorted(expected, key=lambda card: card["id"])]
    completed = [record for record in records if len(target) == 4 and record.get("sequences") == target
                 and numeric(record.get("unixNanoseconds"))]
    accepted = [event.get("acceptedUnixNano") for event in result.get("core", {}).get("sourceEvents", [])]
    accepted = [value for value in accepted if numeric(value)]
    if completed and accepted:
        first = min(record["unixNanoseconds"] for record in completed)
        last = max(accepted)
        summary.update(firstFinalSequenceInstallUnixNanoseconds=first, lastSourceAcceptedUnixNanoseconds=last,
                       finalSequenceInstallAfterLastSourceAcceptedMilliseconds=(first - last) / 1e6)
    return summary


def paired_results(records):
    pairs = []
    for condition in ("R0", "S4", "A4"):
        for order in ("AB", "BA"):
            matching = [row for row in records if row["condition"] == condition and row["order"] == order]
            selected = {row["side"]: row for row in matching}
            row = {"condition": condition, "order": order, "valid": False, "invalidReasons": []}
            if len(matching) == 2 and set(selected) == {"A", "B"} and all(record.get("valid") for record in selected.values()):
                if selected["A"].get("powerBefore") != selected["B"].get("powerBefore"):
                    row["invalidReasons"].append("A/B power sources differ")
                if selected["A"]["result"].get("comparisonIdentity") != selected["B"]["result"].get("comparisonIdentity"):
                    row["invalidReasons"].append("A/B fixture, actual window, camera or display identities differ")
                if row["invalidReasons"]:
                    pairs.append(row)
                    continue
                a, b = cpu_values(selected["A"]), cpu_values(selected["B"])
                row.update(valid=True, uiDeltaPP=b[0] - a[0], coreDeltaPP=b[1] - a[1], totalDeltaPP=b[2] - a[2],
                           uiRelativeReductionPercent=100 * (a[0] - b[0]) / a[0] if a[0] else None,
                           totalRelativeReductionPercent=100 * (a[2] - b[2]) / a[2] if a[2] else None)
            else:
                row["invalidReasons"].append("A prescribed A/B process is missing or invalid")
            pairs.append(row)
    return pairs


def number(value, digits=3):
    return f"{value:.{digits}f}" if numeric(value) else "—"


def record_failure(output, report, error):
    """Keep full exception/argv in JSON; show the actual tool diagnostic in prose."""
    command = getattr(error, "overview_command", getattr(error, "cmd", None))
    exit_code = getattr(error, "overview_exit_code", getattr(error, "returncode", None))
    if isinstance(error, subprocess.CalledProcessError):
        summary = f"Command exited with status {error.returncode}"
    elif isinstance(error, subprocess.TimeoutExpired):
        summary = f"Command exceeded its {error.timeout}s timeout"
    else:
        summary = str(error)
    if len(summary) > 1200:
        summary = summary[:1200] + "… (full exception in failure.json)"
    log = getattr(error, "overview_log", None)
    relative_log, stage, tail, truncated = None, "orchestration", "", False
    if log is not None:
        relative_log = str(log.relative_to(output))
        stage = str(Path(relative_log).with_suffix(""))
        if log.is_file():
            with log.open("rb") as stream:
                size = stream.seek(0, os.SEEK_END)
                stream.seek(max(0, size - 12000))
                raw = stream.read().decode("utf-8", errors="replace")
            lines = raw.splitlines()
            truncated = size > 12000 or len(lines) > 80
            tail = "\n".join(lines[-80:])
    failure = {"stage": stage, "exceptionType": type(error).__name__, "summary": summary,
               "exitCode": exit_code, "log": relative_log, "diagnosticTail": tail,
               "diagnosticTailTruncated": truncated, "fullExceptionFile": "failure.json"}
    write_json(output / "failure.json", {**failure, "command": command,
               "fullException": str(error), "fullTraceback": traceback.format_exc()})
    report["failure"] = failure
    report["errors"].append(f"{stage}: {type(error).__name__}: {summary}")
    text = [f"Stage: {stage}", f"Exception: {type(error).__name__}", f"Exit code: {exit_code}",
            f"Summary: {summary}", f"Full log: {relative_log or 'not available'}",
            "Complete command and exception: failure.json", "", "Tool output (bounded tail):", tail or "No tool output recorded.", "",
            "Python stack (full exception retained in failure.json):", *traceback.format_tb(error.__traceback__)]
    (output / "failure.txt").write_text("\n".join(text))


def markdown(report):
    lines = ["# Foreground Overview Release A/B performance", "",
             "## Result and scope", "", f"Execution status: **{report['status']}**. Started: {report['startedAt']}.", ""]
    if failure := report.get("failure"):
        lines += ["### Execution failure", "", f"- Stage: `{failure['stage']}`.",
                  f"- Exit code: `{failure['exitCode']}`; exception: `{failure['exceptionType']}`.",
                  f"- {failure['summary']}", f"- Full tool log: `{failure['log'] or 'unavailable'}`; complete command/exception: `failure.json`.", ""]
        if failure["diagnosticTail"]:
            lines += ["Tool diagnostic tail (at most 80 lines / 12 KB; full log retained):", "", "````text",
                      failure["diagnosticTail"], "````", ""]
            if failure["diagnosticTailTruncated"]:
                lines += ["Earlier tool output is omitted here and remains in the full log.", ""]
    lines += ["This is a same-runner comparison of fixed product revisions, using the same verification source. "
             "A passing execution means all prescribed measurements are valid; it does not mean the candidate is faster.", "",
             "N=40; four running 2×1 cards must be fully visible. R0 keeps them running without source updates. "
             "S4 replaces a bounded text window at 10 events/s/card (40/s, staggered). "
             "A4 strictly appends at the same rates. Each process has 5s of load-bearing warmup and 20s formal supply. "
             "No profiler, diagnostic build, screenshot capture, hidden/background case, N100, or N500 is part of formal CPU.", "",
             "CPU% is 100 × process user+system CPU seconds / actual monotonic wall seconds, on a single-core scale. "
             "UI and Core are reported separately. Two opposite-order pairs are an initial screen, not a confidence interval "
             "or an estimate comparable to historical local-Mac percentages.", "", "## Fixed versions and builds", "",
             f"- Baseline A: `{report['baseline']}`", f"- Candidate B: `{report['candidate']}`",
             f"- Harness checkout: `{report.get('harnessRevision', 'unavailable')}`",
             f"- Harness source SHA256: `{report.get('harness', {}).get('sha256', 'unavailable')}`",
             "- Both products and probes: Release `-O -enable-testing`; Go runtime: ordinary optimized `go build`, without `-race`.", "",
             "| Side | Actual product commit | Product input SHA256 | Sources Git tree | Signed probe SHA256 | Core binary SHA256 |",
             "| --- | --- | --- | --- | --- | --- |"]
    for side, build in report.get("builds", {}).items():
        product = build.get("product", {})
        lines.append(f"| {side} | `{product.get('revision', '—')}` | `{product.get('sha256', '—')}` | "
                     f"`{product.get('sourcesGitTree', '—')}` | `{build.get('probeSHA256', '—')}` | `{build.get('runtimeSHA256', '—')}` |")
    lines += ["", "Product input hashes include versioned files in the macOS Sources/Plugins, Package files, internal/, cmd/, "
              "and Go module files. Per-file hashes and the digest algorithm are in build JSON; these are not the hash "
              "algorithm of any earlier local report. The shared harness is copied into both detached worktrees; product "
              "directories must remain clean before and after measurement.", "", "## Raw formal runs", "",
              "| Run | Condition | Order/side | Valid | UI CPU s / wall s | UI % | Core CPU s / wall s | Core % | Total % | Formal pubs / D | Formal wire bytes |",
              "| --- | --- | --- | --- | --- | ---: | --- | ---: | ---: | --- | ---: |"]
    for row in report["runs"]:
        result = row.get("result", {}); ui = result.get("ui", {}); core = result.get("core", {})
        cpu = core.get("cpu", {}); publish = core.get("publish", {}); values = cpu_values(row)
        lines.append(f"| {row['id']} | {row['condition']} | {row['order']}/{row['side']} | {row.get('valid', False)} | "
                     f"{number(ui.get('cpuSeconds'))} / {number(ui.get('wallSeconds'))} | {number(values[0])} | "
                     f"{number(cpu.get('cpuSeconds'))} / {number(cpu.get('wallSeconds'))} | {number(values[1])} | {number(values[2])} | "
                     f"{publish.get('formalCount', '—')} / {number(publish.get('dirtyCardMean'))} | {publish.get('wireBytes', '—')} |")
    lines += ["", "Wire bytes are formal publication NDJSON encoding bytes, not socket-delivery accounting. "
              "Warmup, formal and tail event counts remain separate in each Core result.", "", "## Paired changes", "",
              "Every delta is B − A; negative CPU percentage-point deltas mean less CPU. "
              "Relative reductions are positive when B uses less CPU. Invalid or missing runs never enter a pair.", "",
              "| Condition | Order | Valid pair | UI Δ pp | Core Δ pp | Total Δ pp | UI relative reduction | Total relative reduction |",
              "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |"]
    for pair in paired_results(report["runs"]):
        lines.append(f"| {pair['condition']} | {pair['order']} | {pair['valid']} | {number(pair.get('uiDeltaPP'))} | "
                     f"{number(pair.get('coreDeltaPP'))} | {number(pair.get('totalDeltaPP'))} | "
                     f"{number(pair.get('uiRelativeReductionPercent'))}% | {number(pair.get('totalRelativeReductionPercent'))}% |")
    for pair in paired_results(report["runs"]):
        if pair["invalidReasons"]:
            lines += ["", f"{pair['condition']} {pair['order']}: " + "; ".join(pair["invalidReasons"]) + "."]
    lines += ["", "## Model consumption and additional UI cost windows", "",
              "Fixed-window CPU can conceal different amounts of completed work when a consumer falls behind. "
              "The sequence/installation columns below are reconstructed from timestamped catalog receipts, "
              "and publish-to-install latency includes installations completed during the observation tail. "
              "These are model observations, not rendered pixels or direct queue-depth measurements.", "",
              "| Run | Valid | Formal installs | Sequences at formal CPU end | Later installs | Publish→install p50 / p95 ms | Final sequence install after last source accepted ms | Tail UI CPU s / wall s | Source start→tail end UI CPU s / wall s |",
              "| --- | --- | ---: | --- | ---: | --- | ---: | --- | --- |"]
    for row in report["runs"]:
        result = row.get("result", {}); flow = model_flow(result)
        latency = result.get("delivery", {}).get("publishToModelInstallMilliseconds", {})
        windows = result.get("uiWindows", {})
        tail, whole = windows.get("tailObservation", {}), windows.get("sourceThroughTailObservation", {})
        lines.append(f"| {row['id']} | {row.get('valid', False)} | {result.get('installations', {}).get('formalCount', '—')} | "
                     f"{flow.get('formalEndSequences', '—')} | {flow.get('postFormalInstallCount', '—')} | "
                     f"{number(latency.get('p50'))} / {number(latency.get('p95'))} | "
                     f"{number(flow.get('finalSequenceInstallAfterLastSourceAcceptedMilliseconds'))} | "
                     f"{number(tail.get('cpuSeconds'))} / {number(tail.get('wallSeconds'))} | "
                     f"{number(whole.get('cpuSeconds'))} / {number(whole.get('wallSeconds'))} |")
    lines += ["", "The tail CPU interval begins at the independent formal-end sample and ends after the existing "
              "model-stability observation. The whole UI interval also includes the five-second warmup. "
              "They include observation and any remaining model work, are not queue-drain or per-event costs, "
              "and must not be added to Core CPU measured over only the formal interval. A missing interval is unavailable, not zero.", ""]
    lines += ["", "## Validity, source convergence, memory and environment", ""]
    for row in report["runs"]:
        result = row.get("result", {}); source = result.get("core", {}).get("source", {}); ui = result.get("ui", {})
        boundaries = result.get("core", {}).get("boundaries", {})
        core_rss = [value.get("maximumRSSBytes") for value in boundaries.values() if isinstance(value, dict)]
        core_rss = [value for value in core_rss if numeric(value)]
        lines += [f"### {row['id']}", "", f"- Status: `{row.get('status')}`; invalid reasons: {json.dumps(row.get('invalidReasons', []), ensure_ascii=False)}.",
                  f"- Power before/after: `{row.get('powerBefore')}` / `{row.get('powerAfter')}`.",
                  f"- Source planned/sent/accepted: {source.get('planned', '—')} / {source.get('sent', '—')} / {source.get('accepted', '—')}; "
                  f"warm/formal/tail sent: {source.get('warmupSent', '—')} / {source.get('formalSent', '—')} / {source.get('tailSent', '—')}.",
                  f"- UI sampled physical footprint start/end/max: {ui.get('footprintStartBytes', '—')} / {ui.get('footprintEndBytes', '—')} / {ui.get('footprintMaxSampledBytes', '—')} bytes.",
                  f"- Core process maximum RSS across recorded boundaries: {max(core_rss) if core_rss else '—'} bytes; this is not UI physical footprint.",
                  f"- Formal window observations: {len(result.get('windowSamples', []))}; all validity failures remain in the run's invalid reasons.",
                  "- Core executable identity (reported/resolved paths and filesystem identity): `" + json.dumps(row.get("runtimeIdentity", {}), ensure_ascii=False) + "`.",
                  "- Formal CPU clock boundaries: `" + json.dumps(result.get("clock", {}), ensure_ascii=False) + "`.",
                  "- Additional UI CPU windows: `" + json.dumps(result.get("uiWindows", {}), ensure_ascii=False) + "`.",
                  "- Main-actor observation timing: `" + json.dumps(result.get("mainActorObservations", {}), ensure_ascii=False) + "`.",
                  "- Native decorations before/after: `" + json.dumps(result.get("nativeDecoration", {}), ensure_ascii=False) + "`.",
                  "- Window/visibility: `" + json.dumps(result.get("visibility", {}), ensure_ascii=False) + "`.",
                  "- Final per-card model state: `" + json.dumps(result.get("perCard", {}), ensure_ascii=False) + "`.",
                  "- Publication/model installation accounting: `" + json.dumps(result.get("delivery", {}), ensure_ascii=False) + "`.",
                  "- Tail observation: `" + json.dumps(result.get("tailObservation", {}), ensure_ascii=False) + "`.", ""]
    lines += ["Tail stability observation is not queue drain time or proof of displayed pixels. "
              "Missing direct queue/overflow/pixel measurements must not be inferred from final model convergence. "
              "All supplied raw events and publication records remain in the JSON evidence.", "",
              "### Machine and display", "", "```json", json.dumps(report.get("machine", {}), indent=2, ensure_ascii=False), "```", "",
              "```json", json.dumps(report.get("display", {}), indent=2, ensure_ascii=False), "```", "",
              "Display confirmation from a fresh process after the setup helper exited:", "", "```json",
              json.dumps(report.get("displayAfterHelperExit", {}), indent=2, ensure_ascii=False), "```", "",
              "## Failures and limitations", ""]
    lines += ["- " + str(error).replace("\n", " ") for error in report.get("errors", [])] or ["- No execution failures recorded."]
    lines += ["- One hosted macOS arm64 machine and display mode per invocation; cross-run hosts are not paired baselines.",
              "- Two AB/BA pairs per condition provide screening evidence only. No runs are automatically discarded or retried for their CPU value.",
              "- WindowServer pixels, GPU time, optical FPS and accessibility appearance are outside this CPU run.", "",
              "## Evidence and reproduction", "",
              "`report.json` contains the complete aggregate and original per-run results. `runs/<id>/` contains UI/Core JSON, "
              "runtime/source logs, native launch receipts, machine snapshots and cleanup receipts. `builds/A/` and `builds/B/` "
              "contain commands, logs and per-file source/binary identity. Display changes/restoration are recorded separately.", "", "```sh",
              f"python3 tools/verification/overview-ci-performance/run.py --baseline {report['baseline']} --candidate {report['candidate']} --output /tmp/overview-performance",
              "```", "", "The default command requires an already adequate real display. The hosted workflow additionally uses "
              "`--configure-display`, which may select an existing >=1265×800 mode only on a disposable GitHub Actions runner and restores it in cleanup. "
              "Actual full-card and whole-window screen containment remain the final validity checks.", ""]
    return "\n".join(lines)


def save_report(output, report):
    report["pairs"] = paired_results(report["runs"])
    report["modelFlow"] = {row["id"]: model_flow(row.get("result", {})) for row in report["runs"]}
    write_json(output / "report.json", report)
    (output / "report.md").write_text(markdown(report))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--configure-display", action="store_true")
    parser.add_argument("--time-budget-seconds", type=int, default=1650)
    args = parser.parse_args()
    for value in (args.baseline, args.candidate):
        if not re.fullmatch(r"[0-9a-f]{40}", value):
            parser.error("Both product revisions must be full lowercase 40-character commit SHAs")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {"schemaVersion": 1, "status": "running", "startedAt": utc(), "baseline": args.baseline,
              "candidate": args.candidate, "runs": [], "builds": {}, "errors": []}
    budget = Budget(args.time_budget_seconds)
    replays, worktrees = {}, []
    temporary = tempfile.TemporaryDirectory(prefix="mokusei-overview-performance-")
    work = Path(temporary.name).resolve()
    display_helper = work / "display-mode"
    display_record = output / "display.json"
    save_report(output, report)
    try:
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise RuntimeError("Formal Overview performance requires macOS arm64; no architecture emulation")
        if args.configure_display and os.environ.get("GITHUB_ACTIONS") != "true":
            raise RuntimeError("Automatic display changes are restricted to disposable GitHub Actions runners")
        for side, sha in (("A", args.baseline), ("B", args.candidate)):
            if git(ROOT, "rev-parse", sha + "^{commit}") != sha:
                raise RuntimeError("Fixed product commit is unavailable: " + sha)
        report["harnessRevision"] = git(ROOT, "rev-parse", "HEAD")
        harness_files = [path for path in SOURCE.rglob("*") if path.is_file() and
                         (path.suffix == ".swift" or path.suffix == ".go" or path.name == "run.py")]
        harness_files += [ROOT / "tools/verification/native_replay.py", ROOT / "tools/verification/NativeReplayIsolation.swift"]
        report["harness"] = hash_files(ROOT, harness_files)
        report["machine"] = machine_snapshot(full=True)
        helper_source = work / "display-mode.swift"
        helper_source.write_text(DISPLAY_SOURCE)
        command(["xcrun", "swiftc", "-parse-as-library", str(helper_source), "-o", str(display_helper)],
                output / "display-build.log", timeout=budget.remaining(60))
        command([str(display_helper), "prepare" if args.configure_display else "inspect", "unused", str(display_record)],
                output / "display-prepare.log", timeout=budget.remaining(20))
        report["display"] = json.loads(display_record.read_text())
        confirmation = output / "display-after-helper-exit.json"
        command([str(display_helper), "inspect", "unused", str(confirmation)],
                output / "display-confirm.log", timeout=budget.remaining(20))
        report["displayAfterHelperExit"] = json.loads(confirmation.read_text())
        save_report(output, report)
        for side, sha in (("A", args.baseline), ("B", args.candidate)):
            checkout = work / side
            command(["git", "worktree", "add", "--detach", str(checkout), sha], output / "builds" / side / "checkout.log",
                    timeout=budget.remaining(60))
            worktrees.append(checkout)
            for path in harness_files:
                destination = checkout / path.relative_to(ROOT)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
            copied = hash_files(checkout, [checkout / path.relative_to(ROOT) for path in harness_files])
            if copied != report["harness"]:
                raise RuntimeError("A/B harness source mismatch")
            product = product_identity(checkout)
            build_dir = output / "builds" / side
            write_json(build_dir / "product-inputs.json", product)
            report["builds"][side] = {"product": product, "harnessSHA256": copied["sha256"], "configuration": "release", "swiftFlags": SWIFT_FLAGS}
            save_report(output, report)
            swift = ["xcrun", "swift", "build", "--package-path", str(checkout / "app/macos"), "--configuration", "release",
                     "--product", "Mokusei", "--force-resolved-versions", "--disable-index-store", "-Xswiftc", "-O", "-Xswiftc", "-enable-testing"]
            command(swift, build_dir / "swift-build.log", cwd=checkout, timeout=budget.remaining(720))
            runtime = work / ("runtime-" + side)
            command(["go", "build", "-o", str(runtime), "./tools/verification/overview-ci-performance/runtime"],
                    build_dir / "go-build.log", cwd=checkout, timeout=budget.remaining(240))
            replay = NativeReplay(checkout, "OverviewPerformanceProbe", "com.mokusei.overview-performance", configuration="release")
            replays[side] = replay
            if side == "A":
                # One lease covers both staged apps and every serial run.
                replay.acquire()
            sources = sorted((checkout / SOURCE.relative_to(ROOT)).glob("*.swift"))
            if not sources:
                raise RuntimeError("Swift Overview performance harness is missing")
            probe_build = {"sources": list(map(str, sources)), "swiftFlags": SWIFT_FLAGS,
                           "configuration": "release", "startedAt": utc(), "succeeded": False}
            try:
                with native_build_log(build_dir / "probe-build.log"), time_limit(budget.remaining(120)):
                    replay.compile(sources, extra_args=SWIFT_FLAGS)
                probe_build["succeeded"] = True
            except BaseException as error:
                error.overview_log = build_dir / "probe-build.log"
                probe_build["command"] = getattr(error, "cmd", None)
                probe_build["exitCode"] = getattr(error, "returncode", None)
                raise
            finally:
                probe_build["finishedAt"] = utc()
                write_json(build_dir / "probe-build.json", probe_build)
            shutil.copy2(runtime, replay.workspace / "runtime")
            build = report["builds"][side]
            build.update(probeSHA256=digest(replay.executable), runtimeSHA256=digest(runtime),
                         stagedApplication=str(replay.application), stagedExecutable=str(replay.executable))
            write_json(build_dir / "build.json", build)
            save_report(output, report)
        # Reverse both side order and scenario order in the second block.
        sequence = [(condition, "AB", side) for condition in ("R0", "S4", "A4") for side in "AB"]
        sequence += [(condition, "BA", side) for condition in ("A4", "S4", "R0") for side in "BA"]
        for index, (condition, order, side) in enumerate(sequence, 1):
            identifier = f"{index:02d}-{condition}-{order}-{side}"
            run_dir = output / "runs" / identifier
            run_dir.mkdir(parents=True)
            replay = replays[side]
            # Confirm the previous app is gone before forgetting its PID. A stale
            # startup receipt would otherwise hide a new launch that dies before
            # prepareIsolatedNativeReplay writes its own receipt.
            replay.stop()
            for name in ("launch.json", "runtime-isolation.json", "result.json", "stdout.log", "stderr.log", "cleanup.json"):
                (replay.root / name).unlink(missing_ok=True)
            replay.stopped_pids.clear()
            replay.process = None
            staged_evidence = replay.workspace / "evidence"
            if staged_evidence.exists():
                shutil.rmtree(staged_evidence)
            staged_evidence.mkdir()
            result_path = staged_evidence / "ui-result.json"
            before = machine_snapshot()
            row = {"id": identifier, "condition": condition, "order": order, "side": side, "status": "running",
                   "valid": False, "invalidReasons": [], "startedAt": utc(), "powerBefore": power_source(before)}
            report["runs"].append(row)
            write_json(run_dir / "machine-before.json", before)
            save_report(output, report)
            print("MEASURE", identifier, flush=True)
            try:
                arguments = ["--condition", condition, "--n", "40", "--warmup", "5", "--seconds", "20",
                             "--runtime", str(replay.workspace / "runtime"), "--output", str(result_path)]
                row["command"] = arguments
                row["exitCode"] = replay.run(arguments, timeout=budget.remaining(90), launch_services=True,
                                               env={**os.environ, "NSUnbufferedIO": "YES"},
                                               launch_environment={"NSUnbufferedIO": "YES"})
                startup_path = replay.root / "runtime-isolation.json"
                if startup_path.is_file():
                    row["startupIdentity"] = json.loads(startup_path.read_text())
                    row["invalidReasons"].extend(validate_startup(row["startupIdentity"], replay, arguments))
                else:
                    row["invalidReasons"].append("Missing fresh native startup identity receipt")
                if result_path.is_file():
                    row["result"] = json.loads(result_path.read_text())
                    row["invalidReasons"].extend(validate_result(row["result"], condition, 20))
                    runtime_process = row["result"].get("runtimeProcess", {})
                    identity, identity_errors = validate_runtime_identity(
                        runtime_process, row.get("startupIdentity", {}), replay.workspace / "runtime")
                    row["runtimeIdentity"] = identity
                    row["invalidReasons"].extend(identity_errors)
                else:
                    row["invalidReasons"].append("Missing UI result; an exit code alone cannot certify measurement")
                if row["exitCode"] != 0:
                    row["invalidReasons"].append("Probe process returned " + str(row["exitCode"]))
            except (OSError, ValueError, RuntimeError, TimeoutError) as error:
                row["invalidReasons"].append(str(error))
            finally:
                try:
                    cleanup_runtime(replay, run_dir)
                except (OSError, ValueError) as error:
                    row["invalidReasons"].append("Owned runtime cleanup failed: " + str(error))
                try:
                    replay.export(run_dir)
                except OSError as error:
                    row["invalidReasons"].append("Native evidence export failed: " + str(error))
                after = machine_snapshot()
                write_json(run_dir / "machine-after.json", after)
                row["powerAfter"] = power_source(after)
                if row["powerBefore"] is None or row["powerBefore"] != row["powerAfter"]:
                    row["invalidReasons"].append("Power source was unknown or changed during this process")
                row["valid"] = not row["invalidReasons"]
                row["status"] = "valid" if row["valid"] else "invalid"
                row["finishedAt"] = utc()
                write_json(run_dir / "run.json", row)
                save_report(output, report)
        for side, checkout in zip(("A", "B"), worktrees):
            final = product_identity(checkout)
            if final != report["builds"][side]["product"]:
                raise RuntimeError("Product inputs changed while measuring " + side)
        report["status"] = "completed" if all(pair["valid"] for pair in paired_results(report["runs"])) else "invalid measurements"
        if report["status"] != "completed":
            report["errors"].append("At least one prescribed run or paired condition was invalid; its raw result is retained and no automatic retry was substituted.")
    except BaseException as error:
        report["status"] = "failed"
        record_failure(output, report, error)
    finally:
        if display_record.is_file():
            try:
                report["display"] = json.loads(display_record.read_text())
            except ValueError as error:
                report["errors"].append("Display receipt could not be decoded: " + str(error))
                report["status"] = "failed"
        for side in ("B", "A"):
            if side in replays:
                try:
                    replays[side].close()
                except BaseException as error:
                    report["errors"].append(f"{side} replay cleanup: {error}")
                    report["status"] = "failed"
        if report.get("display", {}).get("changed") and display_helper.is_file():
            try:
                command([str(display_helper), "restore", str(display_record), str(output / "display-restored.json")],
                        output / "display-restore.log", timeout=20)
            except BaseException as error:
                report["errors"].append("Display restoration: " + str(error))
                report["status"] = "failed"
        for checkout in reversed(worktrees):
            try:
                command(["git", "worktree", "remove", "--force", str(checkout)],
                        output / "builds" / checkout.name / "cleanup.log", timeout=30)
            except BaseException as error:
                report["errors"].append("Worktree cleanup: " + str(error))
        temporary.cleanup()
        report["finishedAt"] = utc()
        save_report(output, report)
        print("Overview performance:", report["status"], "—", output / "report.md", flush=True)
    return 0 if report["status"] == "completed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
