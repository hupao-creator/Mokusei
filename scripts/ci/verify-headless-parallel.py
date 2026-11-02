"""Exercise the real replay scheduler with isolated external fixture producers."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix="mokusei-parallel-control-") as temporary:
        root = Path(temporary)
        peer = root / "go-peer"
        peer.write_text("#!" + sys.executable + "\n" + r'''
import json, os, pathlib, time
root = pathlib.Path(os.environ["REPLAY_PEER_ROOT"])
pid = str(os.getpid())
(root / pid).write_text("running")
if os.environ.get("REPLAY_PEER_BLOCK"):
    time.sleep(60)
if not (root / "overlap").exists():
    expires = time.monotonic() + 5
    while len(list(root.glob("[0-9]*"))) < 2 and not (root / "overlap").exists():
        if time.monotonic() >= expires: raise SystemExit("No actual producer overlap")
        time.sleep(0.01)
    (root / "overlap").write_text("observed")
for name in ["MOKUSEI_INITIAL_RESPONSE_FIXTURES", "MOKU_STATUS_NATIVE_FIXTURE", "MOKU_TIMER_NATIVE_FIXTURE",
             "MOKUSEI_VOICE_EVENT_EXPORT", "MOKUSEI_CONVERSATION_CONTRACT_EXPORT", "MOKUSEI_HARNESS_FORM_FIXTURE"]:
    # Real producers each own distinct exports; the controlled peer records that
    # all required files exist without executing product code on Linux.
    path = pathlib.Path(os.environ[name])
    path.write_text("{}")
(root / pid).unlink()
raise SystemExit(7 if os.environ.get("REPLAY_PEER_FAIL") else 0)
''')
        peer.chmod(0o755)
        # These are output capabilities, not ordinary inputs. A controlled peer
        # must never export its temporary fixture paths into later hosted steps.
        environment = {key: value for key, value in os.environ.items()
                       if key not in {"GITHUB_ENV", "GITHUB_OUTPUT", "GITHUB_STATE", "GITHUB_PATH", "GITHUB_STEP_SUMMARY"}}
        environment.update(REPLAY_PEER_ROOT=str(root), GITHUB_ENV=str(root / "fixture-env"),
                           GITHUB_STEP_SUMMARY=str(root / "fixture-summary"))
        entry = [sys.executable, str(ROOT / "scripts/ci/replays.py"), "fixtures", "--go", str(peer)]
        output = root / "passed"
        subprocess.run(entry + ["--output", str(output)], env=environment, cwd=ROOT, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=20)
        report = json.loads((output / "report.json").read_text())
        assert report["jobs"] == 2 and len(report["checks"]) == 5
        assert all(check["status"] == "passed" and check["exit_code"] == 0 for check in report["checks"])
        assert (root / "overlap").exists()
        output = root / "failed"
        result = subprocess.run(entry + ["--output", str(output)], env=dict(environment, REPLAY_PEER_FAIL="1"),
                                cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
        report = json.loads((output / "report.json").read_text())
        assert result.returncode != 0 and all(check["status"] == "failed" and check["exit_code"] == 7
                                              for check in report["checks"])
        output = root / "cancelled"
        process = subprocess.Popen(entry + ["--output", str(output)], cwd=ROOT,
                                   env=dict(environment, REPLAY_PEER_BLOCK="1"),
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            expires = time.monotonic() + 10
            while len(list(root.glob("[0-9]*"))) < 2 and time.monotonic() < expires:
                time.sleep(0.02)
            pids = [int(path.name) for path in root.glob("[0-9]*")]
            assert len(pids) == 2
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=10)
            assert process.returncode != 0
            for pid in pids:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    continue
                raise AssertionError(f"Cancelled replay left a producer alive: {pid}")
            assert not all(check["status"] == "passed" for check in
                           json.loads((output / "report.json").read_text())["checks"])
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        result = subprocess.run([sys.executable, str(ROOT / "scripts/ci/replays.py"), "native", "--jobs", "2",
                                 "--output", str(root / "forbidden")], capture_output=True)
        assert result.returncode != 0 and not (root / "forbidden").exists()
    print("PASS real parallel replay overlap, all-result retention, nonzero propagation, cancellation cleanup and GUI admission")


if __name__ == "__main__":
    main()
