#!/usr/bin/env python3
"""Read private tool metadata; bodies require --invocation and --details together."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Profile runtime/tool-calls directory")
    parser.add_argument("--agent", choices=("moku", "tag", "report"))
    parser.add_argument("--tool")
    parser.add_argument("--execution")
    parser.add_argument("--invocation")
    parser.add_argument("--details", action="store_true", help="Include retained bodies for --invocation only")
    args = parser.parse_args()
    if args.details and not args.invocation:
        parser.error("--details requires --invocation to avoid bulk body disclosure")
    if not args.directory.is_dir():
        parser.error("journal directory does not exist")

    calls = {}
    malformed = 0
    files = sorted(args.directory.glob("tools-????-??-??-????.jsonl"))
    for path in files:
        # Read-only: a concurrent append may expose an incomplete tail. An
        # incomplete/rotated snapshot cannot establish a final execution outcome.
        try:
            if not re.fullmatch(r"tools-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}\.jsonl", path.name):
                malformed += 1
                continue
            # Do not follow replaced segments or block on a non-regular file.
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    malformed += 1
                    continue
                for line in stream:
                    try:
                        event = json.loads(line.decode("utf-8"))
                    except (ValueError, UnicodeError):
                        malformed += 1
                        continue
                    if not isinstance(event, dict) or event.get("version") != 1:
                        malformed += 1
                        continue
                    if (event.get("event") not in ("tool.started", "tool.finished")
                            or not isinstance(event.get("invocationId"), str) or not event["invocationId"]
                            or not isinstance(event.get("startedAt"), str)
                            or any(key in event and not isinstance(event[key], dict) for key in ("input", "output", "error"))):
                        malformed += 1
                        continue
                    if any((wanted and event.get(field) != wanted) for field, wanted in (
                        ("agent", args.agent), ("tool", args.tool),
                        ("executionId", args.execution), ("invocationId", args.invocation),
                    )):
                        continue
                    kind = "start" if event["event"] == "tool.started" else "finish"
                    call = calls.setdefault(event["invocationId"], {})
                    if args.details:
                        call[kind] = event
                        continue
                    # Bodies and error text never enter the default summary.
                    summary = {k: v for k, v in event.items() if k not in ("input", "output", "error")}
                    for payload in ("input", "output", "error"):
                        if payload in event:
                            summary[payload] = {k: v for k, v in event[payload].items() if k not in ("json", "jsonPrefix", "structure")}
                    call[kind] = summary
        except FileNotFoundError:
            # Retention can remove a segment after enumeration.
            malformed += 1
        except (OSError, UnicodeError) as error:
            print(f"Cannot read journal segment: {type(error).__name__}", file=sys.stderr)
            return 1

    for invocation, pair in sorted(calls.items(), key=lambda item: (
        item[1].get("start", item[1].get("finish", {})).get("startedAt", ""), item[0]
    )):
        state = "finished" if "finish" in pair and "start" in pair else (
            "finish_without_start" if "finish" in pair else "incomplete_outcome_unknown"
        )
        print(json.dumps({"invocationId": invocation, "recordState": state, **pair}, ensure_ascii=False))
    print(json.dumps({"segmentsRead": len(files), "callsMatched": len(calls),
                      "malformedOrVanished": malformed, "snapshot": "read-only-best-effort",
                      "coverage": "retained-injected-callbacks-only"}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
