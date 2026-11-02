"""Expose runner queues and total retry latency without imposing a whole-run time gate."""
import json
import os
from pathlib import Path
import subprocess
import time

from timings import job_timing, timestamp


def main():
    endpoint = f"repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    run = json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))
    attempt = int(os.environ["GITHUB_RUN_ATTEMPT"])
    pages = json.loads(subprocess.check_output([
        "gh", "api", "--paginate", "--slurp", f"{endpoint}/attempts/{attempt}/jobs?per_page=100"], text=True))
    jobs = []
    for page in pages:
        for job in page["jobs"]:
            timing = job_timing(job)
            if timing:
                jobs.append(timing)
    now = time.time()
    report = {"run": run["id"], "attempt": attempt,
              "elapsedSinceFirstTriggerSeconds": round(now - timestamp(run["created_at"]), 1),
              "elapsedThisAttemptSeconds": round(now - timestamp(run["run_started_at"]), 1),
              "jobs": jobs}
    Path(os.environ["RUNNER_TEMP"], "run-summary.json").write_text(json.dumps(report, indent=2) + "\n")
    rows = ["## Queue and retry latency", "",
            f"Attempt **{attempt}**; since first trigger: **{report['elapsedSinceFirstTriggerSeconds']}s**; "
            f"this attempt: **{report['elapsedThisAttemptSeconds']}s** (measured before cleanup).",
            "", "| Job | Queue seconds | Execution seconds | Preparation | Build | Verification commands | Result |",
            "| --- | ---: | ---: | ---: | ---: | ---: | --- |"]
    for job in jobs:
        queue = "prior execution" if job["reused"] else job["queueSeconds"]
        steps = job["stepSeconds"]
        rows.append(f"| {job['name']} | {queue} | {job['executionSeconds']} | {steps['preparation']} | "
                    f"{steps['build']} | {steps['verification']} | {job['conclusion'] or 'running'} |")
    rows += ["", "Reused jobs are not new runner work. Elapsed time is diagnostic and does not decide merge eligibility."]
    text = "\n".join(rows) + "\n"
    print(text)
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(text)


if __name__ == "__main__":
    main()
