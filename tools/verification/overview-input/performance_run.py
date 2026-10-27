"""Run one preserved, isolated performance bundle; never retry contaminated work."""
import ctypes
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

from performance_support import interfering_process


def host_snapshot():
    result = subprocess.run(["ps", "-axo", "pid=,pcpu=,ucomm="], capture_output=True, text=True)
    rows = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=2)
        if len(fields) == 3:
            process = {"pid": int(fields[0]), "cpu": float(fields[1]), "name": fields[2].strip()}
            # An idle replay can still own a visible window or begin rendering
            # between samples. Keep its identity even below the reporting floor.
            if process["cpu"] >= 5 or interfering_process(process, 0):
                rows.append(process)
    return {"unix": time.time(), "processes": rows,
            "error": result.stderr.strip() or (f"ps exited {result.returncode}" if result.returncode else "")}


def run_performance(bundle, destination):
    bundle = bundle.resolve()
    run = bundle.parent
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    executable = bundle / "Contents/MacOS/OverviewInputReplay"
    raw, result, launch = run / "performance", run / "result.txt", run / "launch.json"
    if (run.parent != Path("/private/tmp") or not run.name.startswith("mokusei-overview-") or
            info.get("MokuseiGlassPerformanceDirectory") != str(raw) or
            info.get("MokuseiReplayResult") != str(result) or
            not info.get("CFBundleIdentifier", "").startswith("com.mokusei.overview-swiftui-replay.")):
        raise ValueError("Not an owned prepared performance bundle")
    build = json.loads((raw / "build.json").read_text())
    if build["bundle"] != str(bundle) or hashlib.sha256(executable.read_bytes()).hexdigest() != build["executableSHA256"]:
        raise ValueError("Prepared executable identity changed")
    source = Path(__file__).resolve().parent
    for name in ["performance.swift", "glass-fixture.swift", "performance_run.py", "performance_support.py", "analyze-performance.py", "run.py"]:
        if build["sources"].get(name) != hashlib.sha256((source / name).read_bytes()).hexdigest():
            raise ValueError("Prepared measurement code changed; rebuild before scheduling: " + name)
    if destination.exists() or launch.exists() or result.exists() or (raw / "prelaunch.json").exists():
        raise ValueError("Refusing to reuse a started trial or overwrite evidence")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)

    # Process-scoped lock; leave the file in place so another opener cannot
    # acquire a different inode while an older owner still holds its lock.
    lock = os.open("/private/tmp/mokusei-overview-performance.lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BaseException:
        os.close(lock)
        raise
    process = None
    outcome = {"phase": "prelaunch", "bundle": str(bundle), "startedAt": time.time()}
    try:
        # CoreGraphics SDK: combined-session state = 0, any input type = ~0U.
        # Read only idle duration, never input content or individual key events.
        graphics = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        idle_seconds = graphics.CGEventSourceSecondsSinceLastEventType
        idle_seconds.argtypes = [ctypes.c_int32, ctypes.c_uint32]
        idle_seconds.restype = ctypes.c_double
        observations, stable = [], 0
        for _ in range(180):
            snapshot = host_snapshot()
            idle = idle_seconds(0, 0xFFFFFFFF)
            busy = [p for p in snapshot["processes"] if interfering_process(p, 0)]
            stable = stable + 1 if math.isfinite(idle) and idle >= 30 and not busy and not snapshot["error"] else 0
            observations.append({**snapshot, "inputIdleSeconds": idle, "competing": busy, "stableSeconds": stable})
            (raw / "prelaunch.json").write_text(json.dumps(observations))
            if stable >= 30:
                break
            time.sleep(1)
        else:
            raise RuntimeError("No 30-second input-idle/compiler-free interval within 180 seconds; no GUI launched")
        outcome["phase"] = "launched"
        (raw / "power-start.txt").write_text(subprocess.check_output(["pmset", "-g", "batt"], text=True))
        # A single ordinary launch follows the idle gate. A background launch
        # suppresses initial activation on this OS; never compensate by forcing
        # activation or repeatedly reclaiming focus from another application.
        launched_at = time.monotonic()
        process = subprocess.Popen(["open", "-n", "-W", str(bundle)], cwd=run)
        with (raw / "host-processes.jsonl").open("w") as monitor:
            deadline = time.monotonic() + 1200
            while process.poll() is None:
                snapshot = host_snapshot()
                snapshot["inputIdleSeconds"] = idle_seconds(0, 0xFFFFFFFF)
                input_during_trial = snapshot["inputIdleSeconds"] < time.monotonic() - launched_at
                monitor.write(json.dumps(snapshot) + "\n"); monitor.flush()
                try:
                    owned_pid = json.loads(launch.read_text())["pid"]
                except (FileNotFoundError, json.JSONDecodeError):
                    owned_pid = None  # The small launch record may still be being written.
                if owned_pid is not None:
                    competing = [p for p in snapshot["processes"] if interfering_process(p, owned_pid)]
                    abort = raw / "external-interference.json"
                    if (competing or snapshot["error"] or input_during_trial) and not abort.exists():
                        temporary = raw / "external-interference.tmp"
                        temporary.write_text(json.dumps({"unix": snapshot["unix"], "processes": competing,
                            "error": snapshot["error"], "sessionInputDuringTrial": input_during_trial,
                            "inputIdleSeconds": snapshot["inputIdleSeconds"]}))
                        temporary.replace(abort)
                if time.monotonic() > deadline:
                    raise TimeoutError("Performance fixture exceeded 20 minutes")
                time.sleep(2)
        report = result.read_text() if result.exists() else "Missing native result"
        outcome["nativeResult"] = report
        if process.returncode or not report.startswith("PASS "):
            raise RuntimeError(report.strip())
        outcome["phase"] = "collected"
    except BaseException as error:
        outcome["error"] = str(error)
        raise
    finally:
        if process is not None and process.poll() is None:
            try:
                owned = json.loads(launch.read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                owned = None
            if owned:
                current = subprocess.run(["ps", "-p", str(owned["pid"]), "-o", "comm="], capture_output=True, text=True)
                if owned["bundle"] == str(bundle) and current.stdout.strip() == str(executable):
                    try:
                        os.kill(owned["pid"], 15)
                    except ProcessLookupError:
                        pass
            process.terminate()
            process.wait(timeout=10)
        try:
            outcome["endedAt"] = time.time()
            (raw / "run-status.json").write_text(json.dumps(outcome, indent=2))
            (raw / "power-end.txt").write_text(subprocess.check_output(["pmset", "-g", "batt"], text=True))
            shutil.copytree(raw, destination)
            for path in [launch, result]:
                if path.exists():
                    shutil.copy2(path, destination / path.name)
        finally:
            os.close(lock)
