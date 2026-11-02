"""Collect the latest 50 Actions runs with gh, or summarize retained metadata offline."""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import statistics
import subprocess

from timings import job_timing, timestamp


def gh(*arguments):
    return json.loads(subprocess.check_output(["gh", *arguments], text=True, timeout=60))


def collect(repository, count, run_ids):
    endpoint = f"repos/{repository}/actions/runs"
    # Fetch all workflows, including failed/skipped runs. Do not silently replace
    # failed samples with successful runs or hide another workflow's runner use.
    runs = ([gh("api", f"{endpoint}/{run_id}") for run_id in run_ids] if run_ids else
            gh("api", f"{endpoint}?per_page={count}")["workflow_runs"])

    def fetch(run):
        pages = gh("api", "--paginate", "--slurp", f"{endpoint}/{run['id']}/jobs?filter=all&per_page=100")
        return {"run": {key: run[key] for key in (
            "id", "name", "event", "head_sha", "head_branch", "status", "conclusion",
            "created_at", "run_started_at", "updated_at", "run_attempt", "html_url")},
            "jobs": [job for page in pages for job in page["jobs"]]}

    with ThreadPoolExecutor(max_workers=4) as pool:
        return list(pool.map(fetch, runs))


def summarize(samples):
    groups = defaultdict(list)
    runs = []
    for sample in samples:
        run = sample["run"]
        jobs = [timing for job in sample["jobs"] if (timing := job_timing(job))]
        names = {job["name"] for job in sample["jobs"]}
        documentation = any(step["name"] == "Confirm documentation-only validation" and step.get("conclusion") == "success"
                            for job in sample["jobs"] for step in job.get("steps", []))
        scope = ("documentation" if documentation else "extended" if "Extended native CLI coverage" in names
                 else "full" if "Complete coverage" in names else "other")
        # Only successful, completed runs enter speed comparisons. Failure and
        # cancellation durations remain in raw evidence and the outcome counts.
        current = [job for job in jobs if job["attempt"] == run["run_attempt"] and not job["reused"]]
        success = run["status"] == "completed" and run["conclusion"] == "success"
        for job in current:
            if success and job["conclusion"] == "success" and job["executionSeconds"] is not None:
                groups[run["name"], scope, job["name"]].append(job)
        completed = [timestamp(job["completed_at"]) for job in sample["jobs"]
                     if job.get("completed_at") and job.get("conclusion") != "skipped"]
        runs.append({**run, "verificationScope": scope, "jobs": jobs,
                     "elapsedSeconds": max(completed) - timestamp(run["created_at"])
                     if run["status"] == "completed" and completed else None,
                     "runnerSecondsThisAttempt": sum(job["executionSeconds"] for job in current)
                     if all(job["executionSeconds"] is not None for job in current) else None})
    aggregates = []
    for (workflow, scope, name), jobs in sorted(groups.items()):
        def stats(values):
            values = sorted(values)
            return {"median": statistics.median(values), "p90": values[math.ceil(len(values) * .9) - 1]}
        aggregates.append({"workflow": workflow, "verificationScope": scope, "job": name, "samples": len(jobs),
                           "queueSeconds": stats([j["queueSeconds"] for j in jobs]),
                           "executionSeconds": stats([j["executionSeconds"] for j in jobs]),
                           "stepSecondsMedian": {key: statistics.median(j["stepSeconds"][key] for j in jobs)
                                                 for key in jobs[0]["stepSeconds"]}})
    return {"collectedAt": datetime.now(timezone.utc).isoformat(),
            "outcomes": dict(Counter(f"{s['run']['name']}: {s['run']['conclusion'] or s['run']['status']}" for s in samples)),
            "aggregates": aggregates, "runs": runs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="hupao-creator/Mokusei")
    parser.add_argument("--count", type=int, default=50, choices=range(1, 101))
    parser.add_argument("--run", action="append", type=int, default=[])
    parser.add_argument("--input", type=Path, help="Previously collected raw.json; no network access")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    samples = json.loads(args.input.read_text()) if args.input else collect(args.repository, args.count, args.run)
    report = summarize(samples)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "raw.json").write_text(json.dumps(samples, indent=2) + "\n")
    (args.output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    rows = ["# Actions timing profile", "", f"Runs: {len(samples)}. Outcomes: {json.dumps(report['outcomes'])}", "",
            "Successful completed runs, latest attempt's newly executed jobs only. Seconds; nearest-rank p90.", "",
            "| Workflow / scope / job | n | Queue median / p90 | Runner median / p90 | Prepare | Build | Verification commands | Evidence |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for group in report["aggregates"]:
        queue, run, steps = group["queueSeconds"], group["executionSeconds"], group["stepSecondsMedian"]
        rows.append(f"| {group['workflow']} / {group['verificationScope']} / {group['job']} | {group['samples']} | {queue['median']} / {queue['p90']} | "
                    f"{run['median']} / {run['p90']} | {steps['preparation']} | {steps['build']} | "
                    f"{steps['verification']} | {steps['evidence']} |")
    rows += ["", "Preparation includes checkout, setup, cache and teardown. Verification commands can include compilation and fixture generation;",
             "these are observed step wall times, not pure test CPU time. Other and unattributed runner time remain in JSON.",
             "Job names can span workflow revisions; inspect source SHA and step inventory before treating samples as comparable.",
             "Failed/cancelled/in-progress runs and carried-forward jobs remain in JSON; they are not speedup evidence."]
    (args.output / "summary.md").write_text("\n".join(rows) + "\n")
    print("\n".join(rows))


if __name__ == "__main__":
    main()
