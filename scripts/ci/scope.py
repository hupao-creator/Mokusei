"""Reject obsolete queued work and prove a conservative documentation-only diff."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--current", action="store_true", help="Reject superseded PR/main revisions before native scheduling")
    args = parser.parse_args()
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    kind = os.environ["GITHUB_EVENT_NAME"]
    base = head = None
    if kind == "pull_request":
        base = event["pull_request"]["base"]["sha"]
        head = event["pull_request"]["head"]["sha"]
    elif kind == "push" and event.get("before", "").strip("0"):
        base, head = event["before"], os.environ["GITHUB_SHA"]
    if args.current and kind in {"pull_request", "push"}:
        repository = os.environ["GITHUB_REPOSITORY"]
        if kind == "pull_request":
            current = json.loads(subprocess.check_output([
                "gh", "api", f"repos/{repository}/pulls/{event['number']}"], text=True))
            obsolete = (current["state"] != "open" or current["head"]["sha"] != head
                        or current["base"]["sha"] != base)
        else:
            current = json.loads(subprocess.check_output([
                "gh", "api", f"repos/{repository}/git/ref/heads/main"], text=True))
            obsolete = current["object"]["sha"] != os.environ["GITHUB_SHA"]
        if obsolete:
            message = "Superseded queued revision: use the latest PR head/base or main commit; no native verification started."
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                summary.write(message + "\n")
            raise SystemExit(message)
    paths = []
    if base and head and all(re.fullmatch(r"[0-9a-f]{40}", ref) for ref in (base, head)):
        # Disable rename detection: both the old and new path must be documentation.
        paths = subprocess.check_output(
            ["git", "diff", "--name-only", "--no-renames", "-z", base, head], text=True).split("\0")[:-1]
        subprocess.run(["git", "diff", "--check", base, head], check=True)
    docs_only = bool(paths)
    for name in paths:
        path = PurePosixPath(name)
        # README files inside a packaged Resources tree can be runtime inputs.
        # Keep the fast path limited to explicit documentation entry points.
        allowed = (name in {"AGENTS.md", "README.md", "CONTEXT.md", "internal/README.md",
                           "app/macos/README.md", "tools/verification/README.md", "demos/README.md"}
                   or (path.suffix == ".md" and path.parent.as_posix() in {".agents", "scripts/ci"}))
        # A renamed executable, symlink, embedded prompt or unknown file needs full CI.
        modes = [subprocess.check_output(["git", "ls-tree", ref, "--", name], text=True)
                 for ref in (base, head)]
        if not allowed or any(mode and not mode.startswith("100644 ") for mode in modes):
            docs_only = False
    result = {"documentation_only": docs_only, "base": base, "head": head, "paths": paths}
    print(json.dumps(result, indent=2))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"documentation_only={str(docs_only).lower()}\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write("## Verification scope\n\n" + (
            "Documentation-only diff: whitespace validation; native/build tests are not required for this scope.\n"
            if docs_only else "Complete verification required.\n"))
        summary.write(f"\nCompared `{base}` to `{head}`; {len(paths)} changed paths.\n")


if __name__ == "__main__":
    main()
