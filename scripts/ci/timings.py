"""Separate observed runner/step time; never infer test CPU time from a job."""
from datetime import datetime
import re


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def job_timing(job):
    if job.get("conclusion") == "skipped" or not job.get("started_at"):
        return None
    started = timestamp(job["started_at"])
    created = timestamp(job["created_at"])
    reused = started < created
    execution = (timestamp(job["completed_at"]) - started) if job.get("completed_at") else None
    buckets = dict(preparation=0, build=0, verification=0, evidence=0, other=0)
    steps = []
    for step in job.get("steps", []):
        if step.get("conclusion") == "skipped" or not all(step.get(key) for key in ("started_at", "completed_at")):
            continue
        seconds = timestamp(step["completed_at"]) - timestamp(step["started_at"])
        if seconds < 0:
            continue
        name = step["name"]
        if re.search(r"upload-artifact|Retain |Collect |Summarize |Enforce |Report queueing", name, re.I):
            category = "evidence"
        elif re.search(r"Set up job|Complete job|checkout@|setup-|cache|toolchain|Prepare |graphical session", name, re.I):
            category = "preparation"
        elif re.search(r"Build current Swift|Go build", name):
            category = "build"
        elif re.search(r"tests?|suite|replays?|projections|fixtures|Go vet|formatting|boundaries", name, re.I):
            category = "verification"
        else:
            category = "other"
        buckets[category] += seconds
        steps.append({"name": name, "category": category, "seconds": seconds,
                      "conclusion": step.get("conclusion")})
    return {"name": job["name"], "id": job["id"], "attempt": job.get("run_attempt"),
            "conclusion": job.get("conclusion"), "reused": reused,
            "queueSeconds": None if reused else round(started - created, 1),
            "executionSeconds": execution, "stepSeconds": buckets, "steps": steps,
            "unattributedSeconds": None if execution is None else round(execution - sum(buckets.values()), 1)}
