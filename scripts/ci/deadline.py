"""Bound an owned command and terminate its process group if it hangs."""
import os
import signal
import subprocess
import sys
import time


def run(command, *, timeout=1800, termination_grace=5, cancel_event=None, **kwargs):
    process = subprocess.Popen(command, start_new_session=True, **kwargs)
    try:
        if cancel_event is None:
            return process.wait(timeout=timeout)
        expires = time.monotonic() + timeout
        while True:
            if cancel_event.is_set():
                raise InterruptedError("CI command cancelled by its owner")
            remaining = expires - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, timeout)
            try:
                return process.wait(timeout=min(0.2, remaining))
            except subprocess.TimeoutExpired:
                continue
    except subprocess.TimeoutExpired as error:
        raise TimeoutError(
            f"CI command exhausted its {timeout:.1f}s execution allowance. "
            "This is incomplete execution, not a test assertion failure.") from error
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=termination_grace)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit("CI command terminated"))
    raise SystemExit(run(sys.argv[1:]))
