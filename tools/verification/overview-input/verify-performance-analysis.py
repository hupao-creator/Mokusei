"""Exercise the real analyzer against retained measurements and corrupted copies."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

from performance_run import host_snapshot
from performance_support import interfering_process


def main():
    source = Path(__file__).resolve().parent
    archive = source.parent / "overview-performance/evidence/glass-run-3/raw.tar.gz"
    with tempfile.TemporaryDirectory(prefix="overview-analysis-") as temporary:
        root = Path(temporary)
        with tarfile.open(archive) as data:
            data.extractall(root, filter="data")
        (root / "run-status.json").write_text('{"phase":"collected"}')

        def run():
            (root / "summary.json").unlink(missing_ok=True)
            result = subprocess.run([sys.executable, str(source / "analyze-performance.py"), str(root)], capture_output=True, text=True)
            assert result.returncode != 0, "Invalid evidence was accepted by the production CLI"
            summary = root / "summary.json"
            return json.loads(summary.read_text()) if summary.exists() else None

        result = run()
        assert result["complete"] and not result["comparisonValid"]
        assert sum(not row["valid"] for row in result["rows"]) == 26
        assert [group["validPairs"] for group in result["groups"]] == [1, 1, 1, 0]

        last = root / "r4-light-static-on.json"
        saved = last.read_bytes(); last.unlink()
        result = run()
        assert not result["complete"] and last.stem in result["missingConditions"]
        last.write_bytes(saved)

        value = json.loads(saved); value["name"] = "r1-light-static-on"
        last.write_text(json.dumps(value))
        assert run() is None
        last.write_bytes(saved)

        first = root / "r1-light-static-on.json"
        saved_first = first.read_bytes(); value = json.loads(saved_first)
        value["deliveredActions"] = 1
        first.write_text(json.dumps(value)); result = run()
        row = next(row for row in result["rows"] if row["name"] == first.stem)
        assert "incomplete-or-different-workload" in row["invalidReasons"]
        first.write_bytes(saved_first)

        value = json.loads(saved_first)
        value["resources"][0]["unix"] = json.loads(saved)["resources"][-1]["unix"] + 1
        first.write_text(json.dumps(value)); result = run()
        assert "condition-order-mismatch" in result["protocolErrors"]

        metadata_file = root / "metadata.json"
        metadata = json.loads(metadata_file.read_text()); metadata["schema"] = 2
        metadata_file.write_text(json.dumps(metadata))
        (root / "run-status.json").write_text('{"phase":"launched","error":"retained native failure"}')
        (root / "result.txt").write_text("FAIL retained native failure\n")
        result = run()
        assert {"driver-did-not-complete", "native-replay-did-not-pass"} <= set(result["protocolErrors"])

        # Exercise the actual ps/filter path with a harmless, sleeping process.
        # It has a replay identity but no GUI or significant CPU consumption.
        sleeper = root / "OverviewInputReplay"
        shutil.copy("/bin/sleep", sleeper)
        process = subprocess.Popen([str(sleeper), "30"])
        try:
            time.sleep(.25)
            snapshot = host_snapshot()
            assert not snapshot["error"], snapshot["error"]
            row = next(row for row in snapshot["processes"] if row["pid"] == process.pid)
            assert row["cpu"] < 5 and interfering_process(row, 0), row
        finally:
            process.terminate(); process.wait(timeout=5)

    for name in ["ReadingPresenta", "OverviewInputRe", "MokuseiNativePa", "swift-frontend"]:
        assert interfering_process({"pid": 2, "cpu": 25, "name": name}, 1)
        assert not interfering_process({"pid": 2, "cpu": 25, "name": name}, 2)
    print("PASS retained trial, incomplete/duplicate/workload/order/native failure rejection, low-CPU replay detection and own-PID exclusion")


if __name__ == "__main__":
    main()
