"""Prove a conservative documentation-only diff before scheduling full verification."""
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess


def main():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    kind = os.environ["GITHUB_EVENT_NAME"]
    base = head = None
    if kind == "pull_request":
        base = event["pull_request"]["base"]["sha"]
        head = event["pull_request"]["head"]["sha"]
    elif kind == "push" and event.get("before", "").strip("0"):
        base, head = event["before"], os.environ["GITHUB_SHA"]
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
