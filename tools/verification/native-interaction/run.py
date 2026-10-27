"""Launch this checkout's real app and daemon; exercise only semantic UI actions."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import socket
import subprocess
import tempfile
import time


REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("interaction_client", REPO / "tools/native-interaction/client.py")
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)


def protocol_checks(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        with connection.makefile("rb") as reader:
            for raw in (b"no json", b"{}", b'{"protocol":2,"id":"bad","op":"snapshot"}',
                        b'{"protocol":1,"id":"extra","op":"snapshot","extra":true}'):
                connection.sendall(raw + b"\n")
                reply = json.loads(reader.readline())
                assert not reply["ok"] and reply["error"]["code"] == "invalid_request", reply
            # Split frames and pipelining exercise actual stream framing/order.
            request = b'{"protocol":1,"id":"split","op":"snapshot"}\n'
            connection.sendall(request[:12])
            connection.sendall(request[12:] + request.replace(b"split", b"next"))
            assert json.loads(reader.readline())["id"] == "split"
            assert json.loads(reader.readline())["id"] == "next"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        connection.sendall(b"x" * (64 * 1024 + 1))
        assert connection.recv(1) == b""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Existing signed production Release bundle; otherwise build one")
    parser.add_argument("--steps", type=int, default=100, help="Chaos actions per seed (three seeds)")
    args = parser.parse_args()
    if args.steps < 1:
        parser.error("steps must be positive")
    run = Path(tempfile.mkdtemp(prefix="oa-ui-", dir="/private/tmp"))
    print(f"Interaction evidence: {run}", flush=True)
    if args.app:
        bundle = args.app.resolve()
    else:
        subprocess.run(["./scripts/go.sh", "run", "./cmd/mokusei-dev", "bundle",
                        "--channel", "production", "--configuration", "release", "--output", str(run / "bundle")],
                       cwd=REPO, check=True)
        bundle = run / "bundle/Mokusei.app"
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    provenance = json.loads((bundle / "Contents/Resources/build-provenance.json").read_text())
    if info.get("CFBundleIdentifier") != "com.mokusei.desktop" or provenance.get("channel") != "production" or provenance.get("configuration") != "release":
        raise ValueError("Replay requires the signed production Release app")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    (run / "application.json").write_text(json.dumps({"app": str(bundle), "provenance": provenance}, indent=2))
    print(f"Production app: {bundle}", flush=True)
    profile = run / "profile"
    subprocess.run(["./scripts/go.sh", "run", "./tools/verification/native-interaction", str(profile)], cwd=REPO, check=True)
    macos = bundle / "Contents/MacOS"
    # Launch the unchanged production bundle with normal runtime/environment
    # discovery. Only the data directory is isolated; the runner owns this PID.
    env = os.environ.copy()
    endpoint = run / "ui.sock"
    log = (run / "app.log").open("w")
    app = subprocess.Popen([str(macos / "Mokusei"), "--data-dir", str(profile), "--automation-socket", str(endpoint)],
                           cwd=run, env=env, stdout=log, stderr=subprocess.STDOUT)
    client = None
    trace = None
    try:
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if app.poll() is not None:
                raise RuntimeError(f"App exited before ready: {app.returncode}")
            try:
                client = api.Client(endpoint)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.1)
        if client is None:
            raise TimeoutError("Automation socket never became ready")
        assert client.request()["pid"] == app.pid
        initial = client.settle(lambda state: state["runtimeAvailable"] and len(state["threads"]) == 3, timeout=45)
        assert endpoint.stat().st_mode & 0o777 == 0o600
        protocol_checks(endpoint)
        trace = api.Trace(run / "smoke.jsonl", command="smoke")
        api.step(client, trace, {}, expected_error="invalid_request")
        api.step(client, trace, {"name": "settings.close"}, expected_error="unavailable")
        api.step(client, trace, {"name": "settings.open", "unexpected": True}, expected_error="invalid_request")
        api.step(client, trace, {"name": "settings.open"})
        api.step(client, trace, {"name": "settings.select", "section": "missing"}, expected_error="not_found")
        api.step(client, trace, {"name": "search.begin"}, expected_error="unavailable")
        assert "archived" not in initial["settingsSections"] and "plugins" not in initial["settingsSections"]
        for removed in ("archived", "plugins"):
            api.step(client, trace, {"name": "settings.select", "section": removed}, expected_error="not_found")
        for section in initial["settingsSections"]:
            api.step(client, trace, {"name": "settings.select", "section": section})
        api.step(client, trace, {"name": "navigation.back"})
        for ref in initial["threads"]:
            api.step(client, trace, {"name": "thread.open", **ref})
            api.step(client, trace, {"name": "settings.open"})
            restored = api.step(client, trace, {"name": "settings.close"})
            assert restored["selectedThread"] == ref
            api.step(client, trace, {"name": "navigation.back"})
            client.settle(lambda state: state["page"] == "overview")
        api.step(client, trace, {"name": "thread.open", "threadId": "missing", "typeId": "agent"}, expected_error="not_found")
        api.step(client, trace, {"name": "search.begin"})
        api.step(client, trace, {"name": "search.update", "query": "不存在"})
        assert client.snapshot()["threads"] == []
        api.step(client, trace, {"name": "search.end"})
        for item in initial["filters"]:
            api.step(client, trace, {"name": "filter.select", "filterId": item["id"]})
        api.step(client, trace, {"name": "filter.select", "filterId": None})
        api.step(client, trace, {"name": "filter.select", "filterId": "missing"}, expected_error="not_found")
        # Regression: a page retained beneath Settings must not clear the next
        # reading visit's back action when its delayed disappearance is delivered.
        for ref in initial["threads"] * 2:
            api.step(client, trace, {"name": "thread.open", **ref})
            api.step(client, trace, {"name": "settings.open"}, wait=False)
            api.step(client, trace, {"name": "overview.show"})
            api.step(client, trace, {"name": "thread.open", **ref})
            api.step(client, trace, {"name": "overview.show"})
        trace.close()
        trace = api.Trace(run / "smoke-replayed.jsonl", command="replay")
        api.replay(client, trace, run / "smoke.jsonl")
        trace.close()
        for seed in (1, 42, 2026):
            trace = api.Trace(run / f"monkey-{seed}.jsonl", command="monkey", seed=seed)
            api.monkey(client, trace, seed, args.steps, timeout=max(120, args.steps * 2))
            trace.close()
        print(f"PASS production Release app navigation, protocol boundaries, trace replay and {args.steps * 3} chaos actions: {run}", flush=True)
    finally:
        if trace:
            trace.close()
        if client:
            client.close()
        if app.poll() is None:
            app.send_signal(signal.SIGTERM)
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait(timeout=5)
        log.close()
        subprocess.run([str(macos / "mokusei-runtime"), "stop", "--data-dir", str(profile)],
                       cwd=run, env=env, check=True, timeout=30)


if __name__ == "__main__":
    main()
