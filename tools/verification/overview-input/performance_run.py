"""Read-only host inventory retained for historical performance analysis checks.

The glass on/off launcher is retired; current Overview cards have no material toggle.
"""
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
