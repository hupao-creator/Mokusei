"""Expose runner queues and total retry latency without resetting the CI budget."""
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import time


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def main():
    endpoint = f"repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    run = json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))
    attempt = int(os.environ["GITHUB_RUN_ATTEMPT"])
    pages = json.loads(subprocess.check_output([
        "gh", "api", "--paginate", "--slurp", f"{endpoint}/attempts/{attempt}/jobs?per_page=100"], text=True))
    jobs = []
    for page in pages:
        for job in page["jobs"]:
            if job["conclusion"] == "skipped" or not job["started_at"]:
                continue
            started, created = timestamp(job["started_at"]), timestamp(job["created_at"])
            # GitHub creates new job IDs for carried-forward successful jobs on a
            # partial rerun, but keeps their earlier start/completion timestamps.
            carried = started < created
            jobs.append({"name": job["name"], "conclusion": job["conclusion"],
                         "reused": carried, "queueSeconds": None if carried else round(started - created, 1),
                         "executionSeconds": round(timestamp(job["completed_at"]) - started, 1)
                         if job["completed_at"] else None})
    now = time.time()
    report = {"run": run["id"], "attempt": attempt,
              "elapsedSinceFirstTriggerSeconds": round(now - timestamp(run["created_at"]), 1),
              "elapsedThisAttemptSeconds": round(now - int(os.environ["MOKUSEI_CI_STARTED_AT"]), 1),
              "jobs": jobs}
    Path(os.environ["RUNNER_TEMP"], "run-summary.json").write_text(json.dumps(report, indent=2) + "\n")
    rows = ["## Queue and retry latency", "",
            f"Attempt **{attempt}**; since first trigger: **{report['elapsedSinceFirstTriggerSeconds']}s**; "
            f"this attempt: **{report['elapsedThisAttemptSeconds']}s** (measured before cleanup).",
            "", "| Job | Queue seconds | Execution seconds | Result |", "| --- | ---: | ---: | --- |"]
    for job in jobs:
        queue = "prior execution" if job["reused"] else job["queueSeconds"]
        rows.append(f"| {job['name']} | {queue} | {job['executionSeconds']} | {job['conclusion'] or 'running'} |")
    rows += ["", "Reused jobs are not new runner work. The strict whole-attempt budget still includes queueing."]
    text = "\n".join(rows) + "\n"
    print(text)
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(text)


if __name__ == "__main__":
    main()
