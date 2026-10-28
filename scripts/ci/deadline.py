"""Bound an owned command and terminate its process group if it hangs."""
import os
import signal
import subprocess
import sys


def run(command, *, timeout=1800, **kwargs):
    process = subprocess.Popen(command, start_new_session=True, **kwargs)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise TimeoutError(
            f"CI command exhausted its {timeout:.1f}s execution allowance. "
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
    raise SystemExit(run(sys.argv[1:]))
