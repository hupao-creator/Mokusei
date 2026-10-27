"""Exercise Settings inside a signed production Release app with its real runtime."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools/native-interaction"))
import client as api
import settings_chaos as settings


def run_seed(bundle, run, seed, steps, smoke, harnesses, glass_world_only=False):
    run.mkdir(mode=0o700)
    profile = run / "profile"
    launch = 0
    subprocess.run(["./scripts/go.sh", "run", "./tools/verification/native-interaction",
                    *(["-harnesses", ",".join(harnesses)] if harnesses else []), str(profile)], cwd=REPO, check=True)
    macos = bundle / "Contents/MacOS"
    log = (run / "app.log").open("w")
    app = None
    client = None
    trace = api.Trace(run / "settings.jsonl", command="settings-monkey", seed=seed)

    def start():
        nonlocal app, client, launch
        launch += 1
        # SIGTERM may leave its socket pathname behind. The production bridge
        # deliberately refuses to unlink occupied paths, so each new owner gets
        # a fresh endpoint while persistence stays in the same profile.
        endpoint = run / f"ui-{launch}.sock"
        app = subprocess.Popen([str(macos / "Mokusei"), "--data-dir", str(profile), "--automation-socket", str(endpoint)],
                               cwd=run, stdout=log, stderr=subprocess.STDOUT)
        trace.write({"kind": "launch", "pid": app.pid, "endpoint": str(endpoint), "launch": launch})
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if app.poll() is not None:
                raise RuntimeError(f"App exited before ready: {app.returncode}")
            try:
                client = api.Client(endpoint)
                if client.request()["pid"] == app.pid:
                    break
                client.close()
                client = None
            except (FileNotFoundError, ConnectionRefusedError):
                pass
            time.sleep(.1)
        if client is None:
            raise TimeoutError("Production app socket did not become ready")
        client.settle(lambda s: s["runtimeAvailable"] and len(s["threads"]) == 3, timeout=90)

    def stop():
        nonlocal client
        if client:
            client.close()
            client = None
        if app and app.poll() is None:
            app.send_signal(signal.SIGTERM)
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait(timeout=5)
        subprocess.run([str(macos / "mokusei-runtime"), "stop", "--data-dir", str(profile)], cwd=run, check=True, timeout=30)

    try:
        start()
        runtime = settings.Runtime(profile)
        if glass_world_only:
            driver = settings.Driver(client, trace, runtime, harnesses=harnesses)
            preferences_file = profile / "desktop-preferences.json"
            def runtime_settings():
                # Startup discovery can occupy Runtime admission capacity before
                # the independent read oracle connects. Retry only this read;
                # control actions and persistence assertions still fail normally.
                deadline = time.monotonic() + 45
                while True:
                    try:
                        return runtime.state()["settings"]
                    except AssertionError as error:
                        cause = error.__cause__
                        if not isinstance(cause, urllib.error.HTTPError) or cause.code != 503 or time.monotonic() >= deadline:
                            raise
                        trace.write({"kind": "runtime-read-retry", "error": str(error)})
                        time.sleep(.2)

            def verify_preferences(expected):
                state = driver.settle(lambda s: s["settings"]["glassWorld"] is expected)
                persisted = json.loads(preferences_file.read_text())["preferences"]
                assert persisted["glassWorld"] is expected, persisted
                trace.write({"kind": "glass-world-persisted", "launch": launch,
                             "snapshot": state["settings"], "preferences": persisted})

            driver.section("general")
            # The production workspace prefetch can legitimately initialize
            # native execution profiles. Finish those startup commands before
            # comparing Runtime settings across client-only preference edits.
            deadline = time.monotonic() + 90
            while True:
                started, completed = set(), set()
                for log_file in (profile / "runtime/debug-logs").glob("*.jsonl"):
                    for line in log_file.read_bytes().split(b"\n")[:-1]:
                        event = json.loads(line)
                        if event.get("channel") != "harness:settings-presentation":
                            continue
                        if event.get("evt") == "settings.command.started":
                            started.add(event["traceId"])
                        elif event.get("evt") == "settings.command.completed":
                            completed.add(event["traceId"])
                if started and started <= completed:
                    trace.write({"kind": "startup-discovery-settled", "commands": len(started)})
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"Startup settings discovery did not finish: {sorted(started - completed)}")
                time.sleep(.1)
            initial_runtime_settings = runtime_settings()
            trace.write({"kind": "runtime-settings-baseline", "settings": initial_runtime_settings})
            assert client.snapshot()["settings"]["glassWorld"] is True
            for enabled in (False, True, False):
                state = driver.control("general.glassWorld", "set", enabled)
                assert settings.controls(state)["general.glassWorld"]["label"] == "glass world"
                verify_preferences(enabled)
                for field, value in (("locale", "0"), ("appearance", "2"), ("locale", "1"), ("appearance", "1")):
                    driver.control("general." + field, "select", value)
                    verify_preferences(enabled)
            assert runtime_settings() == initial_runtime_settings, "Client preference changed Runtime settings"
            # Each restart owns a new app PID/socket and reloads the same private profile.
            for expected in (False, True):
                stop()
                start()
                driver = settings.Driver(client, trace, runtime, harnesses=harnesses)
                verify_preferences(expected)
                driver.section("general")
                state = driver.settle(lambda s: "general.glassWorld" in settings.controls(s))
                assert settings.controls(state)["general.glassWorld"]["value"] is expected
                trace.write({"kind": "glass-world-restart-verified", "launch": launch, "enabled": expected})
                if not expected:
                    driver.control("general.glassWorld", "set", True)
                    verify_preferences(True)
            print(f"PASS glass world real Toggle, JSON, language/appearance and off/on app+Runtime restart: {run}", flush=True)
            return
        # Settings presentation is the production initialization boundary. A
        # cancelled startup discovery must not leave model cases editing an
        # unconfigured local-only draft on later fresh-profile seeds.
        presentation = runtime.invoke("harness:settings-presentation", [{"scope": "global", "harnessId": "codex", "executionOwner": "moku"}])
        initialized = runtime.state()
        assert initialized["settings"]["moku"]["executionHarnesses"].get("codex"), presentation.get("executionSnapshotError", "Codex profile did not initialize")
        trace.write({"kind": "initialized", "revision": initialized["settingsRevision"], "harness": "codex"})
        driver = settings.Driver(client, trace, runtime, harnesses=harnesses)
        if smoke:
            settings.smoke(driver)
        settings.forms(driver)
        settings.monkey(driver, seed, steps)
        driver.saved()
        before = runtime.state()["settings"]
        preferences = {key: client.snapshot()["settings"][key] for key in ("appearance", "locale")}
        (run / "expected-settings.json").write_text(json.dumps(before, ensure_ascii=False, indent=2))
        stop()
        start()
        assert runtime.state()["settings"] == before, "Persisted settings changed across app/runtime restart"
        assert {key: client.snapshot()["settings"][key] for key in preferences} == preferences, "Preferences changed across restart"
        trace.write({"kind": "restart-verified", "preferences": preferences, "settings": before})
        print(f"PASS Settings seed={seed}, {steps} random controls + directed cases + restart: {run}", flush=True)
    except BaseException as error:
        trace.write({"kind": "failure", "error": str(error)})
        raise
    finally:
        stop()
        trace.close()
        log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Existing signed production Release bundle; otherwise build one")
    parser.add_argument("--steps", type=int, default=100)
    parser.add_argument("--seeds", type=int, nargs="+", default=[1, 42, 2026])
    parser.add_argument("--harnesses", nargs="+", choices=["codex", "claude", "pi", "opencode"],
                        help="Explicit Harness matrix for isolated profiles; default: all")
    parser.add_argument("--glass-world-only", action="store_true", help="Run only local glass world preferences and off/on restart assertions; no model edits")
    args = parser.parse_args()
    if args.harnesses and ("codex" not in args.harnesses or len(args.harnesses) < 2 or len(set(args.harnesses)) != len(args.harnesses)):
        parser.error("Harness matrix must include Codex and at least two distinct Harnesses for the CAS target-order case")
    if args.steps < 1:
        parser.error("steps must be positive")
    run = Path(tempfile.mkdtemp(prefix="mokusei-settings-chaos-", dir="/private/tmp"))
    print(f"Settings evidence: {run}", flush=True)
    if args.app:
        bundle = args.app.resolve()
    else:
        subprocess.run(["./scripts/go.sh", "run", "./cmd/mokusei-dev", "bundle", "--channel", "production", "--configuration", "release", "--output", str(run / "bundle")], cwd=REPO, check=True)
        bundle = run / "bundle/Mokusei.app"
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    provenance = json.loads((bundle / "Contents/Resources/build-provenance.json").read_text())
    assert info.get("CFBundleIdentifier") == "com.mokusei.desktop" and provenance.get("channel") == "production" and provenance.get("configuration") == "release"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    (run / "application.json").write_text(json.dumps({"app": str(bundle), "provenance": provenance, "harnesses": args.harnesses or ["codex", "claude", "pi", "opencode"]}, indent=2))
    for index, seed in enumerate(args.seeds):
        run_seed(bundle, run / f"seed-{index}-{seed}", seed, args.steps, smoke=index == 0, harnesses=args.harnesses, glass_world_only=args.glass_world_only)


if __name__ == "__main__":
    main()
