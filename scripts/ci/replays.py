"""Run existing production-boundary replays with retained, fail-closed evidence."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED

import deadline
from replay_plan import fixture_environment, replay_groups


def execute(record, root, output, environment, cancellation):
    record = dict(record)
    print("RUN", record["name"], flush=True)
    start = time.monotonic()
    try:
        with (output / record["log"]).open("w") as log:
            record["exit_code"] = deadline.run(record["command"], cwd=root, env=environment,
                                               cancel_event=cancellation, stdout=log, stderr=subprocess.STDOUT)
        record["status"] = "passed" if record["exit_code"] == 0 else "failed"
        text = (output / record["log"]).read_text(errors="replace")
        if re.search(r"Test Case '[^\n]+' skipped|[➜↷✘] Test [^\n]* skipped(?:[.:]| because)", text):
            record.update(status="failed", error="Replay skipped a required native test")
    except (OSError, TimeoutError, subprocess.TimeoutExpired) as error:
        record.update(status="failed", error=str(error))
    record["seconds"] = round(time.monotonic() - start, 3)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", choices=["runtime", "adapters", "fixtures", "interop", "native"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="append", help="Run only named checks (local evidence, not a complete CI group)")
    parser.add_argument("--go", default=os.environ.get("MOKUSEI_GO", "go"))
    parser.add_argument("--jobs", type=int, default=None, help="1 or 2 independent fixture producers; GUI groups remain serial")
    args = parser.parse_args()
    jobs = args.jobs if args.jobs is not None else (2 if args.group == "fixtures" else 1)
    if jobs not in (1, 2) or (jobs != 1 and args.group != "fixtures"):
        parser.error("Only independent fixture producers support --jobs 2; all other groups require --jobs 1")
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    environment = dict(os.environ, MOKUSEI_GO=args.go)
    fixtures = fixture_environment(output)
    groups = replay_groups(args.go, output)
    if args.group == "fixtures":
        environment.update(fixtures)
    checks = groups[args.group]
    if args.check:
        if len(args.check) != len(set(args.check)) or set(args.check) - {name for name, _ in checks}:
            parser.error("--check must name distinct checks in the selected group")
        checks = [(name, command) for name, command in checks if name in args.check]
    records = [{"name": name, "command": command, "status": "not_run", "log": name + ".log"}
               for name, command in checks]
    report = {"revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
              "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root)),
              "group": args.group, "jobs": jobs, "startedAt": time.time(), "checks": records}
    if args.check:
        report["selectedChecks"] = args.check

    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    # A killed workflow must leave pending/running evidence, never a false pass.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit("Replay runner terminated"))
    save()
    cancellation = threading.Event()
    pool = ThreadPoolExecutor(max_workers=jobs)
    pending = {}
    next_index = 0
    completed = []
    try:
        while next_index < len(records) or pending:
            while next_index < len(records) and len(pending) < jobs:
                record = records[next_index]
                record["status"] = "running"
                pending[pool.submit(execute, record, root, output, environment, cancellation)] = next_index
                next_index += 1
                save()
            done, _ = wait(pending, return_when=FIRST_COMPLETED)
            for future in done:
                index = pending.pop(future)
                records[index] = future.result()
                completed.append(records[index])
                print(records[index]["status"].upper(), records[index]["name"], flush=True)
                save()
    finally:
        # Worker commands own separate process groups. Unwind every one before
        # releasing the parent/CI lease; a cancelled producer cannot outlive it.
        cancellation.set()
        pool.shutdown(wait=True, cancel_futures=True)
        report["finishedAt"] = time.time()
        report["wallSeconds"] = round(report["finishedAt"] - report["startedAt"], 3)
        save()
    for record in completed:
        if record["status"] != "passed":
            path = output / record["log"]
            # The log can exist but be empty when its execution limit kills a
            # newly started command. Always expose the runner's failure separately.
            message = f"{record['name']}: exit={record.get('exit_code')}, seconds={record['seconds']}, error={record.get('error', 'command failed')}"
            print(message, flush=True)
            print(path.read_text(errors="replace")[-12000:] if path.exists() else "No command log")
            if "GITHUB_STEP_SUMMARY" in os.environ:
                with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                    summary.write(f"\n### Replay failure: {record['name']}\n\n{message}\n\nLog: `{path}`\n")

    if any(record["status"] != "passed" for record in records):
        raise SystemExit(1)
    if args.group == "fixtures":
        for name, path in fixtures.items():
            if not Path(path).is_file() or not Path(path).stat().st_size:
                report.setdefault("errors", []).append("Fixture producer did not export " + name)
                save()
                raise SystemExit("Fixture producer did not export " + name)
        if "GITHUB_ENV" in os.environ:
            with open(os.environ["GITHUB_ENV"], "a") as stream:
                stream.writelines(f"{name}={path}\n" for name, path in fixtures.items())


if __name__ == "__main__":
    main()
