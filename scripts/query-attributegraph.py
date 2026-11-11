#!/usr/bin/env python3
"""Read one native layout session's AttributeGraph evidence; never contact the app."""

import argparse
import collections
import datetime
import json
import pathlib
import re
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=pathlib.Path, help="layout-<pid>-<uuid> directory")
    parser.add_argument("--json", action="store_true", help="emit individual warning/boundary evidence")
    parser.add_argument("--stacks", action="store_true", help="show boundary caller stacks (not cycle stacks)")
    args = parser.parse_args()
    files = sorted(
        (p for p in args.session.glob("incidents-*.jsonl") if re.fullmatch(r"incidents-\d+\.jsonl", p.name)),
        key=lambda p: int(p.stem.split("-")[-1]),
    )
    if not files:
        parser.error("no incident journal; this session may predate AttributeGraph capture")
    records, headers, problems = [], [], []
    final_closed = False
    for path in files:
        final_closed = False
        with path.open() as source:
            for number, line in enumerate(source, 1):
                try:
                    record = json.loads(line)
                    if not isinstance(record, dict):
                        raise ValueError("record is not an object")
                except ValueError:
                    problems.append(f"unreadable record: {path.name}:{number}")
                    continue
                if record.get("kind") == "session":
                    headers.append(record)
                elif record.get("kind") == "sessionEnd":
                    final_closed = True
                else:
                    records.append(record)
    if not headers or any(not isinstance(h.get("session"), str) or not isinstance(h.get("pid"), int)
                          for h in headers):
        parser.error("missing or invalid session identity")
    if len({(h["session"], h["pid"]) for h in headers}) != 1:
        parser.error("missing session header or mixed sessions; byte offsets cannot be joined")
    if any(h.get("schema") != 1 for h in headers):
        parser.error("unsupported incident schema")
    operations = [r for r in records if r.get("kind") == "operation"]
    cycles = [r for r in records if r.get("kind") == "cycle"]
    gaps = [r for r in records if r.get("kind") in ("dataLoss", "captureGap")]
    statuses = [r for r in records if r.get("kind") == "captureStatus"]
    if not any(r.get("status") == "watching-stderr" for r in statuses):
        problems.append("stderr capture was not observed starting; zero retained warnings is not proof of absence")
    if not final_closed:
        problems.append("active or incomplete session; diagnostic tail may be lost")
    if headers[-1].get("overwrittenSegments", 0):
        problems.append(f"{headers[-1]['overwrittenSegments']} intermediate incident segments were overwritten")
    if gaps:
        problems.append("capture/admission gaps exist; retained counts are incomplete")
    for status in statuses:
        if status.get("status") != "watching-stderr":
            problems.append(str(status.get("status")))
    evidence = []
    for cycle in cycles:
        start, end = cycle.get("byteStart"), cycle.get("byteEnd")
        if not isinstance(start, int) or not isinstance(end, int) or end <= start:
            problems.append("cycle has no valid byte interval")
            continue
        candidates = [o for o in operations
                      if isinstance(o.get("byteStart"), int) and isinstance(o.get("byteEnd"), int)
                      and o["byteStart"] <= start and end <= o["byteEnd"]]
        evidence.append({"warning": cycle, "candidateBoundaries": candidates})
    result = {
        "session": headers[0], "retainedWarnings": len(cycles), "problems": problems,
        "statuses": statuses, "gaps": gaps, "evidence": evidence,
        "interpretation": "Byte enclosure identifies candidate application calls, not the emitter thread or a framework cycle stack.",
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return
    print(f"Session: {headers[0]['session']} | retained warnings: {len(cycles)}")
    print("Build:", json.dumps(headers[0].get("build", "unavailable"), ensure_ascii=False))
    for problem in problems:
        print("Evidence limit:", problem)
    groups = collections.defaultdict(list)
    for item in evidence:
        boundaries = tuple(sorted({(o.get("operation"), o.get("location")) for o in item["candidateBoundaries"]}))
        groups[(item["warning"].get("attribute"), boundaries)].append(item)
    for (attribute, boundaries), items in groups.items():
        times = [i["warning"].get("time") for i in items]
        times = [t for t in times if isinstance(t, (float, int))]
        interval = "unknown"
        if times:
            interval = " … ".join(datetime.datetime.fromtimestamp(t / 1000).astimezone().isoformat(timespec="milliseconds")
                                  for t in (min(times), max(times)))
        print(f"attribute={attribute} count={len(items)} observed-by={interval}")
        for operation, location in boundaries:
            print(f"  candidate: {operation} @ {location}")
        if not boundaries:
            print("  unattributed: no retained instrumented call encloses these bytes")
        if args.stacks:
            shown = set()
            for item in items:
                for boundary in item["candidateBoundaries"]:
                    key = (boundary.get("operation"), boundary.get("location"))
                    if key not in shown:
                        shown.add(key)
                        print("  example boundary caller stack (not the warning stack; all records available with --json):")
                        for frame in boundary.get("boundaryStack", []):
                            print("   ", frame)
    print(result["interpretation"])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"Cannot read AttributeGraph evidence: {error}", file=sys.stderr)
        sys.exit(2)
