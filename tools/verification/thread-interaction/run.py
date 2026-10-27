"""Run mounted reading chaos against a signed production Release app and real Runtime."""
import argparse
import json
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools/native-interaction"))
from client import Client, Trace
from thread_chaos import ReadingDriver


def run_case(bundle, root, seed, steps, replay=None):
    root.mkdir(mode=0o700)
    profile, endpoint = root / "profile", root / "ui.sock"
    subprocess.run(["./scripts/go.sh", "run", "./tools/verification/thread-interaction", str(profile)], cwd=REPO, check=True)
    macos = bundle / "Contents/MacOS"
    client = None
    app = None
    log = (root / "app.log").open("w")
    trace = Trace(root / "reading.jsonl", command="reading-replay" if replay else "reading-monkey", seed=seed)
    try:
        # This is the unchanged production bundle and its bundled daemon. Only
        # the profile and semantic socket are isolated; native discovery is normal.
        app = subprocess.Popen([str(macos / "Mokusei"), "--data-dir", str(profile), "--automation-socket", str(endpoint)],
                               cwd=root, stdout=log, stderr=subprocess.STDOUT)
        (root / "launch.json").write_text(json.dumps({"pid": app.pid, "profile": str(profile), "socket": str(endpoint)}))
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if app.poll() is not None:
                raise RuntimeError(f"Production app exited before ready: {app.returncode}")
            try:
                client = Client(endpoint)
                if client.request()["pid"] != app.pid:
                    raise RuntimeError("Automation socket belongs to another app process")
                break
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(.1)
        if client is None:
            raise TimeoutError("Production automation socket did not become ready")
        client.settle(lambda state: state["runtimeAvailable"] and len(state["threads"]) == 3, timeout=90)
        driver = ReadingDriver(client, trace)
        if replay:
            driver.replay(replay)
        else:
            driver.route({"name": "thread.open", "typeId": "agent", "threadId": "interaction-c"})
            driver.targeted()
            driver.monkey(seed, steps)
        driver.wait()
        log.flush()
        if "Thread content release failed" in (root / "app.log").read_text():
            raise AssertionError("A scoped content release failed; inspect app.log")
        summary = {"result": "PASS", "seed": seed, "steps": steps, "replay": str(replay) if replay else None,
                   "coverage": dict(driver.coverage)}
        trace.write({"kind": "complete", **summary})
        (root / "summary.json").write_text(json.dumps(summary, indent=2))
        print(f"PASS reading {'replay' if replay else 'seed ' + str(seed)}: {root}", flush=True)
    except BaseException as error:
        trace.write({"kind": "failure", "error": str(error)})
        (root / "summary.json").write_text(json.dumps({"result": "FAIL", "seed": seed, "error": str(error)}, indent=2))
        raise
    finally:
        if client:
            client.close()
        if app is not None and app.poll() is None:
            app.send_signal(signal.SIGTERM)
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait(timeout=5)
        try:
            subprocess.run([str(macos / "mokusei-runtime"), "stop", "--data-dir", str(profile)], cwd=root, check=True, timeout=30)
        finally:
            trace.close()
            log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Existing signed production Release bundle; otherwise build one")
    parser.add_argument("--steps", type=int, default=100)
    parser.add_argument("--seeds", type=int, nargs="+", default=[41, 929, 20261024])
    parser.add_argument("--skip-replay", action="store_true")
    args = parser.parse_args()
    if args.steps < 1:
        parser.error("steps must be positive")
    root = Path(tempfile.mkdtemp(prefix="mokusei-reading-", dir="/private/tmp"))
    print(f"Reading evidence: {root}", flush=True)
    if args.app:
        bundle = args.app.resolve()
    else:
        subprocess.run(["./scripts/go.sh", "run", "./cmd/mokusei-dev", "bundle", "--channel", "production", "--configuration", "release", "--output", str(root / "bundle")], cwd=REPO, check=True)
        bundle = root / "bundle/Mokusei.app"
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    provenance = json.loads((bundle / "Contents/Resources/build-provenance.json").read_text())
    if info.get("CFBundleIdentifier") != "com.mokusei.desktop" or provenance.get("channel") != "production" or provenance.get("configuration") != "release":
        raise ValueError("Reading replay requires a signed production Release app")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    (root / "application.json").write_text(json.dumps({"app": str(bundle), "provenance": provenance}, indent=2))
    for index, seed in enumerate(args.seeds):
        run_case(bundle, root / f"seed-{index}-{seed}", seed, args.steps)
    if not args.skip_replay:
        run_case(bundle, root / "replay", args.seeds[0], args.steps, root / f"seed-0-{args.seeds[0]}" / "reading.jsonl")


if __name__ == "__main__":
    main()
