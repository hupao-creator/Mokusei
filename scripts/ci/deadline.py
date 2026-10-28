"""Bound owned CI subprocesses, reserving cleanup time inside the fifteen-minute run."""
import os
from datetime import datetime
from pathlib import Path
import signal
import subprocess
import sys
import time


def remaining(maximum=900):
    started = os.environ.get("MOKUSEI_CI_STARTED_AT")
    if started is None:
        return maximum
    seconds = min(maximum, 840 - (time.time() - int(started)))
    if seconds <= 0:
        raise TimeoutError("CI execution budget exhausted; no further command started")
    return seconds


def run(command, *, timeout=900, **kwargs):
    seconds = remaining(timeout)
    process = subprocess.Popen(command, start_new_session=True, **kwargs)
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired as error:
        limit = ("the shared 840s execution deadline includes runner queueing and setup"
                 if os.environ.get("MOKUSEI_CI_STARTED_AT") else "the command's execution limit was reached")
        raise TimeoutError(
            f"CI command exhausted its {seconds:.1f}s allowance; "
            f"{limit}. "
            "This is incomplete execution, not a test assertion failure.") from error
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit("CI command terminated"))
    if sys.argv[1:] == ["stamp"]:
        endpoint = f"repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}/attempts/{os.environ['GITHUB_RUN_ATTEMPT']}"
        value = subprocess.check_output(["gh", "api", endpoint, "--jq", ".run_started_at"], text=True).strip()
        started = int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
        with Path(os.environ["GITHUB_ENV"]).open("a") as stream:
            stream.write(f"MOKUSEI_CI_STARTED_AT={started}\n")
        print("CI attempt started:", value)
        raise SystemExit(0)
    raise SystemExit(run(sys.argv[1:]))
