"""Require a successful local macOS signoff on the exact Actions checkout."""
import argparse
import os
from pathlib import Path
import subprocess

from macos_signoff import commit_sha, context_for, gh_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["native", "extended", "overview"])
    args = parser.parse_args()
    sha = commit_sha(os.environ["GITHUB_SHA"])
    repository = os.environ["GITHUB_REPOSITORY"]
    context = context_for(args.mode, os.environ.get("BASELINE_SHA"), os.environ.get("CANDIDATE_SHA"))
    command = f"python3 scripts/ci/local-macos.py {args.mode} --commit {sha} --reviewed"
    if args.mode == "overview":
        command += f" --baseline {commit_sha(os.environ['BASELINE_SHA'])} --candidate {commit_sha(os.environ['CANDIDATE_SHA'])}"
    message = (f"Required local status: {context} on {sha}\n"
               f"After reviewing the code, check out this exact commit on your Mac and run:\n{command}\n"
               "Then rerun only this workflow's failed jobs. Missing, pending, failure and error do not pass.\n")
    print(message, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
            summary.write("\n### Local macOS verification\n\n```text\n" + message + "```\n")
    # The statuses endpoint is newest-first. Never accept an older green status
    # after a newer pending/failing attempt, or a status from a different SHA.
    for page in range(1, 101):
        statuses = gh_json(f"repos/{repository}/commits/{sha}/statuses?per_page=100&page={page}")
        for status in statuses:
            if status["context"] == context:
                print(f"Latest {context}: {status['state']} ({status.get('target_url') or 'local evidence'})")
                if status["state"] != "success":
                    raise SystemExit(1)
                return
        if len(statuses) < 100:
            break
    raise SystemExit("No successful local signoff exists for this checkout and verification mode")


if __name__ == "__main__":
    main()
