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
SOURCE_PROTOCOL_VERSION = 2
SOURCE_QUEUE_CAPACITY = 256

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


def integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def object_value(value):
    """A view for formatting partial receipts; validators still reject the type."""
    return value if isinstance(value, dict) else {}


def validate_source_v2(core, condition):
    """Recompute the input contract; never reinterpret historical v1 runs."""
    reasons = []
    expected = 0 if condition == "R0" else 1000
    if not isinstance(core, dict):
        return ["Core result is not an object"]
    malformed_containers = [key for key in ("schedule", "source", "queue", "windows") if not isinstance(core.get(key), dict)]
    if malformed_containers:
        return ["Core source contract has missing/non-object fields: " + ", ".join(malformed_containers)]
    for label, value in (("Core", core), ("schedule", core.get("schedule", {}))):
        if (not integer(value.get("sourceProtocolVersion")) or value.get("sourceProtocolVersion") != SOURCE_PROTOCOL_VERSION or
                not integer(value.get("sourceQueueCapacity")) or value.get("sourceQueueCapacity") != SOURCE_QUEUE_CAPACITY):
            reasons.append(label + " must identify source protocol v2 and queue capacity 256")
    if any(core.get(key) is not True for key in ("sourceComplete", "enqueueComplete", "producerFinished")):
        reasons.append("Independent source/worker completion is missing")
    source, queue, events = core["source"], core["queue"], core.get("sourceEvents")
    if not isinstance(source.get("errors"), list) or source.get("errors"):
        reasons.append("Source errors must be an empty array")
    if not isinstance(events, list) or len(events) != expected or not all(isinstance(event, dict) for event in events):
        return reasons + ["The complete planned source-event inventory is missing"]
    stage_fields = ("planned", "enqueued", "dequeued", "sent", "storeUpdateStarted", "accepted", "completed")
    malformed = []
    for index, event in enumerate(events):
        if (not integer(event.get("index")) or not integer(event.get("seq")) or
                event.get("index") != index or event.get("cardID") != f"card-{index % 4}" or event.get("seq") != index // 4):
            malformed.append(index)
            continue
        values = [event.get(stage + suffix) for stage in stage_fields for suffix in ("UnixNano", "ElapsedNanoseconds")]
        if not all(integer(value) and value >= 0 for value in values):
            malformed.append(index)
            continue
        if any(bool(event[stage + "UnixNano"]) != bool(event[stage + "ElapsedNanoseconds"]) for stage in stage_fields):
            malformed.append(index)
            continue
        observed = [event[stage + "ElapsedNanoseconds"] for stage in stage_fields if event[stage + "ElapsedNanoseconds"]]
        # A cancelled task can have dequeued/completed receipts without sent or
        # Store.Update. Accepted work must have every predecessor stage.
        if observed != sorted(observed) or not event["plannedUnixNano"] or (
                event["acceptedUnixNano"] and not all(event[stage + "UnixNano"] for stage in stage_fields)):
            malformed.append(index)
    if malformed:
        return reasons + ["Malformed or non-monotonic source receipts at indices " + str(malformed)]
    totals = {stage: sum(event[stage + "UnixNano"] > 0 for event in events)
              for stage in ("enqueued", "dequeued", "sent", "accepted", "completed")}
    for stage in ("planned", "enqueued", "dequeued", "sent", "accepted"):
        actual = expected if stage == "planned" else totals[stage]
        if not integer(source.get(stage)) or source.get(stage) != actual or actual != expected:
            reasons.append(f"Source {stage} does not match the prescribed/observed event count")
    pending = [event["index"] for event in events if event["enqueuedUnixNano"] and not event["dequeuedUnixNano"]]
    in_flight = [event["index"] for event in events if event["dequeuedUnixNano"] and not event["completedUnixNano"]]
    if not all(integer(queue.get(key)) for key in ("capacity", "pending", "inFlight", "inFlightIndex", "overflowCount", "highWater")):
        reasons.append("Input FIFO counters must be explicit JSON integers")
    if (queue.get("capacity") != SOURCE_QUEUE_CAPACITY or queue.get("closed") is not True or
            queue.get("overflowCount") != 0 or queue.get("pending") != 0 or queue.get("inFlight") != 0):
        reasons.append("Input FIFO was not closed and empty without overflow")
    if (queue.get("pendingIndices") != pending or queue.get("pending") != len(pending) or
            queue.get("inFlight") != len(in_flight) or
            queue.get("inFlightIndex") != (in_flight[0] if len(in_flight) == 1 else -1) or
            totals["enqueued"] != totals["dequeued"] + len(pending) or
            totals["dequeued"] != totals["completed"] + len(in_flight)):
        reasons.append("Final input FIFO and event receipts do not conserve admitted work")
    if not integer(queue.get("highWater")) or not 0 <= queue["highWater"] <= SOURCE_QUEUE_CAPACITY:
        reasons.append("Input FIFO high-water receipt is invalid")
    for name, stage, is_gate in (("enqueueDeadline", "enqueued", True), ("legacySentDeadline", "sent", False)):
        observed = [event for event in events if event[stage + "UnixNano"]]
        late = [event["index"] for event in observed if
                event[stage + "ElapsedNanoseconds"] - event["plannedElapsedNanoseconds"] > 50_000_000]
        maximum = max([0] + [event[stage + "ElapsedNanoseconds"] - event["plannedElapsedNanoseconds"] for event in observed]) / 1e6
        receipt = source.get(name)
        if not isinstance(receipt, dict):
            reasons.append(name + " is missing or not an object")
            if is_gate and late:
                reasons.append("Actual source enqueue exceeded the unchanged 50ms deadline at indices " + str(late))
            continue
        if (not all(integer(receipt.get(key)) for key in ("thresholdMilliseconds", "observedCount", "missingCount", "exceededCount")) or
                not isinstance(receipt.get("exceededIndices"), list) or not all(integer(index) for index in receipt["exceededIndices"]) or
                receipt.get("thresholdMilliseconds") != 50 or receipt.get("observedCount") != len(observed) or
                receipt.get("missingCount") != expected - len(observed) or receipt.get("exceededCount") != len(late) or
                receipt.get("exceededIndices") != late or receipt.get("wouldFail") is not bool(late) or
                receipt.get("isValidityGate") is not is_gate or not numeric(receipt.get("maxLatenessMilliseconds")) or
                abs(receipt["maxLatenessMilliseconds"] - maximum) > 1e-6):
            reasons.append(name + " does not match the retained monotonic receipts")
        if is_gate and late:
            reasons.append("Actual source enqueue exceeded the unchanged 50ms deadline at indices " + str(late))
    schedule = core.get("schedule", {})
    start = schedule.get("warmupStartUnixNano")
    if (not integer(start) or schedule.get("formalStartUnixNano") != start + 5_000_000_000 or
            schedule.get("formalEndUnixNano") != start + 25_000_000_000 or schedule.get("warmupSeconds") != 5 or
            schedule.get("formalSeconds") != 20 or schedule.get("sourceIntervalNanoseconds") != 25_000_000 or
            any(event["plannedUnixNano"] != start + event["index"] * 25_000_000 or
                event["plannedElapsedNanoseconds"] != events[0]["plannedElapsedNanoseconds"] + event["index"] * 25_000_000
                for event in events)):
        reasons.append("Independent source schedule differs from the fixed 5+20 seconds and 25ms interval")
    for phase, prefix in (("warmup", "warmup"), ("formal", "formal"), ("tail", "tail")):
        window = core["windows"].get(phase)
        if not isinstance(window, dict):
            reasons.append(phase + " Core count window is missing or not an object")
            continue
        before, after = window.get("startUnixNano"), window.get("endUnixNano")
        if not integer(before) or not integer(after) or after < before:
            reasons.append(phase + " Core count window is missing")
            continue
        for stage in ("planned", "enqueued", "dequeued", "sent", "accepted"):
            actual = sum(before <= event[stage + "UnixNano"] < after for event in events)
            if not integer(window.get(stage)) or window.get(stage) != actual:
                reasons.append(f"{phase} {stage} count does not match actual timestamp boundaries")
            if stage in ("enqueued", "dequeued", "sent") and (not integer(source.get(prefix + stage.capitalize())) or source.get(prefix + stage.capitalize()) != actual):
                reasons.append(f"source.{prefix + stage.capitalize()} does not match actual timestamp boundaries")
    return reasons


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
    if not isinstance(result, dict):
        return ["UI result is not an object"]
    if result.get("schemaVersion") != 1 or result.get("condition") != condition or result.get("n") != 40 or result.get("k") != 4:
        reasons.append("Unexpected result schema or scenario")
    if result.get("valid") is not True:
        reasons.extend(result.get("invalidReasons") or ["UI harness did not certify foreground validity"])
    if not isinstance(result.get("comparisonIdentity"), dict) or not result["comparisonIdentity"]:
        reasons.append("Missing stable fixture/window/display comparison identity")
    for label, value in (("UI", result), ("comparison identity", object_value(result.get("comparisonIdentity")))):
        if (not integer(value.get("sourceProtocolVersion")) or value.get("sourceProtocolVersion") != SOURCE_PROTOCOL_VERSION or
                not integer(value.get("sourceQueueCapacity")) or value.get("sourceQueueCapacity") != SOURCE_QUEUE_CAPACITY):
            reasons.append(label + " must identify source protocol v2 and queue capacity 256")
    checks = object_value(result.get("sourceProtocolChecks"))
    if any(checks.get(stage) is not True for stage in ("ready", "start", "status", "result", "final")):
        reasons.append("Source protocol handshake was not verified at every ready/start/status/result/final stage")
    core = object_value(result.get("core"))
    if core.get("valid") is not True:
        reasons.extend(core.get("invalidReasons") or ["Core harness did not certify source/publication validity"])
    for label, cpu in (("UI", object_value(result.get("ui"))), ("Core", object_value(core.get("cpu")))):
        values = [cpu.get(key) for key in ("cpuSeconds", "wallSeconds", "cpuPercent")]
        if not all(numeric(value) for value in values) or values[0] < 0 or values[1] < seconds * 0.9:
            reasons.append(label + " has missing/invalid formal CPU or a shortened formal interval")
        elif abs(values[2] - 100 * values[0] / values[1]) > 0.02:
            reasons.append(label + " CPU percentage does not match CPU seconds / actual wall seconds")
    reasons.extend(validate_source_v2(core, condition))
    return list(dict.fromkeys(map(str, reasons)))


def cpu_values(record):
    result = object_value(record.get("result"))
    ui = object_value(result.get("ui")).get("cpuPercent")
    core = object_value(object_value(result.get("core")).get("cpu")).get("cpuPercent")
    return (ui, core, ui + core) if numeric(ui) and numeric(core) else (None, None, None)


def distribution(values):
    values = sorted(value for value in values if numeric(value))
    return {"count": len(values), "p50": values[math.ceil(0.50 * len(values)) - 1] if values else None,
            "p95": values[math.ceil(0.95 * len(values)) - 1] if values else None,
            "min": values[0] if values else None, "max": values[-1] if values else None,
            "percentileMethod": "nearest rank"}


def source_flow(result):
    """Link exact (card,seq) receipts; skipped intermediate seqs have no latency."""
    result = object_value(result)
    core = object_value(result.get("core"))
    summary = {"available": integer(core.get("sourceProtocolVersion")) and core.get("sourceProtocolVersion") == SOURCE_PROTOCOL_VERSION,
               "meaning": "All supplied events, including warmup and tail; exact published seqs only. "
                          "Core intervals use monotonic receipts; cross-process model time uses the recorded UTC anchor. "
                          "A coalesced event is covered by a higher published seq, not individually published/installed."}
    if not summary["available"]:
        return summary
    events, publications = core.get("sourceEvents"), core.get("publications")
    records = object_value(result.get("installations")).get("records")
    if (not isinstance(events, list) or not all(isinstance(event, dict) and integer(event.get("index")) and
            integer(event.get("seq")) and isinstance(event.get("cardID"), str) for event in events) or
            not isinstance(publications, list) or not all(isinstance(item, dict) and
            all(integer(item.get(key)) and item[key] > 0 for key in ("revision", "publishedUnixNano", "publishedElapsedNanoseconds")) and
            isinstance(item.get("cardIDs"), list) and isinstance(item.get("seqs"), list) and
            len(item["cardIDs"]) == len(item["seqs"]) and all(isinstance(card, str) for card in item["cardIDs"]) and
            all(integer(seq) for seq in item["seqs"]) for item in publications) or
            not isinstance(records, list) or not all(isinstance(record, dict) and
            all(integer(record.get(key)) for key in ("catalogRevision", "unixNanoseconds", "uptimeNanoseconds")) and
            isinstance(record.get("sequences"), list) for record in records)):
        summary.update(available=False, unavailableReason="Incomplete or malformed source/publication/model trace; raw result retained")
        return summary
    by_revision = {}
    for record in records:
        if record.get("kind") == "mutation" and integer(record.get("catalogRevision")) and numeric(record.get("unixNanoseconds")):
            prior = by_revision.get(record["catalogRevision"])
            if prior is None or prior["unixNanoseconds"] > record["unixNanoseconds"]:
                by_revision[record["catalogRevision"]] = record
    exact, per_card = {}, {}
    for publication in publications:
        for card, seq in zip(publication.get("cardIDs", []), publication.get("seqs", [])):
            exact.setdefault((card, seq), []).append(publication)
            per_card.setdefault(card, []).append((seq, publication))
    rows = []
    metrics = {key: [] for key in ("plannedToPublicationMilliseconds", "enqueueToPublicationMilliseconds",
               "acceptedToPublicationMilliseconds", "enqueueToModelInstallMilliseconds", "plannedToModelInstallMilliseconds")}
    counts = {key: 0 for key in ("planned", "exactPublished", "exactInstalled", "coalescedBeforePublication",
                                "acceptedWithoutPublication", "notEnqueued", "enqueuedUnaccepted")}
    for event in events:
        counts["planned"] += 1
        card, seq = event.get("cardID"), event.get("seq")
        row = {"index": event.get("index"), "cardID": card, "seq": seq}
        published = exact.get((card, seq), [])
        if published:
            counts["exactPublished"] += 1
            first = min(published, key=lambda item: item["publishedElapsedNanoseconds"])
            row["firstExactPublication"] = {"catalogRevision": first["revision"], "unixNanoseconds": first["publishedUnixNano"],
                                             "elapsedNanoseconds": first["publishedElapsedNanoseconds"]}
            for metric, field in (("plannedToPublicationMilliseconds", "plannedElapsedNanoseconds"),
                                  ("enqueueToPublicationMilliseconds", "enqueuedElapsedNanoseconds"),
                                  ("acceptedToPublicationMilliseconds", "acceptedElapsedNanoseconds")):
                if numeric(event.get(field)) and event[field] > 0:
                    value = (first["publishedElapsedNanoseconds"] - event[field]) / 1e6
                    row[metric] = value
                    metrics[metric].append(value)
            matches = []
            for publication in published:
                record = by_revision.get(publication["revision"])
                card_number = event["index"] % 4
                sequences = record.get("sequences", []) if record else []
                if len(sequences) == 4 and sequences[card_number] == seq:
                    matches.append(record)
            if matches:
                counts["exactInstalled"] += 1
                installed = min(matches, key=lambda item: item["unixNanoseconds"])
                row["classification"] = "exactPublishedAndInstalled"
                row["firstExactModelInstallation"] = {"catalogRevision": installed["catalogRevision"],
                    "unixNanoseconds": installed["unixNanoseconds"], "uptimeNanoseconds": installed["uptimeNanoseconds"]}
                for metric, field in (("enqueueToModelInstallMilliseconds", "enqueuedUnixNano"),
                                      ("plannedToModelInstallMilliseconds", "plannedUnixNano")):
                    if numeric(event.get(field)) and event[field] > 0:
                        value = (installed["unixNanoseconds"] - event[field]) / 1e6
                        row[metric] = value
                        metrics[metric].append(value)
            else:
                row["classification"] = "exactPublishedWithoutMatchingInstallation"
        elif not event.get("enqueuedUnixNano"):
            counts["notEnqueued"] += 1
            row["classification"] = "notEnqueued"
        elif not event.get("acceptedUnixNano"):
            counts["enqueuedUnaccepted"] += 1
            row["classification"] = "enqueuedUnaccepted"
        else:
            covering = [(newer, publication) for newer, publication in per_card.get(card, []) if newer > seq]
            if covering:
                counts["coalescedBeforePublication"] += 1
                newer, publication = min(covering, key=lambda item: item[1]["publishedElapsedNanoseconds"])
                row.update(classification="coalescedBeforePublication", coveredBySequence=newer,
                           coveredByPublicationRevision=publication["revision"])
            else:
                counts["acceptedWithoutPublication"] += 1
                row["classification"] = "acceptedWithoutPublication"
        rows.append(row)
    summary.update(counts=counts, latency={key: distribution(values) for key, values in metrics.items()}, records=rows,
                   acceptedToPublicationMayBeNegative="Production Store publishes committed state before Update returns; "
                                                      "signed intervals are retained, never clamped to zero.")
    return summary


def model_flow(result):
    """Summarize completed model work separately from fixed-window CPU."""
    result = object_value(result)
    records = object_value(result.get("installations")).get("records", [])
    records = [record for record in records if isinstance(record, dict)] if isinstance(records, list) else []
    core = object_value(result.get("core"))
    end = object_value(object_value(result.get("clock")).get("formalEnd")).get("uptimeNanoseconds")
    summary = {"meaning": "Model catalog installation, not queue depth, pixels or frame rate"}
    if not numeric(end):
        return summary
    before = [record for record in records if numeric(record.get("uptimeNanoseconds"))
              and record["uptimeNanoseconds"] <= end]
    if before:
        summary["formalEndSequences"] = max(before, key=lambda record: record["uptimeNanoseconds"]).get("sequences")
    summary["postFormalInstallCount"] = sum(
        numeric(record.get("uptimeNanoseconds")) and record["uptimeNanoseconds"] > end for record in records)
    expected = core.get("expectedCards", [])
    expected = [card for card in expected if isinstance(card, dict) and isinstance(card.get("id"), str)] if isinstance(expected, list) else []
    target = [card.get("seq") for card in sorted(expected, key=lambda card: card["id"])]
    completed = [record for record in records if len(target) == 4 and record.get("sequences") == target
                 and numeric(record.get("unixNanoseconds"))]
    events = core.get("sourceEvents", [])
    events = [event for event in events if isinstance(event, dict)] if isinstance(events, list) else []
    accepted = [event.get("acceptedUnixNano") for event in events]
    accepted = [value for value in accepted if numeric(value) and value > 0]
    if completed and accepted:
        first = min(record["unixNanoseconds"] for record in completed)
        last = max(accepted)
        summary.update(firstFinalSequenceInstallUnixNanoseconds=first, lastSourceAcceptedUnixNanoseconds=last,
                       finalSequenceInstallAfterLastSourceAcceptedMilliseconds=(first - last) / 1e6)
    enqueued = [event.get("enqueuedUnixNano") for event in events]
    enqueued = [value for value in enqueued if numeric(value) and value > 0]
    if completed and enqueued:
        first, last = min(record["unixNanoseconds"] for record in completed), max(enqueued)
        summary.update(lastSourceEnqueuedUnixNanoseconds=last,
                       finalSequenceInstallAfterLastSourceEnqueuedMilliseconds=(first - last) / 1e6)
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
             f"- Source protocol: `{report.get('sourceProtocolVersion', 'unavailable')}`; bounded input FIFO capacity: `{report.get('sourceQueueCapacity', 'unavailable')}`.",
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
        result = object_value(row.get("result")); ui = object_value(result.get("ui")); core = object_value(result.get("core"))
        cpu = object_value(core.get("cpu")); publish = object_value(core.get("publish")); values = cpu_values(row)
        lines.append(f"| {row['id']} | {row['condition']} | {row['order']}/{row['side']} | {row.get('valid', False)} | "
                     f"{number(ui.get('cpuSeconds'))} / {number(ui.get('wallSeconds'))} | {number(values[0])} | "
                     f"{number(cpu.get('cpuSeconds'))} / {number(cpu.get('wallSeconds'))} | {number(values[1])} | {number(values[2])} | "
                     f"{publish.get('formalCount', '—')} / {number(publish.get('dirtyCardMean'))} | {publish.get('wireBytes', '—')} |")
    lines += ["", "Wire bytes are formal publication NDJSON encoding bytes, not socket-delivery accounting. "
              "Warmup, formal and tail event counts remain separate in each Core result.", "", "## Independent input and worker accounting", "",
              "Protocol v2 enqueues lightweight identities on independent fixed 25ms deadlines into a 256-item FIFO. "
              "One serial worker performs the original reducer and Store.Update. Actual enqueue lateness above 50ms, overflow, "
              "incomplete inputs, or failed final convergence invalidate a run. Worker backlog does not move the source or formal CPU boundaries "
              "or extend the original five-second tail budget. The old sent−planned 50ms timing result remains visible; "
              "its wouldFail flag describes that timing criterion alone, not the validity of an old run.", "",
              "| Run | Valid | Planned / enqueued / dequeued / sent / accepted | Enqueued warm / formal / tail | Actual enqueue >50ms count / max ms | Legacy sent >50ms count / max ms / would fail | FIFO high water / pending / in flight / overflow |",
              "| --- | --- | --- | --- | --- | --- | --- |"]
    for row in report["runs"]:
        core = object_value(object_value(row.get("result")).get("core")); source = object_value(core.get("source")); queue = object_value(core.get("queue"))
        enqueue, legacy = object_value(source.get("enqueueDeadline")), object_value(source.get("legacySentDeadline"))
        totals = " / ".join(str(source.get(key, "—")) for key in ("planned", "enqueued", "dequeued", "sent", "accepted"))
        phases = " / ".join(str(source.get(key, "—")) for key in ("warmupEnqueued", "formalEnqueued", "tailEnqueued"))
        queued = " / ".join(str(queue.get(key, "—")) for key in ("highWater", "pending", "inFlight", "overflowCount"))
        lines.append(f"| {row['id']} | {row.get('valid', False)} | {totals} | {phases} | "
                     f"{enqueue.get('exceededCount', '—')} / {number(enqueue.get('maxLatenessMilliseconds'))} | "
                     f"{legacy.get('exceededCount', '—')} / {number(legacy.get('maxLatenessMilliseconds'))} / {legacy.get('wouldFail', '—')} | {queued} |")
    lines += ["", "| Run | Queue wait p50 / p95 / max ms | Dequeue→sent max ms | Reducer/projection preparation p95 / max ms | Store.Update p95 / max ms | Enqueue→accepted p95 / max ms |",
              "| --- | --- | --- | --- | --- | --- |"]
    for row in report["runs"]:
        times = object_value(object_value(object_value(row.get("result")).get("core")).get("sourceTimings"))
        columns = []
        for key, fields in (("queueWait", ("p50", "p95", "max")), ("dequeueToSent", ("max",)),
                            ("preparation", ("p95", "max")), ("storeUpdate", ("p95", "max")), ("enqueueThroughAccepted", ("p95", "max"))):
            columns.append(" / ".join(number(object_value(times.get(key)).get(field)) for field in fields))
        lines.append(f"| {row['id']} | " + " | ".join(columns) + " |")
    lines += ["", "These stages describe the benchmark input FIFO and real serial mutation worker, not a measured production "
              "Store/HTTP/UI queue. Per-event planned/enqueued/dequeued/sent/Store-start/accepted/completed timestamps, failed or "
              "unaccepted indices, and overflow attempts remain in JSON. Historical queue boundaries are reconstructed from "
              "monotonic event receipts; they are not queue.snapshot calls taken atomically with the rusage samples.", "",
              "## Paired changes", "",
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
              "| Run | Valid | Formal installs | Sequences at formal CPU end | Later installs | Publish→install p50 / p95 ms | Final install after last accepted / last enqueued ms | Tail UI CPU s / wall s | Source start→tail end UI CPU s / wall s |",
              "| --- | --- | ---: | --- | ---: | --- | --- | --- | --- |"]
    for row in report["runs"]:
        result = object_value(row.get("result")); flow = model_flow(result)
        latency = object_value(object_value(result.get("delivery")).get("publishToModelInstallMilliseconds"))
        windows = object_value(result.get("uiWindows"))
        tail, whole = object_value(windows.get("tailObservation")), object_value(windows.get("sourceThroughTailObservation"))
        lines.append(f"| {row['id']} | {row.get('valid', False)} | {object_value(result.get('installations')).get('formalCount', '—')} | "
                     f"{flow.get('formalEndSequences', '—')} | {flow.get('postFormalInstallCount', '—')} | "
                     f"{number(latency.get('p50'))} / {number(latency.get('p95'))} | "
                     f"{number(flow.get('finalSequenceInstallAfterLastSourceAcceptedMilliseconds'))} / "
                     f"{number(flow.get('finalSequenceInstallAfterLastSourceEnqueuedMilliseconds'))} | "
                     f"{number(tail.get('cpuSeconds'))} / {number(tail.get('wallSeconds'))} | "
                     f"{number(whole.get('cpuSeconds'))} / {number(whole.get('wallSeconds'))} |")
    lines += ["", "The tail CPU interval begins at the independent formal-end sample and ends after the existing "
              "model-stability observation. The whole UI interval also includes the five-second warmup. "
              "They include observation and any remaining model work, are not queue-drain or per-event costs, "
              "and must not be added to Core CPU measured over only the formal interval. A missing interval is unavailable, not zero.", ""]
    lines += ["## Exact source sequence to publication and model", "",
              "The next table covers all supplied events, including warmup and tail. It matches each publication's (card ID, seq) "
              "and its actual catalog-revision installation. Intermediate source seqs absent from publications but covered by a "
              "higher published seq are explicitly coalesced; they receive no invented publication/install timestamp or latency. "
              "Latencies are event-weighted over exact matches, unlike the publication-weighted formal delivery table above. "
              "Signed accepted→publish can be negative because Store notifies committed state before Update returns; values are not clamped.", "",
              "| Run | Exact published / installed | Coalesced / accepted unobserved | Enqueue→publish p50 / p95 ms | Enqueue→model p50 / p95 ms | Accepted→publish min / p95 ms |",
              "| --- | --- | --- | --- | --- | --- |"]
    for row in report["runs"]:
        flow = source_flow(row.get("result", {})); counts, latency = flow.get("counts", {}), flow.get("latency", {})
        ep, em, ap = (latency.get(key, {}) for key in ("enqueueToPublicationMilliseconds", "enqueueToModelInstallMilliseconds", "acceptedToPublicationMilliseconds"))
        lines.append(f"| {row['id']} | {counts.get('exactPublished', '—')} / {counts.get('exactInstalled', '—')} | "
                     f"{counts.get('coalescedBeforePublication', '—')} / {counts.get('acceptedWithoutPublication', '—')} | "
                     f"{number(ep.get('p50'))} / {number(ep.get('p95'))} | {number(em.get('p50'))} / {number(em.get('p95'))} | "
                     f"{number(ap.get('min'))} / {number(ap.get('p95'))} |")
    lines += ["", "## Validity, source convergence, memory and environment", ""]
    for row in report["runs"]:
        result = object_value(row.get("result")); core = object_value(result.get("core")); source = object_value(core.get("source")); ui = object_value(result.get("ui"))
        boundaries = object_value(core.get("boundaries"))
        core_rss = [value.get("maximumRSSBytes") for value in boundaries.values() if isinstance(value, dict)]
        core_rss = [value for value in core_rss if numeric(value)]
        lines += [f"### {row['id']}", "", f"- Status: `{row.get('status')}`; invalid reasons: {json.dumps(row.get('invalidReasons', []), ensure_ascii=False)}.",
                  f"- Power before/after: `{row.get('powerBefore')}` / `{row.get('powerAfter')}`.",
                  f"- Source planned/enqueued/dequeued/sent/accepted: {source.get('planned', '—')} / {source.get('enqueued', '—')} / {source.get('dequeued', '—')} / {source.get('sent', '—')} / {source.get('accepted', '—')}; "
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
                  "- Source deadline gates, including the historical sent criterion: `" + json.dumps({key: source.get(key) for key in ("enqueueDeadline", "legacySentDeadline")}, ensure_ascii=False) + "`.",
                  "- Input FIFO, outstanding work and reconstructed boundary states: `" + json.dumps(core.get("queue", {}), ensure_ascii=False) + "`.",
                  "- Tail observation: `" + json.dumps(result.get("tailObservation", {}), ensure_ascii=False) + "`.", ""]
    lines += ["Tail stability observation is not queue drain time or proof of displayed pixels. "
              "Unobserved production Store/HTTP/UI queues and pixels must not be inferred from the instrumented input FIFO or final model convergence. "
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
    report["sourceFlow"] = {row["id"]: source_flow(row.get("result", {})) for row in report["runs"]}
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
    report = {"schemaVersion": 1, "sourceProtocolVersion": SOURCE_PROTOCOL_VERSION, "sourceQueueCapacity": SOURCE_QUEUE_CAPACITY,
              "status": "running", "startedAt": utc(), "baseline": args.baseline,
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
                    decoded = json.loads(result_path.read_text())
                    if not isinstance(decoded, dict):
                        row["malformedResult"] = decoded
                        raise ValueError("UI result is not a JSON object; original file retained")
                    row["result"] = decoded
                    row["invalidReasons"].extend(validate_result(row["result"], condition, 20))
                    runtime_process = object_value(row["result"].get("runtimeProcess"))
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
