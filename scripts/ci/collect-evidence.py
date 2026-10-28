"""Select the newest artifact per native slot without discarding retry history."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil


def latest(entries):
    selected, errors = {}, []
    for slot in ["preparation", "build", *[f"swift-{i}" for i in range(5)]]:
        pattern = re.compile(r"macos-" + re.escape(slot) + r"-evidence-attempt-([1-9][0-9]*)")
        candidates = [(int(match[1]), entry) for entry in entries
                      if (match := pattern.fullmatch(entry["name"]))]
        if not candidates:
            errors.append(f"No evidence for {slot}")
            continue
        attempt = max(number for number, _ in candidates)
        newest = [entry for number, entry in candidates if number == attempt]
        if len(newest) != 1 or newest[0].get("expired", False):
            errors.append(f"Latest evidence for {slot} is ambiguous or expired")
            continue
        selected[slot] = (attempt, newest[0])
    return selected, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", action="store_true", help="Select artifact IDs from paginated API metadata before downloading")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path, nargs="?")
    args = parser.parse_args()
    if args.plan:
        pages = json.loads(args.source.read_text())
        entries = [entry for page in pages for entry in page["artifacts"]]
    else:
        if args.destination is None:
            parser.error("destination is required when collecting downloaded evidence")
        args.destination.mkdir(parents=True, exist_ok=False)
        entries = [{"name": path.name, "path": path} for path in args.source.iterdir() if path.is_dir()]
    selected, errors = latest(entries)
    # Select by execution attempt, never by passing status. A newer failed or
    # incomplete receipt must reach the auditor instead of an older green one.
    results = json.loads(os.environ["JOB_RESULTS"])
    for name in ("native-go", "swift-build", "mac"):
        if results[name]["result"] != "success":
            errors.append(f"{name} did not succeed; older artifacts cannot certify this attempt")
    report = {"selectedAttempts": {slot: attempt for slot, (attempt, _) in selected.items()}, "errors": errors}
    if args.plan:
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("artifact_ids=" + ",".join(str(entry["id"]) for _, entry in selected.values()) + "\n")
    else:
        for slot, (_, entry) in selected.items():
            shutil.copytree(entry["path"], args.destination / slot)
        (args.destination / "selection.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write("\n## Native evidence selection\n\n| Slot | Execution attempt |\n| --- | ---: |\n")
        summary.writelines(f"| {slot} | {attempt} |\n" for slot, (attempt, _) in selected.items())
        summary.writelines(f"\n- {error}\n" for error in errors)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
